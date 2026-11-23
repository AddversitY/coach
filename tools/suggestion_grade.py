"""Keep a log of Coach's suggestions and grade them by closing line value.

hosting/suggestion-log.mjs runs the Worker's own game analysis on the newest
saved prices and writes Coach's top ranked rows for every upcoming game. This
file appends those rows to assets/suggestion-log.json (one row per suggestion,
price and time kept as they were), then grades every row whose game has a
saved close:

- CLV against Pinnacle: Pinnacle's last fair chance before kickoff times the
  suggested price, minus one (tools/line_shop.py, same line or a small,
  capped line move).
- CLV against the market: the same, using the median no-vig closing chance of
  the other books when Pinnacle is missing.
- Result: win, loss or push from the final score (game markets only).

The summary gates the same way as line shopping: 200 scored suggestions and
the low end of the 90% range above zero before anything is called an edge.
"""

import json
import statistics
from datetime import datetime, timezone
from pathlib import Path

import line_shop

SCHEMA = 'coach-suggestion-log-v1'
MAX_ROWS = 20000


def _key(row):
    return (row.get('eventId'), row.get('market'), row.get('player') or '', row.get('side'), row.get('line'), row.get('book'))


def append(log, suggestions):
    """Add new suggestions. A suggestion is new when its price, book or line changed."""
    rows = log.setdefault('rows', [])
    last = {}
    for row in rows:
        last[(row.get('eventId'), row.get('market'), row.get('player') or '', row.get('side'))] = row
    added = 0
    for row in suggestions:
        ident = (row.get('eventId'), row.get('market'), row.get('player') or '', row.get('side'))
        prior = last.get(ident)
        if prior and prior.get('line') == row.get('line') and prior.get('decimal') == row.get('decimal') \
                and prior.get('book') == row.get('book'):
            continue
        rows.append(row)
        last[ident] = row
        added += 1
    if len(rows) > MAX_ROWS:
        del rows[: len(rows) - MAX_ROWS]
    return added


def _market_closes(observations):
    """Median no-vig closing chance of the non-Pinnacle books, per game, market, player and line."""
    pairs = line_shop._pairs(observations)
    kickoffs = {line_shop._game(row): line_shop._parse(row.get('kickoff')) for row in observations}
    last = {}
    for (game, market, player, book, at, line), sides in pairs.items():
        if book == line_shop.SHARP_BOOK:
            continue
        kickoff = kickoffs.get(game)
        parsed = line_shop._parse(at)
        if kickoff is None or parsed is None or parsed >= kickoff:
            continue
        first, second = ('home', 'away') if market in ('h2h', 'spreads') else ('over', 'under')
        if first not in sides or second not in sides:
            continue
        chance = line_shop.no_vig(sides[first].get('decimal'), sides[second].get('decimal'))
        if chance is None:
            continue
        key = (game, market, player, book)
        if key not in last or at > last[key][0]:
            last[key] = (at, {})
        if last[key][0] == at:
            last[key][1][line] = chance
    merged = {}
    for (game, market, player, _book), (_at, lines) in last.items():
        for line, chance in lines.items():
            merged.setdefault((game, market, player), {}).setdefault(line, []).append(chance)
    return {
        key: [(line, statistics.median(values)) for line, values in lines.items()]
        for key, lines in merged.items()
    }


def _result(row, games):
    """'win', 'loss' or 'push' for a game market from the final score, else None."""
    event = str(row.get('eventId') or '')
    if not event.startswith('nflverse:') or row.get('market') not in ('h2h', 'spreads', 'totals'):
        return None
    parts = event.split(':', 1)[1].split('_')
    if len(parts) < 4:
        return None
    season, week, away, home = int(parts[0]), int(parts[1]), parts[2], parts[3]
    game = games.get((season, week, home, away))
    if not game or game.get('homeScore') is None or game.get('awayScore') is None:
        return None
    home_score, away_score = game['homeScore'], game['awayScore']
    side, line, market = row['side'], row.get('line'), row['market']
    if market == 'h2h':
        diff = (home_score - away_score) * (1 if side == 'home' else -1)
    elif market == 'spreads':
        diff = (home_score - away_score) * (1 if side == 'home' else -1) + line
    else:
        diff = (home_score + away_score - line) * (1 if side == 'over' else -1)
    return 'win' if diff > 0 else 'loss' if diff < 0 else 'push'


