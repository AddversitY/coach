"""Backups stepping in: project the next man up when a starter is ruled out, and test the prices.

Free data only:
- nflverse weekly player stats, snap counts and injury reports, 2016-2026
  (CC BY 4.0).
- The PropLine graded player-props sample (CC BY 4.0): opening and closing
  prices from 20+ books for 32 games, September 18-29, 2026.

Two tests.

1. Projection (2016-2025). A starter is a player who averaged at least the
   group's snap share (QB/WR/TE 70%, RB 50%) over his previous games and is
   listed Out or Doubtful on the final injury report. His backup is the
   same-group teammate with the most snaps over the previous games who is not
   a starter himself. The projection gives the backup his own recent share of
   team targets (or carries, or pass attempts) plus a fraction of the missing
   starter's share, times the team's recent volume, times his efficiency
   (career yards per target, carry or attempt, shrunk toward the position
   average). Only fresh news counts: the starter played the team's previous
   game, so the backup's recent numbers do not already include the absence.
   The fraction is fit on 2016-2020 and checked on 2021-2025
   against the backup's own recent average, which is what a lazy line would
   copy.

2. Prices (PropLine, 2026 weeks 2-4). For every backup with a prop, did the
   opening price beat the close (closing line value, CLV)? Compared with
   every other prop in the same sample, and for the side the projection
   picks against the opening line.

Output: research/backup/backtest.json and the fitted constants that
tools/backup_watch.py uses (research/backup/params.json). Nothing here is a pick.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import line_shop  # noqa: E402

BASE = 'https://github.com/nflverse/nflverse-data/releases/download'
SEASONS = range(2016, 2027)
TRAIN = range(2016, 2021)
TEST = range(2021, 2026)
GROUPS = {'QB': ('QB',), 'RB': ('RB', 'FB', 'HB'), 'WR': ('WR',), 'TE': ('TE',)}
STARTER_SHARE = {'QB': 0.70, 'RB': 0.50, 'WR': 0.70, 'TE': 0.70}
OUT = {'Out', 'Doubtful'}
PRIOR_GAMES = 4
# Efficiency is shrunk toward the position average with this many league-average
# opportunities. Set before testing, not tuned.
SHRINK = {'targets': 60, 'carries': 80, 'attempts': 150}
# Volume each group's backups compete for.
VOLUME = {'QB': ('attempts',), 'RB': ('carries', 'targets'), 'WR': ('targets',), 'TE': ('targets',)}
# Prop markets projected for each group.
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
COLS = ['attempts', 'completions', 'passing_yards', 'carries', 'rushing_yards',
        'targets', 'receptions', 'receiving_yards']


def fetch(kind: str, season: int, cache: Path) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    name = {'stats': 'stats_player/stats_player_week', 'injuries': 'injuries/injuries',
            'snaps': 'snap_counts/snap_counts'}[kind]
    path = cache / f'{Path(name).name}_{season}.csv'
    if not path.exists():
        path.write_bytes(urllib.request.urlopen(f'{BASE}/{name}_{season}.csv', timeout=120).read())
    return path


def norm(name) -> str:
    text = re.sub(r'\b(jr|sr|ii|iii|iv|v)\b\.?', '', str(name).lower())
    return re.sub(r'[^a-z]', '', text)


def group_of(position) -> str | None:
    for group, codes in GROUPS.items():
        if str(position) in codes:
            return group
    return None


# ---------------------------------------------------------------- data

def load(cache: Path, seasons) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Player-weeks (one row per player who took a snap or recorded a stat) and final injury reports."""
    stats, snaps, inj = [], [], []
    for y in seasons:
        s = pd.read_csv(fetch('stats', y, cache), low_memory=False)
        s = s[s.season_type == 'REG']
        stats.append(s[['player_id', 'player_display_name', 'position', 'season', 'week', 'team'] + COLS])
        n = pd.read_csv(fetch('snaps', y, cache), low_memory=False)
        snaps.append(n[n.game_type == 'REG'][['season', 'week', 'team', 'player', 'position', 'offense_pct']])
        i = pd.read_csv(fetch('injuries', y, cache), low_memory=False)
        inj.append(i[(i.game_type == 'REG') & i.report_status.isin(OUT)][['season', 'week', 'team', 'full_name', 'position']])
    stats = pd.concat(stats)
    stats['key'] = stats.player_display_name.map(norm)
    snaps = pd.concat(snaps)
    snaps['key'] = snaps.player.map(norm)
    snaps = snaps.drop_duplicates(['season', 'week', 'team', 'key'])
    pw = snaps.merge(stats.rename(columns={'position': 'stat_position'}), on=['season', 'week', 'team', 'key'],
                     how='outer')
    pw['name'] = pw.player_display_name.fillna(pw.player)
    pw['position'] = pw.position.fillna(pw.stat_position)
    pw['group'] = pw.position.map(group_of)
    pw = pw[pw.group.notna()].copy()
    pw[COLS] = pw[COLS].fillna(0)
    pw['share'] = pw.offense_pct.fillna(0)
    inj = pd.concat(inj)
    inj['key'] = inj.full_name.map(norm)
    return pw, inj


