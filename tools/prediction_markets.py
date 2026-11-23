"""Kalshi NFL prices against the sportsbooks.

Kalshi is a regulated US exchange with free public data (no key): NFL game
winners (KXNFLGAME), spreads (KXNFLSPREAD) and totals (KXNFLTOTAL), plus some
player markets. An exchange has no house margin built into its prices (a small
trading fee instead), so its mid price is a second free "sharp" reference
next to Pinnacle, and sometimes a better price to bet at.

Two parts:

backtest  Every settled 2026 game-winner market: Kalshi's mid price 24 hours
          and 1 hour before kickoff (hourly price history), against the
          sportsbook closing moneyline (nflverse, margin removed) and the
          result. Is Kalshi as accurate as the close? Does the close move
          toward Kalshi's earlier price?
live      Kalshi's current game-winner mids next to the newest saved book
          prices. A book price that pays 2%+ more than Kalshi's fair chance,
          or a Kalshi ask that beats the books' fair chance by 2%+ after the
          fee, is logged and later scored against Pinnacle's close.

Output: research/prediction-markets/backtest.json and
assets/prediction-markets.json. Nothing here is a pick.
"""

import csv
import io
import json
import math
import statistics
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

import line_shop

API = 'https://api.elections.kalshi.com/trade-api/v2'
SCHEMA = 'coach-prediction-markets-v1'
CODES = {'JAC': 'JAX', 'LAR': 'LA'}  # Kalshi code -> nflverse code
HISTORY_CODES = {'LA': 'LAR'}  # nflverse -> price-history code
MIN_EDGE = 0.02
PAUSE = 0.6


def kalshi_fee(price):
    """Kalshi's taker fee per contract: 0.07 x p x (1 - p), rounded up to a cent."""
    return math.ceil(0.07 * price * (1 - price) * 100) / 100


def _get(path, fetch=None):
    if fetch is None:
        def fetch(url):
            for attempt in range(5):
                try:
                    return urllib.request.urlopen(
                        urllib.request.Request(url, headers={'User-Agent': 'CoachResearch/1.0'}), timeout=60).read()
                except urllib.error.HTTPError as error:
                    if error.code != 429 or attempt == 4:
                        raise
                    time.sleep(2 ** attempt)
    return json.loads(fetch(API + path))


def markets(series, status, fetch=None):
    rows, cursor = [], ''
    for _ in range(50):
        page = _get(f'/markets?series_ticker={series}&status={status}&limit=1000' + (f'&cursor={cursor}' if cursor else ''), fetch)
        rows += page.get('markets') or []
        cursor = page.get('cursor')
        if not cursor:
            break
    return rows


def split_teams(event_ticker, team_codes):
    """KXNFLGAME-26NOV22JACNYG -> ('JAC', 'NYG') using the team codes seen in market tickers."""
    tail = event_ticker.split('-', 1)[1][7:]
    for i in range(2, 4):
        away, home = tail[:i], tail[i:]
        if away in team_codes and home in team_codes:
            return away, home
    return None, None


