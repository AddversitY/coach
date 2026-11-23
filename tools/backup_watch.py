"""Backups stepping in: when a starter is ruled out, project his backup and log the prop prices.

The backtest (model/backup_backtest.py, docs/BACKUP_PLAYERS.md) fits how much
of a missing starter's volume his backup inherits, 2016-2025. This script
applies it live, with free data only:

1. ESPN's injury feed (no key) says which starters are Out, Doubtful, on
   injured reserve or suspended. A starter is a QB, RB, WR or TE whose recent
   snap share (assets/prop-usage.json) is at or above the backtest's line.
   Only fresh news counts: he played his team's latest game.
2. The backup is the same-position teammate with the most recent snaps who is
   not a starter and not ruled out himself.
3. His projection = (his recent share of team targets, carries or pass
   attempts + the fitted share of the starter's) x the team's recent volume x
   his career efficiency shrunk toward the position average
   (assets/nfl-player-stats.json). The fitted actual/projected spread turns a
   projection into an over chance at any line.
4. The logged-out prices the Worker already collects (FanDuel, Bovada,
   BetRivers: /v1/book-prices) are read every run. The first price seen for
   each backup prop after the news is kept: that is the price that could have
   been taken. After kickoff it is scored against the same book's last price
   before kickoff (closing line value), and against the box score when it
   arrives.

Every row is research. The rule becomes a pick only after 200 scored bets on
the projected side with closing line value clearly above zero (the same gate
as tools/line_shop.py). Coach ratings are shown beside each player; they are
an extra number to weigh, not part of the chance.

Output: assets/backup-watch.json.
"""

import json
import math
import re
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

import line_shop
import qb_news

SCHEMA = 'coach-backup-watch-v1'
BOOK_PRICES_URL = 'https://coach-research.dds-dge.workers.dev/v1/book-prices'
GROUPS = {'QB': ('QB',), 'RB': ('RB', 'HB', 'FB'), 'WR': ('WR',), 'TE': ('TE',)}
VOLUME = {'QB': ('attempts',), 'RB': ('carries', 'targets'), 'WR': ('targets',), 'TE': ('targets',)}
MARKETS = {
    'QB': ('player_pass_yds', 'player_pass_attempts', 'player_pass_completions'),
    'RB': ('player_rush_yds', 'player_reception_yds', 'player_receptions'),
    'WR': ('player_reception_yds', 'player_receptions'),
    'TE': ('player_reception_yds', 'player_receptions'),
}
STAT_OF_MARKET = {
    'player_pass_yds': 'passing_yards', 'player_pass_attempts': 'attempts',
    'player_pass_completions': 'completions', 'player_rush_yds': 'rushing_yards',
    'player_reception_yds': 'receiving_yards', 'player_receptions': 'receptions',
}
MARKET_LABEL = {
    'player_pass_yds': 'passing yards', 'player_pass_attempts': 'pass attempts',
    'player_pass_completions': 'completions', 'player_rush_yds': 'rushing yards',
    'player_reception_yds': 'receiving yards', 'player_receptions': 'receptions',
}
EFFICIENCY = {  # stat -> (made, opportunities, position-mean key)
    'receiving_yards': ('receiving_yards', 'targets', 'receiving_yards/targets'),
    'receptions': ('receptions', 'targets', 'receptions/targets'),
    'rushing_yards': ('rushing_yards', 'carries', 'rushing_yards/carries'),
    'passing_yards': ('passing_yards', 'attempts', 'passing_yards/attempts'),
    'completions': ('completions', 'attempts', 'completions/attempts'),
}
MAX_LOG = 5000


def _now_text(now):
    return now.isoformat().replace('+00:00', 'Z')


def norm(name):
    text = re.sub(r'\b(jr|sr|ii|iii|iv|v)\b\.?', '', str(name).lower())
    return re.sub(r'[^a-z]', '', text)


def group_of(position):
    for group, codes in GROUPS.items():
        if position in codes:
            return group
    return None


# ---------------------------------------------------------------- usage