def team_volume(pw: pd.DataFrame) -> pd.DataFrame:
    """Each team's recent pass attempts, carries and targets per game (previous games only)."""
    t = pw.groupby(['season', 'team', 'week'])[['attempts', 'carries', 'targets']].sum().reset_index()
    t = t.sort_values(['season', 'team', 'week'])
    for col in ('attempts', 'carries', 'targets'):
        t[f'team_{col}'] = t.groupby(['season', 'team'])[col].transform(
            lambda x: x.shift(1).rolling(PRIOR_GAMES, min_periods=2).mean())
        t[f'team_{col}_now'] = t[col]
    return t[['season', 'team', 'week'] + [c for c in t.columns if c.startswith('team_')]]


def add_priors(pw: pd.DataFrame, volume: pd.DataFrame) -> pd.DataFrame:
    """Previous-games snap share, volume shares, per-game averages and career efficiency."""
    pw = pw.merge(volume, on=['season', 'team', 'week'], how='left')
    for col in ('attempts', 'carries', 'targets'):
        pw[f'{col}_share'] = pw[col] / pw[f'team_{col}_now'].replace(0, np.nan)
    pw = pw.sort_values(['season', 'week'])
    g = pw.groupby(['season', 'team', 'key'])
    pw['prior_snap'] = g.share.transform(lambda x: x.shift(1).rolling(3, min_periods=2).mean())
    pw['prior_games'] = g.cumcount()
    for col in ('attempts', 'carries', 'targets'):
        pw[f'prior_{col}_share'] = g[f'{col}_share'].transform(
            lambda x: x.shift(1).rolling(PRIOR_GAMES, min_periods=1).mean())
    for col in COLS:
        pw[f'naive_{col}'] = g[col].transform(lambda x: x.shift(1).rolling(PRIOR_GAMES, min_periods=1).mean())
    # Career efficiency to date (all earlier seasons and weeks).
    pw = pw.sort_values(['season', 'week'])
    c = pw.groupby('key')
    for num, den in (('receiving_yards', 'targets'), ('receptions', 'targets'), ('rushing_yards', 'carries'),
                     ('passing_yards', 'attempts'), ('completions', 'attempts')):
        pw[f'cum_{num}_{den}'] = c[num].transform(lambda x: x.shift(1).cumsum()).fillna(0)
        pw[f'cum_{den}_for_{num}'] = c[den].transform(lambda x: x.shift(1).cumsum()).fillna(0)
    return pw


def position_means(pw: pd.DataFrame, seasons) -> dict:
    """League efficiency by group, from the given seasons only."""
    frame = pw[pw.season.isin(list(seasons))]
    out = {}
    for group, rows in frame.groupby('group'):
        def rate(num, den):
            d = rows[den].sum()
            return float(rows[num].sum() / d) if d else 0.0
        out[group] = {
            'receiving_yards/targets': rate('receiving_yards', 'targets'),
            'receptions/targets': rate('receptions', 'targets'),
            'rushing_yards/carries': rate('rushing_yards', 'carries'),
            'passing_yards/attempts': rate('passing_yards', 'attempts'),
            'completions/attempts': rate('completions', 'attempts'),
        }
    return out


def shrunk(made, opportunities, mean, k):
    return (made + k * mean) / (opportunities + k)


# ---------------------------------------------------------------- events

def last_prior(pw: pd.DataFrame) -> dict:
    """{(season, team, key): [(week, snap share over previous games, prior volume shares...)]}."""
    rows = {}
    keep = pw.sort_values('week')
    for r in keep.itertuples():
        # Share including this game, so an injured player's latest known level carries forward.
        rows.setdefault((r.season, r.team, r.key), []).append((r.week, r.share, r.targets_share, r.carries_share,
                                                               r.attempts_share, r.name, r.group))
    return rows