def _f(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def mid_at(candles, ts):
    """Mid of the last hourly candle that ended at or before ts."""
    best = None
    for candle in candles:
        if candle.get('end_period_ts', 0) <= ts:
            bid = _f((candle.get('yes_bid') or {}).get('close_dollars'))
            ask = _f((candle.get('yes_ask') or {}).get('close_dollars'))
            if bid is not None and ask is not None and 0 < bid <= ask < 1:
                best = ((bid + ask) / 2, ask)
    return best


def _no_vig_ml(home_ml, away_ml):
    def implied(ml):
        ml = float(ml)
        return 100 / (ml + 100) if ml > 0 else -ml / (-ml + 100)
    h, a = implied(home_ml), implied(away_ml)
    return h / (h + a)


def _kickoff(row):
    # nflverse gametime is US Eastern. November games are UTC-5, Sep/Oct UTC-4.
    day = datetime.strptime(row['gameday'] + ' ' + (row['gametime'] or '13:00'), '%Y-%m-%d %H:%M')
    offset = 4 if day.month in (9, 10) or (day.month == 11 and day.day < 2) else 5
    return (day + timedelta(hours=offset)).replace(tzinfo=timezone.utc)


def backtest(schedule_csv, fetch=None, pause=PAUSE):
    settled = markets('KXNFLGAME', 'settled', fetch)
    codes = {m['ticker'].rsplit('-', 1)[1] for m in settled}
    games = {}
    for row in csv.DictReader(io.StringIO(Path(schedule_csv).read_text())):
        if row['season'] != '2026' or not row['home_moneyline'] or not row['result']:
            continue
        games[(row['away_team'], row['home_team'], row['gameday'])] = row
    todo = []
    for market in settled:
        away, home = split_teams(market['event_ticker'], codes)
        if not away or market['ticker'].rsplit('-', 1)[1] != home:
            continue  # One market per game: the home team's.
        a, h = CODES.get(away, away), CODES.get(home, home)
        date = datetime.strptime(market['event_ticker'].split('-')[1][:7], '%y%b%d').strftime('%Y-%m-%d')
        game = games.get((a, h, date))
        if game and float(game['result']) != 0:
            todo.append((market['ticker'], date, game, _kickoff(game)))
    by_date = {}
    for item in todo:
        by_date.setdefault(item[1], []).append(item)
    rows = []
    for date, items in sorted(by_date.items()):
        first = min(item[3] for item in items)
        last = max(item[3] for item in items)
        start = int((first - timedelta(hours=30)).timestamp())
        end = int(last.timestamp())
        tickers = ','.join(item[0] for item in items)
        payload = _get(f'/markets/candlesticks?market_tickers={tickers}&start_ts={start}&end_ts={end}&period_interval=60', fetch)
        candles = {m.get('market_ticker') or m.get('ticker'): m.get('candlesticks') or [] for m in payload.get('markets') or []}
        time.sleep(pause)
        for ticker, _date, game, kickoff in items:
            series = candles.get(ticker) or []
            ts = int(kickoff.timestamp())
            early, late = mid_at(series, ts - 24 * 3600), mid_at(series, ts - 3600)
            rows.append({
                'game': f"{game['away_team']}@{game['home_team']} {date}",
                'homeWon': 1 if float(game['result']) > 0 else 0,
                'close': _no_vig_ml(game['home_moneyline'], game['away_moneyline']),
                'kalshi24h': early[0] if early else None, 'kalshi1h': late[0] if late else None,
            })
    return summarize_backtest(rows)


def _brier(pairs):
    return round(statistics.mean((p - y) ** 2 for p, y in pairs), 5) if pairs else None


def summarize_backtest(rows):
    both = [r for r in rows if r['kalshi1h'] is not None]
    early = [r for r in rows if r['kalshi24h'] is not None]
    return {
        'games': len(rows),
        'brier': {
            'sportsbookClose': _brier([(r['close'], r['homeWon']) for r in both]),
            'kalshi1h': _brier([(r['kalshi1h'], r['homeWon']) for r in both]),
            'kalshi24h': _brier([(r['kalshi24h'], r['homeWon']) for r in early]),
            'sportsbookCloseSameGames24h': _brier([(r['close'], r['homeWon']) for r in early]),
            'games1h': len(both), 'games24h': len(early),
        },
        'averageGap': {
            'kalshi1hVsClose': round(statistics.mean(abs(r['kalshi1h'] - r['close']) for r in both), 4) if both else None,
            'kalshi24hVsClose': round(statistics.mean(abs(r['kalshi24h'] - r['close']) for r in early), 4) if early else None,
        },
        'rows': rows,
    }


# ------------------------------------------------------------------ live

def live_rows(fetch=None):
    """Current Kalshi game-winner mids as {(away, home, date): {team: (mid, ask)}} in price-history codes."""
    open_markets = markets('KXNFLGAME', 'open', fetch)
    codes = {m['ticker'].rsplit('-', 1)[1] for m in open_markets}
    out = {}
    for market in open_markets:
        away, home = split_teams(market['event_ticker'], codes)
        team = market['ticker'].rsplit('-', 1)[1]
        bid, ask = _f(market.get('yes_bid_dollars')), _f(market.get('yes_ask_dollars'))
        if not away or bid is None or ask is None or not (0 < bid <= ask < 1):
            continue
        conv = lambda code: HISTORY_CODES.get(CODES.get(code, code), CODES.get(code, code))
        date = datetime.strptime(market['event_ticker'].split('-')[1][:7], '%y%b%d').strftime('%Y-%m-%d')
        out.setdefault((conv(away), conv(home), date), {})[conv(team)] = ((bid + ask) / 2, ask)
    return out


def _date_et(kickoff):
    parsed = line_shop._parse(kickoff)
    return (parsed - timedelta(hours=5)).strftime('%Y-%m-%d') if parsed else ''


def compare(kalshi, history, now):
    """Flags between Kalshi mids and the newest saved moneylines."""
    rows = [r for r in (history.get('observations') or []) if r.get('market') == 'h2h' and r.get('decimal')]
    latest = {}
    for r in rows:
        if (line_shop._parse(r.get('kickoff')) or now) <= now:
            continue
        g = line_shop._game(r)
        latest[g] = max(latest.get(g, ''), r['at'])
    flags = []
    for r in rows:
        g = line_shop._game(r)
        if latest.get(g) != r['at']:
            continue
        prices = kalshi.get((r['away'], r['home'], _date_et(r['kickoff'])))
        side = line_shop._side(r)
        if not prices or side not in ('home', 'away') or r['book'] == line_shop.SHARP_BOOK:
            continue
        team = r['home'] if side == 'home' else r['away']
        other = r['away'] if side == 'home' else r['home']
        if team not in prices or other not in prices:
            continue
        mid_team, mid_other = prices[team][0], prices[other][0]
        fair = mid_team / (mid_team + mid_other)
        if not (line_shop.MIN_FAIR <= fair <= line_shop.MAX_FAIR):
            continue
        edge = line_shop.expected_value(fair, r['decimal'])
        if edge >= MIN_EDGE:
            flags.append({'at': r['at'], 'kickoff': r['kickoff'], 'away': r['away'], 'home': r['home'],
                          'market': 'h2h', 'player': '', 'side': side, 'line': None, 'book': r['book'],
                          'decimal': r['decimal'], 'kalshiFair': round(fair, 4), 'edge': round(edge, 4),
                          'kind': 'book beats Kalshi'})
    # Kalshi ask against the books' median fair chance.
    fair_books = {}
    for (game, market, player, book, at, line), sides in line_shop._pairs(
            [r for r in rows if latest.get(line_shop._game(r)) == r['at']]).items():
        if market != 'h2h' or 'home' not in sides or 'away' not in sides:
            continue
        chance = line_shop.no_vig(sides['home']['decimal'], sides['away']['decimal'])
        if chance is not None:
            fair_books.setdefault(game, []).append(chance)
    for game, chances in fair_books.items():
        away, home, kickoff_key = game
        prices = kalshi.get((away, home, _date_et(kickoff_key + ':00Z')))
        if not prices or home not in prices or away not in prices:
            continue
        p_home = statistics.median(chances)
        for team, side, fair in ((home, 'home', p_home), (away, 'away', 1 - p_home)):
            ask = prices[team][1]
            cost = ask + kalshi_fee(ask)
            edge = fair / cost - 1
            if edge >= MIN_EDGE and line_shop.MIN_FAIR <= fair <= line_shop.MAX_FAIR:
                flags.append({'at': now.isoformat().replace('+00:00', 'Z'), 'kickoff': kickoff_key + ':00Z',
                              'away': away, 'home': home, 'market': 'h2h', 'player': '', 'side': side,
                              'line': None, 'book': 'kalshi', 'decimal': round(1 / cost, 4),
                              'booksFair': round(fair, 4), 'edge': round(edge, 4), 'kind': 'Kalshi beats the books'})
    return flags


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(description='Compare Kalshi NFL prices with the sportsbooks.')
    parser.add_argument('--backtest', action='store_true')
    parser.add_argument('--schedule', default='model/.cache/games.csv')
    parser.add_argument('--backtest-output', default='research/prediction-markets/backtest.json')
    parser.add_argument('--history', default='assets/price-history.json')
    parser.add_argument('--output', default='assets/prediction-markets.json')
    args = parser.parse_args(argv)
    if args.backtest:
        result = backtest(args.schedule)
        Path(args.backtest_output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.backtest_output).write_text(json.dumps({
            'source': 'Kalshi public market data (KXNFLGAME hourly candlesticks); nflverse closing moneylines (CC BY 4.0)',
            **result}, indent=1) + '\n')
        print(json.dumps({k: v for k, v in result.items() if k != 'rows'}, indent=1))
        return 0
    now = datetime.now(timezone.utc)
    path = Path(args.output)
    log = json.loads(path.read_text()) if path.exists() else {'schema': SCHEMA, 'flags': []}
    history = json.loads(Path(args.history).read_text())
    try:
        flags = compare(live_rows(), history, now)
        log['source'] = {'status': 'ok', 'checkedAt': now.isoformat().replace('+00:00', 'Z')}
    except Exception as error:  # noqa: BLE001 - an unavailable feed is recorded, not invented
        flags = []
        log['source'] = {'status': 'unavailable', 'detail': type(error).__name__}
    seen = {(f['away'], f['home'], f['kickoff'], f['side'], f['book'], f['kind']) for f in log['flags']}
    for flag in flags:
        key = (flag['away'], flag['home'], flag['kickoff'], flag['side'], flag['book'], flag['kind'])
        if key not in seen:
            log['flags'].append(flag)
            seen.add(key)
    del log['flags'][:-3000]
    observations = [r for r in (history.get('observations') or []) if r.get('decimal')]
    closes, _ = line_shop._closing_fair(observations)
    values = []
    for flag in log['flags']:
        kickoff = line_shop._parse(flag.get('kickoff'))
        if kickoff and kickoff <= now:
            flag['clv'] = line_shop.clv_of(flag, closes)
            values.append(flag['clv'])
    summary = line_shop.summarize(values)
    passes, reason = line_shop.gate(summary)
    log.update({'schema': SCHEMA, 'current': flags, 'summary': {'clv': summary, 'passes': passes, 'reason': reason},
                'notice': 'Kalshi exchange prices next to sportsbook prices. Research, not a pick.'})
    path.write_text(json.dumps(log, indent=1) + '\n')
    print(json.dumps({'current': len(flags), 'logged': len(log['flags']), 'scored': summary['n']}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
