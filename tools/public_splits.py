"""Public betting splits: fade the crowd, or follow the money, scored by closing line value.

Source: SportsBettingDime's public JSON (the feed behind its free betting
trends page): share of bets (tickets) and share of money (handle) per side
for the spread, total and moneyline. Free, no key, read at most hourly.

docs/PUBLIC_SHARP.md found no free source whose terms let Coach *display*
these percentages, so this log keeps only the signal and its bucket, never
the raw numbers, and nothing here is shown in the app. It is research.

Signals (chosen before any scoring):
- fade the public: 70%+ of bets on one side -> bet the other side.
- follow the money: the share of money on a side is 15+ points above its
  share of bets -> bet that side (bigger bettors on it).

No free history of splits with lines exists (earlier tests on paid-site
samples found nothing), so the test is live: each signal is logged with the
best price when first seen and scored against the close by tools/edge_log.py.

Output: assets/public-splits.json.
"""

import json
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

import edge_log

SCHEMA = 'coach-public-splits-v1'
URL = 'https://www.sportsbettingdime.com/wp-json/adpt/v1/nfl-odds?format=us'
FADE_BETS = 70.0
MONEY_GAP = 15.0
HORIZON_DAYS = 7
MARKETS = {'spread': ('spreads', 'home', 'away'), 'total': ('totals', 'over', 'under'),
           'moneyline': ('h2h', 'home', 'away')}


def fetch(fetcher=None):
    fetcher = fetcher or (lambda url: urllib.request.urlopen(
        urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (coach research)'}), timeout=30).read())
    return json.loads(fetcher(URL))


def _pct(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _bucket(value):
    return '80%+' if value >= 80 else ('70-80%' if value >= 70 else ('60-70%' if value >= 60 else 'under 60%'))


def signals(payload, now):
    """[(away, home, kickoff, angle, market, side, bucket)] for games in the next week."""
    out = []
    for game in (payload or {}).get('data') or []:
        kickoff = datetime.fromisoformat(str(game.get('scheduled')).replace('Z', '+00:00'))
        if kickoff <= now or kickoff - now > timedelta(days=HORIZON_DAYS):
            continue
        teams = game.get('competitors') or {}
        away = (teams.get('away') or {}).get('abbreviation')
        home = (teams.get('home') or {}).get('abbreviation')
        splits = game.get('bettingSplits') or {}
        if not away or not home:
            continue
        away, home = edge_log.CODES.get(away, away), edge_log.CODES.get(home, home)
        for name, (market, first, second) in MARKETS.items():
            block = splits.get(name) or {}
            a, b = block.get(first) or {}, block.get(second) or {}
            bets = {first: _pct(a.get('betsPercentage')), second: _pct(b.get('betsPercentage'))}
            money = {first: _pct(a.get('stakePercentage')), second: _pct(b.get('stakePercentage'))}
            if None in bets.values() or None in money.values():
                continue
            for side, other in ((first, second), (second, first)):
                if bets[side] >= FADE_BETS:
                    out.append((away, home, kickoff, f'fade the public ({name})', market, other, _bucket(bets[side])))
                if money[side] - bets[side] >= MONEY_GAP:
                    out.append((away, home, kickoff, f'follow the money ({name})', market, side,
                                f'money {int((money[side] - bets[side]) // 5 * 5)}+ points over bets'))
    return out


def build(payload, rows, now):
    current = []
    for away, home, kickoff, angle, market, side, bucket in signals(payload, now):
        row = {'away': away, 'home': home, 'kickoff': edge_log.iso(kickoff), 'angle': angle, 'bucket': bucket,
               'checkedAt': edge_log.iso(now)}
        bet = edge_log.best_price(rows, away, home, market, side, now=now)
        if bet:
            row['bet'] = bet
            row['kickoff'] = bet.get('kickoff') or row['kickoff']
        current.append(row)
    return current


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(description='Public betting splits, logged and scored by CLV.')
    parser.add_argument('--history', default='assets/price-history.json')
    parser.add_argument('--output', default='assets/public-splits.json')
    args = parser.parse_args(argv)
    now = datetime.now(timezone.utc)
    path = Path(args.output)
    log = json.loads(path.read_text()) if path.exists() else {'schema': SCHEMA, 'alerts': []}
    rows = edge_log.normalize(json.loads(Path(args.history).read_text()).get('observations'))
    try:
        current = build(fetch(), rows, now)
        log['source'] = {'status': 'ok', 'checkedAt': edge_log.iso(now), 'provider': 'SportsBettingDime public feed'}
    except Exception as error:  # noqa: BLE001 - an unavailable feed is recorded, not invented
        current = []
        log['source'] = {'status': 'unavailable', 'detail': type(error).__name__}
    added = edge_log.merge(log, current, ('away', 'home', 'kickoff', 'angle'))
    log.update({'schema': SCHEMA, 'current': current, 'summary': edge_log.score(log, rows, now),
                'notice': ('Research only, never shown in the app. Signal buckets only; raw percentages are not '
                           'stored because no free source grants a display right.')})
    path.write_text(json.dumps(log, indent=1) + '\n')
    print(json.dumps({'signals': len(current), 'new': added}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
