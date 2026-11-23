"""Quarterback news watch: flag a starter ruled out, and whether the line has caught up.

The opening-line backtest (docs/OPENING_LINES.md) found that quarterback
changes are where lines move most (2.05 points open to close against 1.30)
and that betting the side a change favors at the opener had +2.3% to +4.4%
closing line value in 2008-2021, if the news was known before the line moved.

This script runs with the price capture. For each upcoming game it checks the
free ESPN injury feed for the team's current starter (from
assets/elo-ratings.json). If the starter is Out, Doubtful, on injured reserve
or suspended, it writes an alert with:

- the backup (the team's other quarterback with the most snaps) and both
  Coach skill ratings, as a rough size of the drop;
- the spread saved before the report and the newest saved spread, so you can
  see whether the line already moved;
- the best price on the other team at the newest snapshot.

Each alert's price is kept and later scored against Pinnacle's close with
tools/line_shop.py. An alert is research. It becomes a pick only after alerts
like it beat the closing line on 200 bets (the same gate as line shopping).
"""

import json
import statistics
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

import line_shop

SCHEMA = 'coach-qb-news-v1'
ESPN_INJURIES = 'https://site.api.espn.com/apis/site/v2/sports/football/nfl/injuries'
OUT_STATUSES = {'out', 'doubtful', 'injured reserve', 'suspension', 'physically unable to perform'}
HORIZON_DAYS = 8
MAX_ALERTS = 2000

TEAM_NAMES = None


def _names():
    global TEAM_NAMES
    if TEAM_NAMES is None:
        import line_timing
        TEAM_NAMES = dict(line_timing.TEAMS)
    return TEAM_NAMES


def fetch_injuries(fetch=None):
    fetch = fetch or (lambda url: urllib.request.urlopen(
        urllib.request.Request(url, headers={'User-Agent': 'CoachResearch/1.0'}), timeout=30).read())
    return json.loads(fetch(ESPN_INJURIES))


def quarterback_statuses(payload):
    """{team code: {player name: (status, reported at)}} for quarterbacks."""
    out = {}
    for team in (payload or {}).get('injuries') or []:
        code = _names().get(team.get('displayName'))
        if not code:
            continue
        for item in team.get('injuries') or []:
            athlete = item.get('athlete') or {}
            if ((athlete.get('position') or {}).get('abbreviation')) != 'QB':
                continue
            out.setdefault(code, {})[athlete.get('displayName') or ''] = (
                str(item.get('status') or ''), item.get('date'))
    return out


def _normal(name):
    return ''.join(ch for ch in str(name).lower() if ch.isalnum())


def _status_for(statuses, name):
    target = _normal(name)
    for listed, value in statuses.items():
        lowered = _normal(listed)
        if lowered == target or lowered.startswith(target) or target.startswith(lowered):
            return value
    return None


def _home_spread(rows):
    """Median home spread across books for one snapshot."""
    values = [row['line'] for row in rows if row.get('market') == 'spreads' and row.get('line') is not None
              and line_shop._side(row) == 'home']
    return statistics.median(values) if values else None


def _game_snapshots(observations, team, now):
    games = {}
    for row in observations:
        if team not in (row.get('home'), row.get('away')):
            continue
        kickoff = line_shop._parse(row.get('kickoff'))
        if kickoff is None or kickoff <= now or kickoff - now > timedelta(days=HORIZON_DAYS):
            continue
        games.setdefault(line_shop._game(row), {}).setdefault(row.get('at'), []).append(row)
    return games


