"""Line shopping: compare each soft-book price with a sharp book's fair price.

A "sharp" book (Pinnacle) takes big bets and moves fast, so its price with
the margin removed is the best free estimate of the true chance. A soft book
whose price pays more than that fair chance is worth flagging. Whether a flag
is worth betting is a separate question, answered only by closing line value:
did the price we flagged beat the sharp book's last price before kickoff?

This module does three things:

1. ``flags_from_history`` reads assets/price-history.json and lists the soft
   prices that beat Pinnacle's fair price in the same Odds API snapshot.
2. ``history_clv`` scores earlier flags against Pinnacle's closing price.
3. ``backtest_propline`` runs the same rule on the free PropLine sample
   (CC BY 4.0), which has opening and closing prices for 20+ books.

A flag is research only. ``gate`` says whether the rule has beaten the close
on enough bets to be shown as a pick. Nothing here invents a price.
"""

import csv
import gzip
import io
import json
import math
import random
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCHEMA = 'coach-line-shop-v1'
SHARP_BOOK = 'pinnacle'
# Fair chances outside this range are long shots where a no-vig split is
# unreliable. Chosen before testing.
MIN_FAIR = 0.10
MAX_FAIR = 0.90
# A flag needs this much expected value against the fair price.
MIN_EDGE = 0.02
# The gate: at least this many scored bets, and the low end of the 90%
# bootstrap range of average closing line value must be above zero.
GATE_MIN_BETS = 200
BOOTSTRAP_ROUNDS = 2000
SEED = 20261123

# Logit change in the over chance per unit of line, used only to move a
# closing fair chance to a nearby line. Fit on PropLine closes across books
# (pairs of books posting different lines on the same prop). Game-line slopes
# are rough and only used to score a flag when the close moved off its line.
LOGIT_SLOPE = {
    'player_pass_yds': -0.0148,
    'player_reception_yds': -0.0387,
    'player_receptions': -0.6793,
    'player_rush_yds': -0.0378,
    'spreads': -0.13,
    'totals': -0.09,
}
# Never move a fair chance further than this many units of line.
MAX_SHIFT = {
    'player_pass_yds': 15,
    'player_reception_yds': 8,
    'player_receptions': 1,
    'player_rush_yds': 8,
    'spreads': 1.5,
    'totals': 2,
}

PROPLINE_URL = (
    'https://huggingface.co/datasets/propline/graded-player-props-sample/'
    'resolve/main/nfl_graded_props_14d.csv.gz'
)
PROPLINE_SOFT = (
    'draftkings', 'fanduel', 'betmgm', 'bovada', 'fanatics', 'betrivers',
    'hardrock', 'betway', 'fliff', 'betonlineag', 'courtside',
)


# ---------------------------------------------------------------- prices

def decimal_from_american(value):
    value = float(value)
    if value == 0:
        return None
    return 1 + value / 100 if value > 0 else 1 + 100 / abs(value)


def no_vig(first_decimal, second_decimal):
    """Fair chance of the first side, margin split in proportion."""
    if not first_decimal or not second_decimal or first_decimal <= 1 or second_decimal <= 1:
        return None
    a, b = 1 / first_decimal, 1 / second_decimal
    return a / (a + b)


def expected_value(chance, decimal):
    """Profit per unit staked if ``chance`` is the true chance."""
    return chance * decimal - 1


def shift_chance(chance, from_line, to_line, market, side='over'):
    """Move the chance of the over (or home cover) from one line to another.

    Returns None if the move is larger than MAX_SHIFT or the market has no
    slope. ``side`` is 'over' for totals and props and 'home' for spreads,
    where a home line of -3 moving to -3.5 makes the home cover less likely.
    """
    if chance is None:
        return None
    if from_line == to_line:
        return chance
    slope = LOGIT_SLOPE.get(market)
    limit = MAX_SHIFT.get(market)
    if slope is None or limit is None or abs(to_line - from_line) > limit:
        return None
    chance = min(max(chance, 1e-6), 1 - 1e-6)
    logit = math.log(chance / (1 - chance))
    if market == 'spreads':
        # The home line is a handicap: a bigger number helps the home side.
        logit += -slope * (to_line - from_line)
    else:
        logit += slope * (to_line - from_line)
    return 1 / (1 + math.exp(-logit))


