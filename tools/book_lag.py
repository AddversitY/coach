"""Which book is slowest to move, per market, and its stale prices right now.

Backtest (PropLine sample, CC BY 4.0: open and close for 20+ books on 32
games): for every prop where Pinnacle's fair over chance moved 3+ points
from open to close, how much of that move each book's own price followed
(1.0 = fully, 0 = not at all), and how far each book's close still sat from
Pinnacle's close. Both are measured at Pinnacle's closing line.

Live: the Worker saves FanDuel, Bovada and BetRivers props every hour or so,
and price-history.json holds the Odds API game lines. When two or more books
move a line the same way, the hours each other book took to match it are the
lag. Books still on the old number are logged as a bet on the stale side with
their price, and scored by closing line value (tools/edge_log.py).

Output: assets/book-lag.json. Research, not a pick.
"""

import json
import statistics
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import edge_log
import line_shop

SCHEMA = 'coach-book-lag-v1'
MIN_SHARP_MOVE = 0.03
MIN_MOVERS = 2


# ---------------------------------------------------------------- backtest

def backtest(rows):
    quotes = line_shop.propline_quotes(rows)
    books = {b for (_e, b, _m, _p, _s) in quotes}
    props = {(e, m, p) for (e, _b, m, p, _s) in quotes}
    follow, gap, value = defaultdict(list), defaultdict(list), defaultdict(list)
    for event, market, player in props:
        pin_open = line_shop._book_fair(quotes, event, line_shop.SHARP_BOOK, market, player, 'open')
        pin_close = line_shop._book_fair(quotes, event, line_shop.SHARP_BOOK, market, player, 'close')
        if not pin_open or not pin_close:
            continue
        line = pin_close[0]
        p_open = line_shop.shift_chance(pin_open[1], pin_open[0], line, market)
        if p_open is None:
            continue
        move = pin_close[1] - p_open
        for book in books - {line_shop.SHARP_BOOK}:
            b_open = line_shop._book_fair(quotes, event, book, market, player, 'open')
            b_close = line_shop._book_fair(quotes, event, book, market, player, 'close')
            if not b_open or not b_close:
                continue
            o = line_shop.shift_chance(b_open[1], b_open[0], line, market)
            c = line_shop.shift_chance(b_close[1], b_close[0], line, market)
            if o is None or c is None:
                continue
            gap[(book, market)].append(abs(c - pin_close[1]))
            if abs(move) >= MIN_SHARP_MOVE:
                follow[(book, market)].append(max(-1.0, min(2.0, (c - o) / move)))
                # Bet the side Pinnacle moved toward, at this book's closing price on Pinnacle's line.
                side = 'over' if move > 0 else 'under'
                quote = quotes.get((event, book, market, player, side))
                if quote and quote['closeLine'] == line and quote['closePrice'] is not None:
                    fair = pin_close[1] if side == 'over' else 1 - pin_close[1]
                    value[(book, market)].append(
                        line_shop.expected_value(fair, line_shop.decimal_from_american(quote['closePrice'])))
    table = []
    for key in sorted(set(follow) | set(gap)):
        f, g = follow.get(key, []), gap.get(key, [])
        if len(g) < 20:
            continue
        table.append({'book': key[0], 'market': key[1], 'props': len(g), 'sharpMoves': len(f),
                      'followShare': round(statistics.median(f), 3) if len(f) >= 10 else None,
                      'closeGapToPinnacle': round(statistics.mean(g), 4),
                      'staleSideValue': line_shop.summarize(value.get(key, []), rounds=500)})
    by_market = defaultdict(list)
    for row in table:
        if row['followShare'] is not None:
            by_market[row['market']].append(row)
    slowest = {m: sorted(r, key=lambda x: (x['followShare'], -x['closeGapToPinnacle']))[0]['book']
               for m, r in by_market.items() if r}
    return {'books': table, 'slowestByMarket': slowest,
            'howToRead': ('followShare: median share of Pinnacle\'s open-to-close move that the book followed. '
                          'staleSideValue: value of betting the side Pinnacle moved toward at the book\'s closing '
                          'price, judged by Pinnacle\'s close (zero = fair, above zero = the book was too slow).')}


# ---------------------------------------------------------------- live

def _series(rows):
    """{(game, market, player, side): {book: [(at, line, decimal)]}} sorted by time."""
    out = defaultdict(lambda: defaultdict(list))
    for row in rows:
        side = line_shop._side(row)
        if side is None or row.get('line') is None or row.get('market') == 'h2h':
            continue
        out[(line_shop._game(row), row['market'], row.get('player') or '', side)][row['book']].append(
            (str(row['at']), float(row['line']), row['decimal'], row))
    for books in out.values():
        for quotes in books.values():
            quotes.sort(key=lambda q: q[0])
    return out