def _mean(values) -> float:
    values = [v for v in values if v is not None and not pd.isna(v)]
    return float(np.mean(values)) if values else 0.0


def _recent(history, week, n=3):
    before = [h for h in history if h[0] < week]
    return before[-n:]


def find_events(pw: pd.DataFrame, inj: pd.DataFrame) -> pd.DataFrame:
    """One row per (team-week, group) with a starter ruled out and a backup who played."""
    history = last_prior(pw)
    team_weeks = {}
    for (season, team), weeks in pw.groupby(['season', 'team']).week:
        team_weeks[(season, team)] = sorted(set(weeks))
    events = []
    played = pw[pw.share > 0]
    by_team_week = {k: v for k, v in played.groupby(['season', 'week', 'team'])}
    for (season, week, team), outs in inj.groupby(['season', 'week', 'team']):
        roster = by_team_week.get((season, week, team))
        if roster is None:
            continue
        for group in GROUPS:
            starters = []
            for r in outs.itertuples():
                recent = _recent(history.get((season, team, r.key), []), week)
                if len(recent) < 2 or recent[-1][6] != group:
                    continue
                # Fresh news only: he played the team's previous game. After a missed game the
                # backup's own recent numbers already include the absence.
                earlier = [w for w in team_weeks.get((season, team), []) if w < week]
                if not earlier or recent[-1][0] != earlier[-1]:
                    continue
                share = float(np.mean([h[1] for h in recent]))
                if share < STARTER_SHARE[group]:
                    continue
                starters.append({
                    'key': r.key, 'name': recent[-1][5], 'snap': share,
                    'targets': _mean([h[2] for h in recent]),
                    'carries': _mean([h[3] for h in recent]),
                    'attempts': _mean([h[4] for h in recent]),
                })
            if not starters:
                continue
            mates = roster[(roster.group == group) & (~roster.key.isin([s['key'] for s in starters]))].copy()
            mates['prior_snap'] = mates.prior_snap.fillna(0)
            # Other healthy starters are not the backup.
            mates = mates[mates.prior_snap < STARTER_SHARE[group]]
            if mates.empty:
                continue
            backup = mates.sort_values(['prior_snap', 'share'], ascending=False).iloc[0]
            row = backup.to_dict()
            row.update({
                'out_names': ', '.join(s['name'] for s in starters),
                'out_snap': sum(s['snap'] for s in starters),
                'out_targets': float(np.nansum([s['targets'] for s in starters])),
                'out_carries': float(np.nansum([s['carries'] for s in starters])),
                'out_attempts': float(np.nansum([s['attempts'] for s in starters])),
            })
            events.append(row)
    return pd.DataFrame(events)


# ---------------------------------------------------------------- projection

def fit_inherit(events: pd.DataFrame) -> dict:
    """Fraction of a missing starter's volume share the backup inherits, by group and volume type."""
    out = {}
    for group, vols in VOLUME.items():
        e = events[events.group == group]
        for vol in vols:
            s = e[f'out_{vol}'].fillna(0).values
            b = e[f'prior_{vol}_share'].fillna(0).values
            a = e[f'{vol}_share'].fillna(0).values
            mask = s > 0.02
            if mask.sum() < 20:
                out[f'{group}:{vol}'] = 0.5
                continue
            f = float(np.sum(s[mask] * (a[mask] - b[mask])) / np.sum(s[mask] ** 2))
            out[f'{group}:{vol}'] = round(min(max(f, 0.0), 1.0), 3)
    return out