def grade(log, history, closing_games=None, now=None):
    observations = [row for row in (history.get('observations') or []) if row.get('decimal')]
    sharp, _ = line_shop._closing_fair(observations)
    market = _market_closes(observations)
    games = {}
    for game in (closing_games or {}).get('games') or []:
        games[(game['season'], game['week'], game['home'], game['away'])] = game
    now = now or datetime.now(timezone.utc)
    graded = []
    for row in log.get('rows') or []:
        kickoff = line_shop._parse(row.get('kickoff'))
        if kickoff is None or kickoff > now:
            continue  # No close yet.
        flag = {**row}
        if flag.get('market') == 'spreads' and flag.get('line') is None:
            continue
        sharp_clv = line_shop.clv_of(flag, sharp)
        market_clv = line_shop.clv_of(flag, market)
        result = _result(row, games)
        if sharp_clv is None and market_clv is None and result is None:
            continue
        graded.append({
            **row,
            'clvPinnacle': sharp_clv,
            'clvMarket': market_clv,
            'result': result,
            'profit': None if result is None else (row['decimal'] - 1 if result == 'win' else 0.0 if result == 'push' else -1.0),
        })
    return graded


def summary(graded):
    out = {}
    groups = {'all': graded}
    for row in graded:
        groups.setdefault(row['market'] if row['market'] in ('h2h', 'spreads', 'totals') else 'props', []).append(row)
    for name, rows in groups.items():
        clv = line_shop.summarize([row['clvPinnacle'] if row['clvPinnacle'] is not None else row['clvMarket'] for row in rows])
        passes, reason = line_shop.gate(clv)
        out[name] = {
            'suggestions': len(rows),
            'clv': clv,
            'clvPinnacle': line_shop.summarize([row['clvPinnacle'] for row in rows], rounds=500),
            'beatClose': line_shop._mean(
                1.0 if (row['clvPinnacle'] if row['clvPinnacle'] is not None else row['clvMarket']) > 0 else 0.0
                for row in rows
                if (row['clvPinnacle'] if row['clvPinnacle'] is not None else row['clvMarket']) is not None
            ),
            'profitPerUnit': line_shop.summarize([row['profit'] for row in rows], rounds=500),
            'passes': passes,
            'reason': reason,
        }
    return out


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(description='Log and grade Coach suggestions by closing line value.')
    parser.add_argument('--suggestions', help='Output of hosting/suggestion-log.mjs')
    parser.add_argument('--log', default='assets/suggestion-log.json')
    parser.add_argument('--history', default='assets/price-history.json')
    parser.add_argument('--closing-lines', default='assets/closing-lines.json')
    args = parser.parse_args(argv)
    path = Path(args.log)
    log = json.loads(path.read_text()) if path.exists() else {'schema': SCHEMA, 'rows': []}
    added = 0
    if args.suggestions and Path(args.suggestions).exists():
        added = append(log, json.loads(Path(args.suggestions).read_text()).get('suggestions') or [])
    history = json.loads(Path(args.history).read_text())
    closing = json.loads(Path(args.closing_lines).read_text()) if Path(args.closing_lines).exists() else None
    graded = grade(log, history, closing)
    log['schema'] = SCHEMA
    log['updatedAt'] = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
    log['notice'] = (
        "Coach's top ranked rows for each upcoming game, saved with the price and time shown, "
        'then graded by closing line value. A record, not a pick.'
    )
    log['summary'] = summary(graded)
    log['recentGraded'] = graded[-40:]
    path.write_text(json.dumps(log, indent=1) + '\n')
    print(json.dumps({'added': added, 'rows': len(log['rows']), 'graded': len(graded)}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