class Usage:
    """Recent snap shares, team volume and career box scores from the bundled assets."""

    def __init__(self, stats, usage):
        keys = stats.get('statKeys') or []
        self.rows = []
        for row in stats.get('rows') or []:
            if row.get('seasonType') != 'REG':
                continue
            values = dict(zip(keys, row.get('stats') or []))
            self.rows.append({**{k: row.get(k) for k in ('playerId', 'name', 'position', 'team', 'season', 'week')},
                              **{k: values.get(k) or 0 for k in ('attempts', 'completions', 'passing_yards',
                                                                   'carries', 'rushing_yards', 'targets',
                                                                   'receptions', 'receiving_yards')}})
        self.season = max((r['season'] for r in self.rows), default=0)
        ukeys = usage.get('keys') or []
        self.snaps = {}
        for raw in usage.get('rows') or []:
            row = dict(zip(ukeys, raw))
            if row.get('season') == self.season:
                self.snaps.setdefault(row['id'], []).append((row['week'], row.get('snap') or 0))
        for values in self.snaps.values():
            values.sort()
        self.team_weeks = {}
        for r in self.rows:
            if r['season'] != self.season:
                continue
            t = self.team_weeks.setdefault((r['team'], r['week']), {'attempts': 0, 'carries': 0, 'targets': 0})
            for col in t:
                t[col] += r[col]
        self.by_player = {}
        for r in self.rows:
            self.by_player.setdefault(r['playerId'], []).append(r)

    def last_team_week(self, team):
        return max((w for (t, w) in self.team_weeks if t == team), default=None)

    def last_week_played(self, player_id, team):
        weeks = [r['week'] for r in self.by_player.get(player_id, [])
                 if r['season'] == self.season and r['team'] == team]
        weeks += [w for w, share in self.snaps.get(player_id, []) if share > 0]
        return max(weeks, default=None)

    def recent_snap(self, player_id, games=3):
        values = self.snaps.get(player_id) or []
        recent = [share for _week, share in values[-games:]]
        return sum(recent) / len(recent) if recent else 0.0

    def team_volume(self, team, games):
        weeks = sorted(w for (t, w) in self.team_weeks if t == team)[-games:]
        if len(weeks) < 2:
            return None
        return {col: sum(self.team_weeks[(team, w)][col] for w in weeks) / len(weeks)
                for col in ('attempts', 'carries', 'targets')}

    def recent_shares(self, player_id, team, games):
        rows = [r for r in self.by_player.get(player_id, []) if r['season'] == self.season and r['team'] == team]
        rows = sorted(rows, key=lambda r: r['week'])[-games:]
        out = {}
        for col in ('attempts', 'carries', 'targets'):
            shares = []
            for r in rows:
                total = self.team_weeks.get((team, r['week']), {}).get(col)
                if total:
                    shares.append(r[col] / total)
            out[col] = sum(shares) / len(shares) if shares else 0.0
        return out

    def career(self, player_id):
        totals = {}
        for r in self.by_player.get(player_id, []):
            for col in ('attempts', 'completions', 'passing_yards', 'carries', 'rushing_yards', 'targets',
                        'receptions', 'receiving_yards'):
                totals[col] = totals.get(col, 0) + r[col]
        return totals

    def actual(self, player_id, season, week):
        for r in self.by_player.get(player_id, []):
            if r['season'] == season and r['week'] == week:
                return r
        return None


def project(group, backup_shares, starter_shares, volume, career, params):
    """Projected stat line for a backup (stat -> value)."""
    inherit = params.get('inheritedShare') or {}
    means = (params.get('positionMeans') or {}).get(group) or {}
    shrink = params.get('shrink') or {}

    def share(vol):
        return backup_shares.get(vol, 0) + inherit.get(f'{group}:{vol}', 0) * starter_shares.get(vol, 0)

    def eff(stat):
        made, opp, key = EFFICIENCY[stat]
        k = shrink.get(opp, 60)
        return (career.get(made, 0) + k * means.get(key, 0)) / (career.get(opp, 0) + k)

    out = {}
    if group == 'QB':
        attempts = share('attempts') * volume['attempts']
        out['attempts'] = attempts
        out['passing_yards'] = attempts * eff('passing_yards')
        out['completions'] = attempts * eff('completions')
        return out
    targets = share('targets') * volume['targets']
    out['targets'] = targets
    out['receiving_yards'] = targets * eff('receiving_yards')
    out['receptions'] = targets * eff('receptions')
    if group == 'RB':
        carries = share('carries') * volume['carries']
        out['carries'] = carries
        out['rushing_yards'] = carries * eff('rushing_yards')
    return out