def project(row, inherit: dict, means: dict) -> dict:
    """Projected stat line for the backup in one event (a dict of stat -> value)."""
    group = row['group']
    m = means[group]
    out = {}
    def share(vol):
        return (0 if pd.isna(row.get(f'prior_{vol}_share')) else row[f'prior_{vol}_share']) + \
            inherit.get(f'{group}:{vol}', 0) * (0 if pd.isna(row.get(f'out_{vol}')) else row[f'out_{vol}'])
    def eff(num, den, key):
        return shrunk(row.get(f'cum_{num}_{den}', 0), row.get(f'cum_{den}_for_{num}', 0), m[key], SHRINK[den])
    if group == 'QB':
        att = share('attempts') * row['team_attempts']
        out['attempts'] = att
        out['passing_yards'] = att * eff('passing_yards', 'attempts', 'passing_yards/attempts')
        out['completions'] = att * eff('completions', 'attempts', 'completions/attempts')
        return out
    targets = share('targets') * row['team_targets']
    out['targets'] = targets
    out['receiving_yards'] = targets * eff('receiving_yards', 'targets', 'receiving_yards/targets')
    out['receptions'] = targets * eff('receptions', 'targets', 'receptions/targets')
    if group == 'RB':
        carries = share('carries') * row['team_carries']
        out['carries'] = carries
        out['rushing_yards'] = carries * eff('rushing_yards', 'carries', 'rushing_yards/carries')
    return out


QUANTILES = np.linspace(0.025, 0.975, 39)


def ratio_quantiles(events: pd.DataFrame, inherit: dict, means: dict) -> dict:
    """Spread of actual / projected for each group and market: turns a projection into an over chance."""
    out = {}
    events = events.dropna(subset=['team_targets', 'team_carries', 'team_attempts'])
    for group, markets in MARKETS.items():
        e = events[events.group == group]
        if len(e) < 30:
            continue
        proj = pd.DataFrame([project(r, inherit, means) for r in e.to_dict('records')], index=e.index)
        for market in markets:
            stat = STAT_OF_MARKET[market]
            if stat not in proj:
                continue
            ok = proj[stat] > 0.5
            ratio = (e[stat][ok] / proj[stat][ok]).values
            out[f'{group}:{market}'] = [round(float(q), 3) for q in np.quantile(ratio, QUANTILES)]
    return out


def over_chance(projection: float, line: float, quantiles: list) -> float | None:
    """Chance the stat goes over ``line`` given a projection and the actual/projected spread."""
    if not projection or projection <= 0 or not quantiles:
        return None
    target = line / projection
    qs = np.asarray(quantiles)
    probs = QUANTILES
    if target <= qs[0]:
        return float(1 - probs[0] * max(target, 0) / qs[0]) if qs[0] > 0 else float(1 - probs[0])
    if target >= qs[-1]:
        return float((1 - probs[-1]) * 0.5)
    below = float(np.interp(target, qs, probs))
    return 1 - below


def projection_report(events: pd.DataFrame, inherit: dict, means: dict, quantiles: dict | None = None) -> dict:
    report = {}
    events = events.dropna(subset=['team_targets', 'team_carries', 'team_attempts'])
    for group, markets in MARKETS.items():
        e = events[events.group == group]
        if e.empty:
            continue
        proj = pd.DataFrame([project(r, inherit, means) for r in e.to_dict('records')], index=e.index)
        block = {'events': int(len(e))}
        for market in markets:
            stat = STAT_OF_MARKET[market]
            if stat not in proj:
                continue
            actual, p, naive = e[stat].values, proj[stat].values, e[f'naive_{stat}'].fillna(0).values
            block[market] = {
                'averageActual': round(float(actual.mean()), 1),
                'averageOwnRecent': round(float(naive.mean()), 1),
                'averageProjection': round(float(p.mean()), 1),
                'rmseOwnRecent': round(float(np.sqrt(((actual - naive) ** 2).mean())), 2),
                'rmseProjection': round(float(np.sqrt(((actual - p) ** 2).mean())), 2),
                'beatOwnRecent': round(float((actual > naive).mean()), 3),
            }
            q = (quantiles or {}).get(f'{group}:{market}')
            if q:
                # A lazy line: the backup's own recent average, rounded to a half point.
                lines = np.floor(naive) + 0.5
                chance = np.array([over_chance(pp, ll, q) or 0.5 for pp, ll in zip(p, lines)])
                won = (actual > lines).astype(float)
                block[market]['lazyLineBrier'] = {
                    'projection': round(float(((chance - won) ** 2).mean()), 4),
                    'coinFlip': 0.25,
                    'overRate': round(float(won.mean()), 3),
                }
        report[group] = block
    return report


# ---------------------------------------------------------------- prices

def _consensus_close(quotes, event, market, player):
    """Median no-vig closing over chance across books, at the most common closing line."""
    lines = {}
    for (e, book, m, p, side), q in quotes.items():
        if (e, m, p) != (event, market, player) or side != 'over':
            continue
        fair = line_shop._book_fair(quotes, event, book, market, player, 'close')
        if fair:
            lines.setdefault(fair[0], []).append(fair[1])
    if not lines:
        return None
    line = max(lines, key=lambda l: len(lines[l]))
    return line, float(np.median(lines[line])), len(lines[line])