def lags(rows):
    """Hours each book took to match a move made first by 2+ books, per market."""
    hours = defaultdict(list)
    never = defaultdict(int)
    for (game, market, player, side), books in _series(rows).items():
        if side in ('under', 'away'):
            continue  # Same line move as the other side; count it once.
        changes = []  # (at, book, old, new)
        for book, quotes in books.items():
            for (a0, l0, _d0, _r0), (a1, l1, _d1, _r1) in zip(quotes, quotes[1:]):
                if l1 != l0:
                    changes.append((a1, book, l0, l1))
        changes.sort()
        for i, (at, book, old, new) in enumerate(changes):
            direction = 1 if new > old else -1
            movers = {b for a, b, o, n in changes[:i + 1] if (1 if n > o else -1) == direction and o == old}
            if len(movers) != MIN_MOVERS:
                continue
            for other, quotes in books.items():
                if other in movers:
                    continue
                before = [q for q in quotes if q[0] <= at]
                if not before or before[-1][1] != old:
                    continue
                after = [q for q in quotes if q[0] > at and (q[1] - old) * direction > 0]
                if after:
                    t0 = line_shop._parse(at)
                    t1 = line_shop._parse(after[0][0])
                    hours[(other, market)].append((t1 - t0).total_seconds() / 3600)
                else:
                    never[(other, market)] += 1
    table = []
    for key in sorted(set(hours) | set(never)):
        h = hours.get(key, [])
        table.append({'book': key[0], 'market': key[1], 'moves': len(h) + never.get(key, 0),
                      'medianHoursToMatch': round(statistics.median(h), 2) if h else None,
                      'neverMatched': never.get(key, 0)})
    return table


def stale_now(rows, now):
    """Books still on the old number after 2+ other books moved the same way (newest quote each)."""
    current = []
    for (game, market, player, side), books in _series(rows).items():
        kickoff = line_shop._parse(game[2])
        if kickoff is None or kickoff <= now:
            continue
        newest = {b: q[-1] for b, q in books.items()}
        first = {b: q[0] for b, q in books.items()}
        if len(newest) < 3:
            continue
        latest_at = max(q[0] for q in newest.values())
        for book, (at, line, decimal, row) in newest.items():
            if book == line_shop.SHARP_BOOK or first[book][1] != line:
                continue
            # Only books still quoting in the newest snapshot (within two hours of it).
            if (line_shop._parse(latest_at) - line_shop._parse(at)).total_seconds() > 7200:
                continue
            movers = [b for b in newest if b != book and first[b][1] == line and newest[b][1] != line]
            up = [b for b in movers if newest[b][1] > line]
            down = [b for b in movers if newest[b][1] < line]
            if len(up) >= MIN_MOVERS and not down:
                direction = 1
            elif len(down) >= MIN_MOVERS and not up:
                direction = -1
            else:
                continue
            # Keep only the side the stale number favors. Totals and props: the market went up, so the
            # over at the old, lower number is the better bet. Spreads (line is this side's handicap):
            # other books now give this side fewer points, so the stale book's extra points are the value.
            if market == 'spreads':
                if direction > 0:
                    continue
            elif (side == 'over') != (direction > 0):
                continue
            current.append({
                'away': game[0], 'home': game[1], 'kickoff': row.get('kickoff'), 'angle': f'slow book ({market})',
                'staleBook': book, 'movedBooks': sorted(up or down), 'checkedAt': edge_log.iso(now),
                'bet': {'market': market, 'side': side, 'outcome': row.get('outcome'), 'line': line, 'book': book,
                        'decimal': decimal, 'priceAt': at, 'player': player},
            })
    return current


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(description='Per-book slowness and stale prices.')
    parser.add_argument('--history', default='assets/price-history.json')
    parser.add_argument('--book-prices', default=None, help='Worker /v1/book-prices JSON (optional).')
    parser.add_argument('--propline', default=None, help='PropLine sample path (downloaded when missing).')
    parser.add_argument('--backtest', action='store_true')
    parser.add_argument('--output', default='assets/book-lag.json')
    args = parser.parse_args(argv)
    now = datetime.now(timezone.utc)
    path = Path(args.output)
    log = json.loads(path.read_text()) if path.exists() else {'schema': SCHEMA, 'alerts': []}
    rows = edge_log.normalize(json.loads(Path(args.history).read_text()).get('observations'))
    if args.book_prices and Path(args.book_prices).exists():
        rows += edge_log.normalize(json.loads(Path(args.book_prices).read_text()).get('observations'))
    if args.backtest:
        log['backtest'] = {'source': 'PropLine NFL sample (CC BY 4.0), Sep 18-29 2026',
                           **backtest(line_shop.load_propline(args.propline))}
    current = stale_now(rows, now)
    added = edge_log.merge(log, current, ('away', 'home', 'kickoff', 'angle', 'staleBook'))
    log.update({'schema': SCHEMA, 'live': lags(rows), 'current': current, 'summary': edge_log.score(log, rows, now),
                'notice': 'Which book is slowest to follow a move, and its stale prices now. Research, not a pick.'})
    path.write_text(json.dumps(log, indent=1) + '\n')
    print(json.dumps({'stale': len(current), 'new': added, 'slowest': (log.get('backtest') or {}).get('slowestByMarket')}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