def build_alerts(ratings, statuses, history, now):
    observations = [row for row in (history.get('observations') or []) if row.get('decimal')]
    players = [p for p in ratings.get('players') or [] if p.get('p') == 'QB']
    alerts = []
    for team in ratings.get('teams') or []:
        code, starter = team.get('t'), team.get('qb')
        if not code or not starter:
            continue
        status = _status_for(statuses.get(code, {}), starter)
        if not status or status[0].lower() not in OUT_STATUSES:
            continue
        reported_at = line_shop._parse(status[1])
        starter_row = next((p for p in players if p.get('t') == code and _normal(p.get('n')) == _normal(starter)), None)
        backups = [
            p for p in players if p.get('t') == code and _normal(p.get('n')) != _normal(starter)
            and not ((_status_for(statuses.get(code, {}), p.get('n')) or ('',))[0].lower() in OUT_STATUSES)
        ]
        backup = max(backups, key=lambda p: p.get('s') or 0) if backups else None
        for game, snaps in _game_snapshots(observations, code, now).items():
            times = sorted(snaps)
            before = [t for t in times if reported_at and line_shop._parse(t) and line_shop._parse(t) < reported_at]
            latest = times[-1]
            home = game[1] == code
            # Best price on the other team at the newest snapshot.
            other_side = 'away' if home else 'home'
            offers = [row for row in snaps[latest] if row.get('market') == 'spreads'
                      and line_shop._side(row) == other_side and row.get('book') != line_shop.SHARP_BOOK]
            best = max(offers, key=lambda row: (row['line'], row['decimal'])) if offers else None
            alerts.append({
                'loggedAt': now.isoformat().replace('+00:00', 'Z'),
                'team': code,
                'starter': starter,
                'status': status[0],
                'reportedAt': status[1],
                'backup': backup.get('n') if backup else None,
                'starterRating': starter_row.get('o') if starter_row else None,
                'backupRating': backup.get('o') if backup else None,
                'away': game[0], 'home': game[1], 'kickoff': snaps[latest][0].get('kickoff'),
                'homeSpreadBeforeReport': _home_spread(snaps[before[-1]]) if before else None,
                'homeSpreadNow': _home_spread(snaps[latest]),
                'priceAt': latest,
                'bet': None if best is None else {
                    'market': 'spreads', 'side': other_side, 'outcome': best.get('outcome'),
                    'line': best['line'], 'book': best['book'], 'decimal': best['decimal'],
                },
            })
    return alerts


def merge(log, alerts):
    rows = log.setdefault('alerts', [])
    seen = {(a['team'], a['starter'], a['home'], a['away'], a['kickoff']) for a in rows}
    added = 0
    for alert in alerts:
        key = (alert['team'], alert['starter'], alert['home'], alert['away'], alert['kickoff'])
        if key in seen:
            continue  # Keep the first sighting: that is the price we could have taken.
        rows.append(alert)
        seen.add(key)
        added += 1
    del rows[:-MAX_ALERTS]
    return added


def score(log, history, now):
    observations = [row for row in (history.get('observations') or []) if row.get('decimal')]
    closes, _ = line_shop._closing_fair(observations)
    values = []
    for alert in log.get('alerts') or []:
        kickoff = line_shop._parse(alert.get('kickoff'))
        bet = alert.get('bet')
        if not bet or kickoff is None or kickoff > now:
            continue
        flag = {**bet, 'away': alert['away'], 'home': alert['home'], 'kickoff': alert['kickoff'], 'player': ''}
        alert['clv'] = line_shop.clv_of(flag, closes)
        values.append(alert['clv'])
    summary = line_shop.summarize(values)
    passes, reason = line_shop.gate(summary)
    return {'clv': summary, 'passes': passes, 'reason': reason}


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(description='Watch for starting quarterbacks ruled out.')
    parser.add_argument('--ratings', default='assets/elo-ratings.json')
    parser.add_argument('--history', default='assets/price-history.json')
    parser.add_argument('--output', default='assets/qb-news.json')
    parser.add_argument('--injuries', help='A saved ESPN injuries response (for tests).')
    args = parser.parse_args(argv)
    now = datetime.now(timezone.utc)
    path = Path(args.output)
    log = json.loads(path.read_text()) if path.exists() else {'schema': SCHEMA, 'alerts': []}
    history = json.loads(Path(args.history).read_text())
    ratings = json.loads(Path(args.ratings).read_text())
    try:
        payload = json.loads(Path(args.injuries).read_text()) if args.injuries else fetch_injuries()
        alerts = build_alerts(ratings, quarterback_statuses(payload), history, now)
        log['source'] = {'status': 'ok', 'checkedAt': now.isoformat().replace('+00:00', 'Z')}
    except Exception as error:  # noqa: BLE001 - an unavailable feed is recorded, not invented
        alerts = []
        log['source'] = {'status': 'unavailable', 'detail': type(error).__name__,
                         'checkedAt': now.isoformat().replace('+00:00', 'Z')}
    added = merge(log, alerts)
    log['schema'] = SCHEMA
    log['notice'] = ('A starting quarterback listed out, the line before and after, and the price on the '
                     'other side when Coach first saw it. Research, not a pick.')
    log['current'] = alerts
    log['summary'] = score(log, history, now)
    path.write_text(json.dumps(log, indent=1) + '\n')
    print(json.dumps({'current': len(alerts), 'added': added, 'scored': log['summary']['clv']['n']}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