def summarize(values, rounds=BOOTSTRAP_ROUNDS, seed=SEED):
    """Mean with a 90% bootstrap range. Empty input gives Nones."""
    values = [v for v in values if v is not None]
    if not values:
        return {'n': 0, 'mean': None, 'low': None, 'high': None}
    rng = random.Random(seed)
    n = len(values)
    means = []
    for _ in range(rounds):
        means.append(sum(values[rng.randrange(n)] for _ in range(n)) / n)
    means.sort()
    return {
        'n': n,
        'mean': round(sum(values) / n, 4),
        'low': round(means[int(0.05 * rounds)], 4),
        'high': round(means[int(0.95 * rounds) - 1], 4),
    }


def gate(clv_summary, min_bets=GATE_MIN_BETS):
    """Whether a rule may be shown as a pick: enough bets and CLV clearly above zero."""
    n = clv_summary.get('n') or 0
    low = clv_summary.get('low')
    if n < min_bets:
        return False, f'only {n} scored bets; {min_bets} are needed'
    if low is None or low <= 0:
        return False, 'closing line value is not clearly above zero'
    return True, 'beats the closing line'


# ------------------------------------------------------- price history

def _parse(value):
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _side(row):
    """'home'/'away' for h2h and spreads, 'over'/'under' for totals and props."""
    outcome = str(row.get('outcome') or '').strip()
    lowered = outcome.lower()
    if lowered in ('over', 'under'):
        return lowered
    home, away = row.get('home') or '', row.get('away') or ''
    names = _team_names()
    if outcome == names.get(home) or outcome == home:
        return 'home'
    if outcome == names.get(away) or outcome == away:
        return 'away'
    return None


_NAMES = None


def _team_names():
    global _NAMES
    if _NAMES is None:
        try:
            import line_timing
            _NAMES = dict(line_timing.NAMES)
        except ImportError:  # pragma: no cover
            _NAMES = {}
    return _NAMES


def _game(row):
    """A key that is the same for every book's copy of a game."""
    return (row.get('away') or '', row.get('home') or '', str(row.get('kickoff') or '')[:16])


def _pairs(rows):
    """Two-sided prices: {(game, market, player, book, at, home/over line): {side: row}}.

    For spreads the key line is the home line, so both sides share it.
    """
    out = {}
    for row in rows:
        side = _side(row)
        if side is None:
            continue
        market = row.get('market')
        line = row.get('line')
        if market == 'spreads':
            if line is None:
                continue
            key_line = line if side == 'home' else -line
        elif market == 'h2h':
            key_line = None
        else:
            if line is None:
                continue
            key_line = line
        key = (_game(row), market, row.get('player') or '', row.get('book'), row.get('at'), key_line)
        out.setdefault(key, {})[side] = row
    return out


def _fair_table(rows):
    """Pinnacle fair chances: {(game, market, player, at, line): (first-side chance, kickoff)}."""
    fair = {}
    for (game, market, player, book, at, line), sides in _pairs(rows).items():
        if book != SHARP_BOOK:
            continue
        first, second = ('home', 'away') if market in ('h2h', 'spreads') else ('over', 'under')
        if first not in sides or second not in sides:
            continue
        chance = no_vig(sides[first].get('decimal'), sides[second].get('decimal'))
        if chance is None:
            continue
        fair[(game, market, player, at, line)] = chance
    return fair


def _flag_rows(rows, min_edge=MIN_EDGE):
    """Every soft price that pays more than Pinnacle's fair price in the same snapshot."""
    fair = _fair_table(rows)
    flags = []
    for row in rows:
        book = row.get('book')
        if not book or book == SHARP_BOOK:
            continue
        side = _side(row)
        market = row.get('market')
        if side is None:
            continue
        line = row.get('line')
        if market == 'spreads':
            if line is None:
                continue
            key_line = line if side == 'home' else -line
        elif market == 'h2h':
            key_line = None
        else:
            key_line = line
        chance = fair.get((_game(row), market, row.get('player') or '', row.get('at'), key_line))
        if chance is None:
            continue
        if side in ('away', 'under'):
            chance = 1 - chance
        if not (MIN_FAIR <= chance <= MAX_FAIR):
            continue
        edge = expected_value(chance, row['decimal'])
        if edge < min_edge:
            continue
        flags.append({
            'at': row.get('at'),
            'kickoff': row.get('kickoff'),
            'away': row.get('away'),
            'home': row.get('home'),
            'market': market,
            'player': row.get('player') or '',
            'side': side,
            'outcome': row.get('outcome'),
            'line': line,
            'book': book,
            'decimal': row['decimal'],
            'fairChance': round(chance, 4),
            'edge': round(edge, 4),
        })
    # One flag per bet: the best-paying book.
    best = {}
    for flag in flags:
        key = (flag['at'], flag['away'], flag['home'], flag['market'], flag['player'], flag['side'], flag['line'])
        if key not in best or flag['decimal'] > best[key]['decimal']:
            best[key] = flag
    return sorted(best.values(), key=lambda f: -f['edge'])