def over_chance(projection, line, levels, quantiles):
    """Chance of going over ``line``, from the fitted spread of actual / projected."""
    if not projection or projection <= 0 or not quantiles or line is None:
        return None
    target = line / projection
    if target <= quantiles[0]:
        return 1 - levels[0] * (max(target, 0) / quantiles[0] if quantiles[0] > 0 else 1)
    if target >= quantiles[-1]:
        return (1 - levels[-1]) * 0.5
    for i in range(1, len(quantiles)):
        lo, hi = quantiles[i - 1], quantiles[i]
        if target <= hi:
            frac = 0 if hi == lo else (target - lo) / (hi - lo)
            return 1 - (levels[i - 1] + frac * (levels[i] - levels[i - 1]))
    return None


# ---------------------------------------------------------------- who steps in

def stepping_in(ratings, statuses, usage, params):
    """[(team, group, [out starters], backup)] using ratings rosters, box scores and recent snaps."""
    threshold = params.get('starterShare') or {}
    listed_qb = {t.get('t'): norm(t.get('qb')) for t in ratings.get('teams') or [] if t.get('qb')}
    by_team, seen = {}, set()
    for p in ratings.get('players') or []:
        group = group_of(p.get('p'))
        if group and p.get('t') and p.get('id'):
            by_team.setdefault((p['t'], group), []).append(p)
            seen.add(p['id'])
    # Players too new or too little used to be rated still count as backups.
    for player_id, rows in usage.by_player.items():
        latest = max(rows, key=lambda r: (r['season'], r['week']))
        group = group_of(latest.get('position'))
        if player_id in seen or not group or latest['season'] != usage.season:
            continue
        by_team.setdefault((latest['team'], group), []).append(
            {'n': latest['name'], 'id': player_id, 't': latest['team'], 'p': latest['position'], 'o': None, 's': 0})
    out = []
    for (team, group), roster in sorted(by_team.items()):
        team_status = statuses.get(team, {})

        def status(p):
            found = qb_news._status_for(team_status, p.get('n'))
            return found if found and found[0].lower() in qb_news.OUT_STATUSES else None

        line = threshold.get(group, 0.7)

        def is_starter(p):
            if group == 'QB' and listed_qb.get(team) == norm(p.get('n')):
                return True  # The ratings' listed starter (a short last game does not demote him).
            return usage.recent_snap(p['id']) >= line

        last_week = usage.last_team_week(team)
        # Fresh news only: he played the team's latest game. Once a game is missed, the backup's
        # recent numbers already include the absence (and the books have seen it too).
        starters = [{**p, 'status': status(p)} for p in roster
                    if is_starter(p) and status(p) and usage.last_week_played(p['id'], team) == last_week]
        if not starters:
            continue
        candidates = [p for p in roster if not status(p) and not is_starter(p)]
        if not candidates:
            continue
        backup = max(candidates, key=lambda p: (usage.recent_snap(p['id']), p.get('s') or 0))
        out.append((team, group, starters, backup))
    return out


def projections(ratings, statuses, usage, params):
    rows = []
    games = params.get('priorGames', 4)
    for team, group, starters, backup in stepping_in(ratings, statuses, usage, params):
        volume = usage.team_volume(team, games)
        if not volume:
            continue
        starter_shares = {}
        for s in starters:
            shares = usage.recent_shares(s['id'], team, 3)
            for col, value in shares.items():
                starter_shares[col] = starter_shares.get(col, 0) + value
        proj = project(group, usage.recent_shares(backup['id'], team, games), starter_shares, volume,
                       usage.career(backup['id']), params)
        rows.append({
            'team': team, 'group': group,
            'out': [{'player': s['n'], 'status': s['status'][0], 'reportedAt': s['status'][1], 'rating': s.get('o')}
                    for s in starters],
            'backup': backup['n'], 'backupId': backup['id'], 'backupRating': backup.get('o'),
            'backupRecentSnaps': round(usage.recent_snap(backup['id']), 2),
            'projection': {m: round(proj[STAT_OF_MARKET[m]], 1) for m in MARKETS[group]
                           if STAT_OF_MARKET[m] in proj},
        })
    return rows


# ---------------------------------------------------------------- prices

