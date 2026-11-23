"""Shared helpers for live edge logs: best price now, first-sighting alerts, CLV at the close.

Every niche signal is logged the same way as the wind and QB-news watches:
the bet and the best price when Coach first saw it, then, after kickoff, its
closing line value (CLV) against Pinnacle's last fair price, or, when
Pinnacle has no close for that market (most player props), against the
median no-vig close of the books we saved. ``line_shop.gate`` decides when a
signal has earned the right to be shown as a pick (200 scored bets, CLV
clearly above zero).
"""

import statistics
from datetime import datetime, timezone

import line_shop

# Odds API rows use LAR; nflverse and the Worker use LA.
CODES = {'LAR': 'LA'}
PROP_MARKETS = ('player_pass_yds', 'player_rush_yds', 'player_reception_yds', 'player_receptions')


def iso(when):
    return when.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')


def normalize(rows):
    """Price rows from price-history.json and the Worker's /v1/book-prices in one shape."""
    out = []
    for row in rows or []:
        if not row.get('decimal'):
            continue
        row = dict(row)
        away, home = row.get('away'), row.get('home')
        event = str(row.get('eventId') or '')
        if (not away or not home) and event.startswith('nflverse:'):
            parts = event.split(':', 1)[1].split('_')
            if len(parts) >= 4:
                away, home = parts[2], parts[3]
        if not away or not home:
            continue
        row['away'], row['home'] = CODES.get(away, away), CODES.get(home, home)
        out.append(row)
    return out


def _better(side, market, a, b):
    """True when quote a is better for the bettor than quote b."""
    if market == 'h2h' or a.get('line') is None or b.get('line') is None or a['line'] == b['line']:
        return a['decimal'] > b['decimal']
    if market == 'spreads':
        return a['line'] > b['line']
    return a['line'] < b['line'] if side == 'over' else a['line'] > b['line']


def best_price(rows, away, home, market, side, player='', now=None):
    """The best price among every book's newest quote for one side, before kickoff. None if none."""
    now = now or datetime.now(timezone.utc)
    newest = {}
    for row in rows:
        if row.get('away') != away or row.get('home') != home or row.get('market') != market:
            continue
        if (row.get('player') or '') != (player or '') or row.get('book') == line_shop.SHARP_BOOK:
            continue
        kickoff = line_shop._parse(row.get('kickoff'))
        if kickoff and kickoff <= now:
            continue
        if line_shop._side(row) != side:
            continue
        book = row.get('book')
        if book not in newest or str(row.get('at')) > str(newest[book].get('at')):
            newest[book] = row
    if not newest:
        return None
    # Drop books that stopped quoting: only quotes within 3 hours of the newest one count.
    latest = max(line_shop._parse(r.get('at')) for r in newest.values())
    newest = {b: r for b, r in newest.items() if (latest - line_shop._parse(r.get('at'))).total_seconds() <= 3 * 3600}
    best = None
    for row in newest.values():
        if best is None or _better(side, market, row, best):
            best = row
    if not best:
        return None
    return {'market': market, 'side': side, 'outcome': best.get('outcome'), 'line': best.get('line'),
            'book': best.get('book'), 'decimal': best['decimal'], 'priceAt': best.get('at'),
            'kickoff': best.get('kickoff'), 'player': player or ''}


def consensus_closes(rows):
    """Median no-vig close across books: {(game, market, player): [(line, first-side chance)]}.

    Each book's last two-sided pair before kickoff; the median chance per line.
    """
    kickoffs = {line_shop._game(r): line_shop._parse(r.get('kickoff')) for r in rows}
    last = {}
    for (game, market, player, book, at, line), sides in line_shop._pairs(rows).items():
        kickoff, parsed = kickoffs.get(game), line_shop._parse(at)
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
            last[key] = (at, {line: chance})
        elif at == last[key][0]:
            last[key][1][line] = chance
    pooled = {}
    for (game, market, player, _book), (_at, lines) in last.items():
        for line, chance in lines.items():
            pooled.setdefault((game, market, player), {}).setdefault(line, []).append(chance)
    return {key: [(line, statistics.median(c)) for line, c in lines.items()] for key, lines in pooled.items()}


def merge(log, current, key_fields):
    """Add alerts seen for the first time. The first sighting (and its price) is never replaced."""
    alerts = log.setdefault('alerts', [])
    key = lambda a: tuple(str(a.get(f)) for f in key_fields)
    seen = {key(a) for a in alerts}
    added = 0
    for row in current:
        if row.get('bet') and key(row) not in seen:
            alerts.append(row)
            seen.add(key(row))
            added += 1
    del alerts[:-5000]
    return added


def score(log, rows, now=None, group_field='angle'):
    """CLV for every alert whose game has kicked off; summary overall and per group."""
    now = now or datetime.now(timezone.utc)
    pinnacle, _ = line_shop._closing_fair(rows)
    consensus = consensus_closes(rows)
    groups = {}
    overall = []
    for alert in log.get('alerts') or []:
        bet = alert.get('bet')
        kickoff = line_shop._parse(alert.get('kickoff'))
        if not bet or not kickoff or kickoff > now:
            continue
        if alert.get('clv') is None:
            flag = {**bet, 'away': alert['away'], 'home': alert['home'], 'kickoff': alert['kickoff'],
                    'player': bet.get('player') or ''}
            value = line_shop.clv_of(flag, pinnacle)
            reference = 'pinnacle'
            if value is None:
                value = line_shop.clv_of(flag, consensus)
                reference = 'book consensus'
            if value is None:
                continue
            alert['clv'], alert['clvReference'] = value, reference
        overall.append(alert['clv'])
        groups.setdefault(alert.get(group_field) or 'other', []).append(alert['clv'])
    summary = line_shop.summarize(overall)
    passes, reason = line_shop.gate(summary)
    by_group = {}
    for name, values in sorted(groups.items()):
        s = line_shop.summarize(values, rounds=500)
        ok, why = line_shop.gate(s)
        by_group[name] = {'clv': s, 'passes': ok, 'reason': why}
    return {'clv': summary, 'passes': passes, 'reason': reason, 'byAngle': by_group}