def flags_from_history(history, now=None, min_edge=MIN_EDGE):
    """Flags from the newest snapshot of each game that has not kicked off."""
    now = now or datetime.now(timezone.utc)
    rows = [
        row for row in (history.get('observations') or [])
        if (_parse(row.get('kickoff')) or now) > now and row.get('decimal')
    ]
    latest = {}
    for row in rows:
        if row.get('book') != SHARP_BOOK:
            continue
        game = _game(row)
        at = row.get('at')
        if game not in latest or (at or '') > (latest[game] or ''):
            latest[game] = at
    current = [row for row in rows if latest.get(_game(row)) == row.get('at')]
    return _flag_rows(current, min_edge=min_edge)


def _closing_fair(rows):
    """Pinnacle's last fair chance before kickoff for each game, market and player.

    {(game, market, player): [(line, first-side chance)]} from the last
    Pinnacle snapshot before kickoff (every line posted in that snapshot).
    """
    fair = _fair_table(rows)
    last_at = {}
    kickoffs = {}
    for row in rows:
        kickoffs[_game(row)] = _parse(row.get('kickoff'))
    for (game, market, player, at, line), _chance in fair.items():
        kickoff = kickoffs.get(game)
        parsed = _parse(at)
        if kickoff is None or parsed is None or parsed >= kickoff:
            continue
        key = (game, market, player)
        if key not in last_at or at > last_at[key]:
            last_at[key] = at
    out = {}
    for (game, market, player, at, line), chance in fair.items():
        if last_at.get((game, market, player)) == at:
            out.setdefault((game, market, player), []).append((line, chance))
    return out, last_at


def clv_of(flag, closes):
    """Closing line value of one flag: Pinnacle's closing fair chance times the flagged price, minus one."""
    game = (flag.get('away') or '', flag.get('home') or '', str(flag.get('kickoff') or '')[:16])
    options = closes.get((game, flag['market'], flag.get('player') or ''))
    if not options:
        return None
    market = flag['market']
    side = flag['side']
    if market == 'h2h':
        chance = options[0][1]
    else:
        # Spreads are keyed by the home line; an away line of +3 is home -3.
        target = -flag['line'] if (market == 'spreads' and side == 'away') else flag['line']
        line, chance = min(options, key=lambda item: abs(item[0] - target))
        chance = shift_chance(chance, line, target, market)
        if chance is None:
            return None
    if side in ('away', 'under'):
        chance = 1 - chance
    return round(expected_value(chance, flag['decimal']), 4)


def history_clv(history, min_edge=MIN_EDGE):
    """Score every flag from every pre-close snapshot against Pinnacle's close."""
    rows = [row for row in (history.get('observations') or []) if row.get('decimal')]
    closes, last_at = _closing_fair(rows)
    by_at = {}
    for row in rows:
        by_at.setdefault(row.get('at'), []).append(row)
    scored = []
    for at, group in by_at.items():
        for flag in _flag_rows(group, min_edge=min_edge):
            game = (flag['away'] or '', flag['home'] or '', str(flag['kickoff'] or '')[:16])
            close_at = last_at.get((game, flag['market'], flag['player']))
            if close_at is None or at >= close_at:
                continue  # Only flags made before the close can be scored.
            value = clv_of(flag, closes)
            if value is not None:
                scored.append({**flag, 'clv': value})
    return scored


# ------------------------------------------------------------ PropLine

def load_propline(path=None, fetch=None):
    """Rows of the PropLine NFL sample. Downloads it when no path is given."""
    if path and Path(path).exists():
        raw = Path(path).read_bytes()
    else:
        fetch = fetch or (lambda url: urllib.request.urlopen(url, timeout=120).read())
        raw = fetch(PROPLINE_URL)
        if path:
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            Path(path).write_bytes(raw)
    text = gzip.decompress(raw).decode('utf-8') if raw[:2] == b'\x1f\x8b' else raw.decode('utf-8')
    return list(csv.DictReader(io.StringIO(text)))