def fetch_book_prices(fetch=None):
    fetch = fetch or (lambda url: urllib.request.urlopen(
        urllib.request.Request(url, headers={'User-Agent': 'CoachResearch/1.0'}), timeout=60).read())
    return json.loads(fetch(BOOK_PRICES_URL))


def _team_in_event(event_id, team):
    parts = str(event_id).split('_')
    return len(parts) >= 4 and team in (parts[-2], parts[-1])


def price_rows(observations, row, now):
    """Two-sided prices for one backup's props in his upcoming game: [(book, market, line, over, under, ...)]."""
    sides = {}
    for o in observations:
        if o.get('market') not in MARKETS[row['group']] or o.get('outcome') not in ('Over', 'Under'):
            continue
        if o.get('playerId') != row['backupId'] and norm(o.get('player')) != norm(row['backup']):
            continue
        if not _team_in_event(o.get('eventId'), row['team']):
            continue
        kickoff = line_shop._parse(o.get('kickoff'))
        if kickoff is None or kickoff <= now:
            continue
        key = (o['eventId'], o['book'], o['market'])
        sides.setdefault(key, {})[o['outcome']] = o
    out = []
    for (event, book, market), pair in sorted(sides.items()):
        over, under = pair.get('Over'), pair.get('Under')
        if not over or not under or over.get('line') != under.get('line'):
            continue
        out.append({'eventId': event, 'kickoff': over.get('kickoff'), 'book': book, 'market': market,
                    'line': over['line'], 'over': over['decimal'], 'under': under['decimal'], 'priceAt': over.get('at')})
    return out


def priced(rows, observations, params, now):
    """Each projection row with its current prices, Coach's over chance and the edge on each side."""
    levels = params.get('quantiles') or []
    spread = params.get('ratioQuantiles') or {}
    bets = []
    for row in rows:
        row['prices'] = []
        for price in price_rows(observations, row, now):
            proj = row['projection'].get(price['market'])
            chance = over_chance(proj, price['line'], levels, spread.get(f"{row['group']}:{price['market']}"))
            if chance is None:
                continue
            over_edge = line_shop.expected_value(chance, price['over'])
            under_edge = line_shop.expected_value(1 - chance, price['under'])
            side = 'over' if over_edge >= under_edge else 'under'
            entry = {**price, 'overChance': round(chance, 3), 'overEdge': round(over_edge, 4),
                     'underEdge': round(under_edge, 4), 'side': side if max(over_edge, under_edge) > 0 else None}
            row['prices'].append(entry)
            bets.append({
                'team': row['team'], 'group': row['group'], 'out': [o['player'] for o in row['out']],
                'backup': row['backup'], 'backupId': row['backupId'], 'projection': proj, **entry,
            })
        row['eventId'] = row['prices'][0]['eventId'] if row['prices'] else None
    return bets


# ---------------------------------------------------------------- log and score

def merge(log, bets, now):
    rows = log.setdefault('bets', [])
    seen = {(b['eventId'], b['backupId'], b['market'], b['book']) for b in rows}
    added = 0
    for bet in bets:
        key = (bet['eventId'], bet['backupId'], bet['market'], bet['book'])
        if key in seen:
            continue  # Keep the first price after the news: that is the price that could have been taken.
        rows.append({**bet, 'loggedAt': _now_text(now)})
        seen.add(key)
        added += 1
    del rows[:-MAX_LOG]
    return added


def _close_for(observations, bet):
    pair = {}
    for o in observations:
        if (o.get('eventId'), o.get('book'), o.get('market')) != (bet['eventId'], bet['book'], bet['market']):
            continue
        if o.get('playerId') != bet['backupId'] and norm(o.get('player')) != norm(bet['backup']):
            continue
        if o.get('outcome') in ('Over', 'Under'):
            pair[o['outcome']] = o
    over, under = pair.get('Over'), pair.get('Under')
    if not over or not under or over.get('line') != under.get('line'):
        return None
    chance = line_shop.no_vig(over['decimal'], under['decimal'])
    return None if chance is None else (over['line'], chance, over.get('at'))


def _week_of(event_id):
    parts = str(event_id).split(':')[-1].split('_')
    try:
        return int(parts[0]), int(parts[1])
    except (ValueError, IndexError):
        return None