def price_test(rows, backups: dict, projections: dict, quantiles: dict, soft=line_shop.PROPLINE_SOFT) -> dict:
    """Closing line value of opening prices on backups' props, against every other prop."""
    quotes = line_shop.propline_quotes(rows)
    props = {(e, m, p) for (e, _b, m, p, _s) in quotes}
    out = {'backup': {'over': [], 'under': [], 'projected': [], 'projectedProfit': []},
           'other': {'over': [], 'under': []}, 'backupProps': []}
    for event, market, player in props:
        close = _consensus_close(quotes, event, market, player)
        if close is None:
            continue
        close_line, close_over, books = close
        if books < 3:
            continue
        who = backups.get((event, norm(player)))
        bucket = 'backup' if who else 'other'
        best = {}
        for book in soft:
            for side in ('over', 'under'):
                q = quotes.get((event, book, market, player, side))
                if not q or q['openPrice'] is None or q['openLine'] is None:
                    continue
                moved = line_shop.shift_chance(close_over, close_line, q['openLine'], market)
                if moved is None:
                    continue
                fair = moved if side == 'over' else 1 - moved
                decimal = line_shop.decimal_from_american(q['openPrice'])
                clv = line_shop.expected_value(fair, decimal)
                # One bet per prop and side: the best opening price across soft books.
                if side not in best or clv > best[side]['clv']:
                    best[side] = {'clv': clv, 'line': q['openLine'], 'decimal': decimal, 'book': book,
                                  'actual': q['actual']}
        for side, bet in best.items():
            out[bucket][side].append(bet['clv'])
        if who and best:
            proj = projections.get((event, norm(player)), {})
            stat = proj.get(STAT_OF_MARKET.get(market))
            pick, chance = None, None
            if stat is not None:
                line = (best.get('over') or best.get('under'))['line']
                chance = over_chance(stat, line, quantiles.get(f"{proj.get('_group')}:{market}"))
                edges = {side: line_shop.expected_value(chance if side == 'over' else 1 - chance, bet['decimal'])
                         for side, bet in best.items() if chance is not None and bet['line'] == line}
                pick = max(edges, key=edges.get) if edges and max(edges.values()) > 0 else None
                if pick in best:
                    bet = best[pick]
                    out['backup']['projected'].append(bet['clv'])
                    if bet['actual'] is not None and bet['actual'] != bet['line']:
                        won = (bet['actual'] > bet['line']) == (pick == 'over')
                        out['backup']['projectedProfit'].append(bet['decimal'] - 1 if won else -1.0)
            out['backupProps'].append({
                'player': player, 'starterOut': who, 'market': market,
                'openLine': (best.get('over') or best.get('under'))['line'], 'closeLine': close_line,
                'projection': None if stat is None else round(stat, 1), 'pick': pick,
                'overChance': None if chance is None else round(chance, 3),
                'overClv': round(best['over']['clv'], 4) if 'over' in best else None,
                'underClv': round(best['under']['clv'], 4) if 'under' in best else None,
            })
    summary = {
        'backupOverClv': line_shop.summarize(out['backup']['over']),
        'backupUnderClv': line_shop.summarize(out['backup']['under']),
        'backupProjectedSideClv': line_shop.summarize(out['backup']['projected']),
        'backupProjectedSideProfit': line_shop.summarize(out['backup']['projectedProfit']),
        'otherOverClv': line_shop.summarize(out['other']['over'], rounds=200),
        'otherUnderClv': line_shop.summarize(out['other']['under'], rounds=200),
        'backupProps': sorted(out['backupProps'], key=lambda r: (r['player'], r['market'])),
    }
    passes, reason = line_shop.gate(summary['backupProjectedSideClv'])
    summary['passes'], summary['reason'] = passes, reason
    return summary