def _num(value):
    try:
        return float(value) if value not in (None, '') else None
    except ValueError:
        return None


def propline_quotes(rows):
    """One open and close per book, game, market, player and side."""
    quotes = {}
    for row in rows:
        key = (row['event_id'], row['bookmaker'], row['market'], row['player_name'], row['outcome_name'].lower())
        if key in quotes:
            if quotes[key]['actual'] is None:
                quotes[key]['actual'] = _num(row.get('actual_value'))
            continue
        quotes[key] = {
            'kickoff': _parse(row['commence_time']),
            'openLine': _num(row.get('opening_point')),
            'openPrice': _num(row.get('opening_price')),
            'openAt': _parse(row.get('opening_at')),
            'closeLine': _num(row.get('closing_point')),
            'closePrice': _num(row.get('closing_price')),
            'closeAt': _parse(row.get('closing_at')),
            'actual': _num(row.get('actual_value')),
        }
    return quotes


def _book_fair(quotes, event, book, market, player, when):
    """(line, over chance, time) for one book's open or close, two-sided at one line."""
    over = quotes.get((event, book, market, player, 'over'))
    under = quotes.get((event, book, market, player, 'under'))
    if not over or not under:
        return None
    line_key, price_key, at_key = (
        ('openLine', 'openPrice', 'openAt') if when == 'open' else ('closeLine', 'closePrice', 'closeAt')
    )
    if over[line_key] is None or over[line_key] != under[line_key]:
        return None
    if over[price_key] is None or under[price_key] is None:
        return None
    chance = no_vig(decimal_from_american(over[price_key]), decimal_from_american(under[price_key]))
    if chance is None:
        return None
    return over[line_key], chance, over[at_key]


def backtest_propline(rows, reference=SHARP_BOOK, min_edge=MIN_EDGE, soft=PROPLINE_SOFT):
    """Two tests of the line-shopping rule on PropLine props.

    open: a soft book's opening price is compared with the reference book's
      opening fair price at the same line, only when the reference had
      opened first (no look-ahead). Flags are scored by closing line value
      against Pinnacle's close, moved to the flagged line when needed.
    close: a soft book's closing price against Pinnacle's closing fair price
      at the same line. Closing line value is zero by construction here, so
      these flags are scored by the actual result (profit per unit).
    """
    quotes = propline_quotes(rows)
    props = {(e, m, p) for (e, _b, m, p, _s) in quotes}
    open_bets, close_bets = {}, {}
    baseline = []
    for event, market, player in props:
        ref = _book_fair(quotes, event, reference, market, player, 'open')
        pin_close = _book_fair(quotes, event, SHARP_BOOK, market, player, 'close')
        if pin_close is None:
            continue
        close_line, close_over, _ = pin_close
        for book in soft:
            for side in ('over', 'under'):
                quote = quotes.get((event, book, market, player, side))
                if not quote:
                    continue
                # Open test.
                if ref is not None and quote['openPrice'] is not None and quote['openLine'] is not None:
                    ref_line, ref_over, ref_at = ref
                    if ref_at is not None and quote['openAt'] is not None and ref_at <= quote['openAt'] \
                            and ref_line == quote['openLine']:
                        fair = ref_over if side == 'over' else 1 - ref_over
                        decimal = decimal_from_american(quote['openPrice'])
                        moved = shift_chance(close_over, close_line, quote['openLine'], market)
                        if moved is not None and MIN_FAIR <= fair <= MAX_FAIR:
                            close_fair = moved if side == 'over' else 1 - moved
                            clv = expected_value(close_fair, decimal)
                            baseline.append(clv)
                            edge = expected_value(fair, decimal)
                            key = (event, market, player, side)
                            if edge >= min_edge and (key not in open_bets or edge > open_bets[key]['edge']):
                                open_bets[key] = {'edge': edge, 'clv': clv, 'book': book}
                # Close test.
                if quote['closePrice'] is not None and quote['closeLine'] == close_line:
                    fair = close_over if side == 'over' else 1 - close_over
                    decimal = decimal_from_american(quote['closePrice'])
                    actual = quote['actual']
                    if actual is None or actual == close_line or not (MIN_FAIR <= fair <= MAX_FAIR):
                        continue
                    won = (actual > close_line) == (side == 'over')
                    edge = expected_value(fair, decimal)
                    key = (event, market, player, side)
                    if edge >= min_edge and (key not in close_bets or edge > close_bets[key]['edge']):
                        close_bets[key] = {'edge': edge, 'profit': (decimal - 1) if won else -1.0, 'book': book}
    open_clv = summarize([bet['clv'] for bet in open_bets.values()])
    open_ok, open_reason = gate(open_clv)
    return {
        'reference': reference,
        'minEdge': min_edge,
        'open': {
            'allSoftOpensClv': summarize(baseline, rounds=200),
            'flags': len(open_bets),
            'averageEdge': _mean([bet['edge'] for bet in open_bets.values()]),
            'clv': open_clv,
            'beatClose': _mean([1.0 if bet['clv'] > 0 else 0.0 for bet in open_bets.values()]),
            'passes': open_ok,
            'reason': open_reason,
        },
        'close': {
            'flags': len(close_bets),
            'averageEdge': _mean([bet['edge'] for bet in close_bets.values()]),
            'profitPerUnit': summarize([bet['profit'] for bet in close_bets.values()]),
        },
    }