def score(log, observations, usage, now):
    over, under, projected, profit = [], [], [], []
    for bet in log.get('bets') or []:
        kickoff = line_shop._parse(bet.get('kickoff'))
        if kickoff is None or kickoff > now:
            continue
        if 'close' not in bet:
            close = _close_for(observations, bet)
            if close:
                bet['close'] = {'line': close[0], 'overChance': round(close[1], 4), 'at': close[2]}
        close = bet.get('close')
        if close:
            moved = line_shop.shift_chance(close['overChance'], close['line'], bet['line'], bet['market'])
            if moved is not None:
                bet['overClv'] = round(line_shop.expected_value(moved, bet['over']), 4)
                bet['underClv'] = round(line_shop.expected_value(1 - moved, bet['under']), 4)
        if 'actual' not in bet:
            week = _week_of(bet['eventId'])
            row = usage.actual(bet['backupId'], *week) if week else None
            if row is not None:
                bet['actual'] = row[STAT_OF_MARKET[bet['market']]]
        if 'overClv' in bet:
            over.append(bet['overClv'])
            under.append(bet['underClv'])
            if bet.get('side'):
                projected.append(bet[f"{bet['side']}Clv"])
        if bet.get('side') and bet.get('actual') is not None and bet['actual'] != bet['line']:
            won = (bet['actual'] > bet['line']) == (bet['side'] == 'over')
            profit.append(bet[bet['side']] - 1 if won else -1.0)
    summary = {
        'projectedSideClv': line_shop.summarize(projected),
        'overClv': line_shop.summarize(over),
        'underClv': line_shop.summarize(under),
        'projectedSideProfit': line_shop.summarize(profit),
    }
    summary['passes'], summary['reason'] = line_shop.gate(summary['projectedSideClv'])
    return summary


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(description='Project backups when a starter is ruled out and log prop prices.')
    parser.add_argument('--ratings', default='assets/elo-ratings.json')
    parser.add_argument('--stats', default='assets/nfl-player-stats.json')
    parser.add_argument('--usage', default='assets/prop-usage.json')
    parser.add_argument('--params', default='research/backup/params.json')
    parser.add_argument('--output', default='assets/backup-watch.json')
    parser.add_argument('--injuries', help='A saved ESPN injuries response (for tests).')
    parser.add_argument('--prices', help='A saved /v1/book-prices response (for tests).')
    args = parser.parse_args(argv)
    now = datetime.now(timezone.utc)
    path = Path(args.output)
    log = json.loads(path.read_text()) if path.exists() else {'schema': SCHEMA, 'bets': []}
    ratings = json.loads(Path(args.ratings).read_text())
    usage = Usage(json.loads(Path(args.stats).read_text()), json.loads(Path(args.usage).read_text()))
    params = json.loads(Path(args.params).read_text())
    sources = {}
    try:
        payload = json.loads(Path(args.injuries).read_text()) if args.injuries else qb_news.fetch_injuries()
        rows = projections(ratings, qb_news.quarterback_statuses(payload, positions=None), usage, params)
        sources['injuries'] = 'ok'
    except Exception as error:  # noqa: BLE001 - an unavailable feed is recorded, not invented
        rows, sources['injuries'] = [], f'unavailable ({type(error).__name__})'
    try:
        prices = json.loads(Path(args.prices).read_text()) if args.prices else fetch_book_prices()
        observations = [o for o in prices.get('observations') or [] if o.get('decimal')]
        sources['prices'] = 'ok'
    except Exception as error:  # noqa: BLE001
        observations, sources['prices'] = [], f'unavailable ({type(error).__name__})'
    bets = priced(rows, observations, params, now)
    added = merge(log, bets, now)
    log['schema'] = SCHEMA
    log['checkedAt'] = _now_text(now)
    log['source'] = {**sources, 'books': 'Logged-out FanDuel, Bovada and BetRivers prices collected by the Worker'}
    log['notice'] = ('Backups stepping in for a starter ruled out: Coach projection, the first price seen after '
                     'the news, and closing line value after kickoff. Research, not a pick.')
    log['current'] = rows
    log['summary'] = score(log, observations, usage, now)
    path.write_text(json.dumps(log, indent=1) + '\n')
    print(json.dumps({'backups': len(rows), 'priced': len(bets), 'added': added,
                      'scored': log['summary']['projectedSideClv']['n']}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