def propline_events(rows, events_2026: pd.DataFrame, inherit, means) -> tuple[dict, dict]:
    """Map PropLine (event, player) to the starter who was out, and to the projection."""
    teams = {name: code for code, name in line_shop._team_names().items()}
    games = {}
    for row in rows:
        games.setdefault(row['event_id'], (row['commence_time'][:10], row['home_team'], row['away_team']))
    schedule = {}
    for event, (day, home, away) in games.items():
        for name in (home, away):
            schedule.setdefault((teams.get(name, name), day), event)
    backups, projections = {}, {}
    for r in events_2026.to_dict('records'):
        for (code, day), event in schedule.items():
            if code != r['team']:
                continue
            # Match the event inside the backup's NFL week (kickoff within 7 days of the week's Thursday).
            if r.get('game_day') and abs((pd.Timestamp(day) - pd.Timestamp(r['game_day'])).days) > 3:
                continue
            backups[(event, r['key'])] = r['out_names']
            projections[(event, r['key'])] = {**project(r, inherit, means), '_group': r['group']}
    return backups, projections


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cache', default='model/.cache/backup')
    ap.add_argument('--schedule', default='model/.cache/games.csv')
    ap.add_argument('--propline', default='model/.cache/propline.csv.gz')
    ap.add_argument('--out', default='research/backup/backtest.json')
    ap.add_argument('--params', default='research/backup/params.json')
    args = ap.parse_args()
    cache = Path(args.cache)
    pw, inj = load(cache, SEASONS)
    pw = add_priors(pw, team_volume(pw))
    events = find_events(pw, inj)
    train = events[events.season.isin(list(TRAIN))]
    test = events[events.season.isin(list(TEST))]
    inherit = fit_inherit(train)
    means_train = position_means(pw, TRAIN)
    quant_train = ratio_quantiles(train, inherit, means_train)
    report = {
        'source': 'nflverse weekly player stats, snap counts and injury reports 2016-2026 (CC BY 4.0); '
                  'PropLine graded player-props sample 2026-09-18 to 2026-09-29 (CC BY 4.0)',
        'starter': {g: f'at least {int(v * 100)}% of snaps over his previous games, Out or Doubtful'
                    for g, v in STARTER_SHARE.items()},
        'backup': 'the same-group teammate with the most snaps over the previous games who is not a starter',
        'train': [TRAIN.start, TRAIN.stop - 1], 'test': [TEST.start, TEST.stop - 1],
        'events': {'train': int(len(train)), 'test': int(len(test))},
        'inheritedShare': inherit,
        'projectionTest': projection_report(test, inherit, means_train, quant_train),
        'projectionTrain': projection_report(train, inherit, means_train),
    }
    # Prices: 2026 weeks covered by PropLine, using every season before 2026 for the fit.
    fit_all = events[events.season < 2026]
    inherit_all = fit_inherit(fit_all)
    means_all = position_means(pw, range(2016, 2026))
    schedule = pd.read_csv(args.schedule, low_memory=False) if Path(args.schedule).exists() else None
    ev26 = events[events.season == 2026].copy()
    if schedule is not None:
        days = {}
        for g in schedule[schedule.season == 2026].itertuples():
            days[(g.week, g.home_team)] = g.gameday
            days[(g.week, g.away_team)] = g.gameday
        ev26['game_day'] = [days.get((w, t)) for w, t in zip(ev26.week, ev26.team)]
    rows = line_shop.load_propline(args.propline)
    backups, projections = propline_events(rows, ev26, inherit_all, means_all)
    quant_all = ratio_quantiles(fit_all, inherit_all, means_all)
    report['prices'] = price_test(rows, backups, projections, quant_all)
    report['prices']['note'] = ('Opening price at the best soft book against the median no-vig close of 3+ '
                                'books, moved to the opening line. Backups are matched by name in the '
                                'weeks a starter was ruled out.')
    params = {
        'schema': 'coach-backup-params-v1',
        'quantiles': [round(float(q), 3) for q in QUANTILES],
        'ratioQuantiles': quant_all,
        'fitSeasons': [2016, 2025],
        'inheritedShare': inherit_all,
        'positionMeans': means_all,
        'shrink': SHRINK,
        'starterShare': STARTER_SHARE,
        'priorGames': PRIOR_GAMES,
    }
    report['inheritedShareAllSeasons'] = inherit_all
    for path, doc in ((args.out, report), (args.params, params)):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(json.dumps(doc, indent=1) + '\n')
    printable = {k: v for k, v in report.items() if k != 'prices'}
    printable['prices'] = {k: v for k, v in report['prices'].items() if k != 'backupProps'}
    print(json.dumps(printable, indent=1))


if __name__ == '__main__':
    main()