def _mean(values):
    values = list(values)
    return round(sum(values) / len(values), 4) if values else None


# ---------------------------------------------------------------- report

def build_report(history, propline_results=None, now=None):
    now = now or datetime.now(timezone.utc)
    flags = flags_from_history(history, now=now)
    scored = history_clv(history)
    live_clv = summarize([row['clv'] for row in scored])
    live_ok, live_reason = gate(live_clv)
    propline_ok = bool(propline_results) and all(
        result['open']['passes'] for result in propline_results.values()
        if result['reference'] == SHARP_BOOK
    )
    adopted = live_ok and propline_ok
    return {
        'schema': SCHEMA,
        'updatedAt': now.isoformat().replace('+00:00', 'Z'),
        'notice': (
            'Soft-book prices that pay more than Pinnacle\'s price with the margin '
            'removed. Research only. A flag becomes a pick only after flags like it '
            'have beaten the closing line on at least 200 bets.'
        ),
        'rule': {
            'sharpBook': SHARP_BOOK,
            'minEdge': MIN_EDGE,
            'fairRange': [MIN_FAIR, MAX_FAIR],
            'gateMinBets': GATE_MIN_BETS,
        },
        'adopted': adopted,
        'adoptedReason': 'beats the closing line in the live record and the PropLine sample'
        if adopted else (live_reason if not live_ok else 'the PropLine sample did not beat the close'),
        'live': {
            'clv': live_clv,
            'beatClose': _mean([1.0 if row['clv'] > 0 else 0.0 for row in scored]),
            'recent': scored[-25:],
        },
        'propline': propline_results or {},
        'flags': flags[:100],
    }


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(description='Flag soft prices against Pinnacle and score them by closing line value.')
    parser.add_argument('--history', default='assets/price-history.json')
    parser.add_argument('--output', default='assets/line-shop.json')
    parser.add_argument('--propline', help='Path to the PropLine NFL csv.gz (downloaded if missing).')
    parser.add_argument('--propline-results', default='research/line-shop/propline_backtest.json')
    args = parser.parse_args(argv)
    history = json.loads(Path(args.history).read_text())
    propline_results = None
    results_path = Path(args.propline_results)
    if args.propline:
        rows = load_propline(args.propline)
        propline_results = {}
        for reference in (SHARP_BOOK, 'prophetx', 'novig'):
            propline_results[reference] = backtest_propline(rows, reference=reference)
        results_path.parent.mkdir(parents=True, exist_ok=True)
        results_path.write_text(json.dumps({
            'source': 'PropLine graded player props sample (NFL, 2026-09-18 to 2026-09-29)',
            'sourceUrl': 'https://huggingface.co/datasets/propline/graded-player-props-sample',
            'license': 'CC BY 4.0',
            'results': propline_results,
        }, indent=2) + '\n')
    elif results_path.exists():
        propline_results = json.loads(results_path.read_text()).get('results')
    report = build_report(history, propline_results)
    Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({
        'flags': len(report['flags']),
        'liveScored': report['live']['clv']['n'],
        'adopted': report['adopted'],
    }))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
