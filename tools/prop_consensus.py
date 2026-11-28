"""Cross-book prop comparison from the Worker's logged-out prices.

For each player, market and line, take the margin out of every book that
posts both sides, then average those fair chances. At least three books have
to be on that same line. A book on a different line is not moved onto the
chance. A side is flagged when its price pays at least 3% more than a fair
payout at that chance (fair chance times the decimal, minus 1), and the fair
chance is between 10% and 90%.

The bar is 3%, wider than the 2% Pinnacle rule in line_shop.py. This average
is the same soft books, and each book sits inside the average, so a 2% gap is
ordinary vig noise. The PropLine test of a 2% gap against Pinnacle still lost
to the close.

Flags are a separate signal, ``prop-consensus``. tools/edge_log.py grades each
one against Pinnacle's no-vig close when that close exists, otherwise against
the median no-vig close of the saved books. Nothing here is a pick. The served
prop chance is unchanged.

    python tools/prop_consensus.py --book-prices book-prices.json --history assets/price-history.json
"""

import json
from datetime import datetime, timezone
from pathlib import Path

import edge_log
import line_shop

SCHEMA = 'coach-prop-consensus-v1'
SIGNAL = 'prop-consensus'
MIN_BOOKS = 3
MIN_EDGE = 0.03
MIN_FAIR = line_shop.MIN_FAIR
MAX_FAIR = line_shop.MAX_FAIR
TWO_SIDED = {
    'player_pass_yds', 'player_rush_yds', 'player_reception_yds', 'player_receptions',
    'player_pass_attempts', 'player_pass_completions', 'player_pass_tds',
}
BOOK_NAMES = {
    'fanduel': 'FanDuel', 'bovada': 'Bovada', 'betrivers': 'BetRivers',
    'draftkings': 'DraftKings', 'betmgm': 'BetMGM', 'pinnacle': 'Pinnacle',
}
NOTICE = (
    'A comparison of a saved prop price with the no-vig average of the books '
    'on the same line. Not a pick. A different line is not treated as the same '
    'chance. Listed only when the price pays at least 3% more than a fair '
    'payout at that chance.'
)


def _newer(next_at, prev_at):
    a, b = line_shop._parse(next_at), line_shop._parse(prev_at)
    if a and b:
        return a >= b
    return str(next_at or '') >= str(prev_at or '')


def _side(outcome):
    text = str(outcome or '')
    if text.lower() == 'over':
        return 'Over'
    if text.lower() == 'under':
        return 'Under'
    return ''


def _identity(row):
    event = str(row.get('eventId') or '')
    away, home = row.get('away'), row.get('home')
    if event.startswith('nflverse:'):
        parts = event.split(':', 1)[1].split('_')
        if len(parts) >= 4 and parts[2] and parts[3]:
            away, home = parts[2], parts[3]
    if not away or not home:
        return None
    away = edge_log.CODES.get(away, away)
    home = edge_log.CODES.get(home, home)
    key = event or f"{away}|{home}|{str(row.get('kickoff') or '')[:16]}"
    return key, away, home


def consensus_groups(rows):
    """One group per player, market and exact line that has at least 3 two-sided books."""
    latest = {}
    for row in rows or []:
        if row.get('market') not in TWO_SIDED:
            continue
        decimal = row.get('decimal')
        if not isinstance(decimal, (int, float)) or not 1 < decimal <= 100:
            continue
        try:
            line = float(row.get('line'))
        except (TypeError, ValueError):
            continue
        side = _side(row.get('outcome'))
        who = _identity(row)
        if not side or not who or not row.get('book') or not row.get('player'):
            continue
        key = (who[0], row.get('book'), row.get('market'), row.get('player'), side)
        prev = latest.get(key)
        if prev is None or _newer(row.get('at'), prev['row'].get('at')):
            latest[key] = {'row': row, 'who': who, 'side': side, 'line': line}
    buckets = {}
    for item in latest.values():
        buckets.setdefault((item['who'][0], item['row'].get('market'), item['row'].get('player'), item['line']), []).append(item)
    groups = []
    for items in buckets.values():
        by_book = {}
        for item in items:
            by_book.setdefault(item['row'].get('book'), {})[item['side']] = item
        fairs = []
        for book, sides in by_book.items():
            if 'Over' not in sides or 'Under' not in sides:
                continue
            chance = line_shop.no_vig(sides['Over']['row'].get('decimal'), sides['Under']['row'].get('decimal'))
            if chance is None:
                continue
            fairs.append((book, chance, sides))
        if len(fairs) < MIN_BOOKS:
            continue
        consensus = sum(chance for _, chance, _ in fairs) / len(fairs)
        flags = []
        for sides in by_book.values():
            for side in ('Over', 'Under'):
                item = sides.get(side)
                if not item:
                    continue
                chance = consensus if side == 'Over' else 1 - consensus
                if not (MIN_FAIR <= chance <= MAX_FAIR):
                    continue
                edge = line_shop.expected_value(chance, item['row']['decimal'])
                if edge < MIN_EDGE:
                    continue
                row = item['row']
                flags.append({
                    'book': row.get('book'), 'player': row.get('player'), 'market': row.get('market'),
                    'outcome': side, 'side': side.lower(), 'line': item['line'], 'decimal': row['decimal'],
                    'at': row.get('at') or '', 'fairChance': chance, 'edge': edge, 'books': len(fairs),
                    'away': item['who'][1], 'home': item['who'][2], 'kickoff': row.get('kickoff') or '',
                    'eventId': item['who'][0],
                })
        flags.sort(key=lambda flag: (-flag['edge'], str(flag['book'])))
        first = items[0]
        groups.append({
            'player': first['row'].get('player'), 'market': first['row'].get('market'), 'line': first['line'],
            'eventId': first['who'][0], 'away': first['who'][1], 'home': first['who'][2],
            'consensus': consensus, 'books': len(fairs), 'flags': flags,
        })
    return groups


def book_label(book):
    return BOOK_NAMES.get(str(book or '').lower(), book or 'unavailable')


def decimal_label(value):
    text = f'{float(value):.6f}'.rstrip('0').rstrip('.')
    return text if '.' in text else text + '.0'


def american_label(decimal):
    if not isinstance(decimal, (int, float)) or not decimal > 1:
        return 'unavailable'
    value = (decimal - 1) * 100 if decimal >= 2 else -100 / (decimal - 1)
    rounded = int(round(value))
    return f'+{rounded}' if rounded >= 0 else str(rounded)


def percent_label(chance):
    return f'{chance * 100:.1f}%'


def record_sentence(record):
    if not record or not isinstance(record.get('scored'), int):
        return 'Prop-consensus closing-line record: unavailable.'
    n = record['scored']
    gate = '200 scored bets, with the low end of the range above zero, are needed before this is a signal.'
    mean = record.get('mean')
    if n <= 0 or not isinstance(mean, (int, float)):
        return f'Prop-consensus closing-line record: {n} scored bets. {gate}'
    def pct(value):
        return f'{value * 100:+.1f}%'
    low, high = record.get('low'), record.get('high')
    spread = f' (90% range {pct(low)} to {pct(high)})' if isinstance(low, (int, float)) and isinstance(high, (int, float)) else ''
    cleared = ' The closing-line record has cleared the 200-bet bar.' if record.get('passes') else f' {gate}'
    return f'Prop-consensus closing-line record: {n} scored bets, average closing-line value {pct(mean)}{spread}.{cleared}'


def _flag_sentence(flag):
    return (
        f"{book_label(flag['book'])}, {flag['player']} {flag['outcome']} {flag['line']} at "
        f"{american_label(flag['decimal'])} (decimal {decimal_label(flag['decimal'])}), "
        f"consensus fair chance {percent_label(flag['fairChance'])} from {flag['books']} books, "
        f"price saved {flag['at'] or 'unavailable'}."
    )


def market_from_question(question):
    text = str(question or '').lower()
    if 'reception' in text and 'yard' not in text:
        return 'player_receptions'
    if 'receiving' in text:
        return 'player_reception_yds'
    if 'rush' in text:
        return 'player_rush_yds'
    if 'anytime' in text:
        return 'player_anytime_td'
    if 'attempt' in text:
        return 'player_pass_attempts'
    if 'completion' in text:
        return 'player_pass_completions'
    if 'touchdown' in text or ' td' in f' {text}':
        return 'player_pass_tds'
    if 'pass' in text:
        return 'player_pass_yds'
    return ''


def format_consensus(rows, player='', market='', line=None, event_id='', record=None):
    groups = consensus_groups(rows)
    wanted = player.lower() if player else ''
    if wanted:
        groups = [g for g in groups if wanted in str(g['player']).lower() or str(g['player']).lower() in wanted]
    if market:
        groups = [g for g in groups if g['market'] == market]
    if event_id:
        scoped = [g for g in groups if g['eventId'] == event_id]
        if scoped:
            groups = scoped
    if line is not None:
        groups = [g for g in groups if g['line'] == line]
    framing = 'This is a comparison, not a pick.'
    record_text = record_sentence(record)
    if market == 'player_anytime_td':
        return (
            'Best price vs other books: unavailable. Anytime touchdown is one-sided, so there is '
            f'no two-sided consensus to compare. {framing} {record_text}'
        )
    matched = []
    for row in rows or []:
        name = str(row.get('player') or '').lower()
        if wanted and wanted not in name and name not in wanted:
            continue
        if market and row.get('market') != market:
            continue
        matched.append(row)
    if not groups:
        reason = (
            'Fewer than 3 books have a two-sided price on the same line. A different line is not treated as the same chance.'
            if matched else 'No saved price for this prop.'
        )
        return f'Best price vs other books: unavailable. {reason} {framing} {record_text}'
    flags = sorted((flag for group in groups for flag in group['flags']), key=lambda flag: (-flag['edge'], str(flag['book'])))
    if not flags:
        if len(groups) == 1:
            group = groups[0]
            return (
                'Best price vs other books: no saved price pays 3% more than a fair payout at the consensus chance. '
                f"Consensus fair chance on the over at {group['line']} is {percent_label(group['consensus'])} from {group['books']} books. "
                f'{framing} {record_text}'
            )
        return f'Best price vs other books: no saved price pays 3% more than a fair payout at the consensus chance. {framing} {record_text}'
    shown = ' '.join(_flag_sentence(flag) for flag in flags[:4])
    extra = f' {len(flags) - 4} more are not listed.' if len(flags) > 4 else ''
    return f'Best price vs other books: {shown}{extra} {framing} {record_text}'


def _before_kick(flag):
    kick = line_shop._parse(flag.get('kickoff'))
    at = line_shop._parse(flag.get('at'))
    return bool(kick and at and at < kick)


def _alert(flag, now):
    return {
        'away': flag['away'], 'home': flag['home'], 'kickoff': flag['kickoff'],
        'player': flag['player'], 'market': flag['market'], 'side': flag['side'],
        'line': flag['line'], 'book': flag['book'], 'angle': SIGNAL, 'signal': SIGNAL,
        'checkedAt': edge_log.iso(now),
        'bet': {
            'market': flag['market'], 'side': flag['side'], 'outcome': flag['outcome'],
            'line': flag['line'], 'book': flag['book'], 'decimal': flag['decimal'],
            'priceAt': flag['at'], 'player': flag['player'],
            'fairChance': round(flag['fairChance'], 4), 'consensusBooks': flag['books'],
            'edge': round(flag['edge'], 4),
        },
    }


def update_log(log, rows, grade_rows, now=None):
    """Add first-sighting flags and score them. The first price is kept."""
    now = now or datetime.now(timezone.utc)
    flags = [flag for group in consensus_groups(rows) for flag in group['flags']]
    alerts = [_alert(flag, now) for flag in flags if _before_kick(flag)]
    added = edge_log.merge(log, alerts, ('away', 'home', 'kickoff', 'player', 'market', 'side', 'line', 'book', 'angle'))
    summary = edge_log.score(log, grade_rows, now, group_field='angle')
    log.update({
        'schema': SCHEMA,
        'signal': SIGNAL,
        'checkedAt': edge_log.iso(now),
        'notice': NOTICE,
        'rule': {
            'minBooks': MIN_BOOKS,
            'minEdge': MIN_EDGE,
            'fairRange': [MIN_FAIR, MAX_FAIR],
            'sameLineOnly': True,
            'why': (
                '3% is wider than the 2% Pinnacle rule because this average is the same '
                'soft books and each book sits inside it. A 2% gap there is ordinary vig noise, '
                'and the PropLine 2% test against Pinnacle lost to the close.'
            ),
        },
        # Answers stay a comparison. passes is the 200-bet closing-line gate.
        'adopted': False,
        'passes': summary['passes'],
        'summary': summary,
        'current': [
            {
                'book': flag['book'], 'player': flag['player'], 'market': flag['market'],
                'outcome': flag['outcome'], 'line': flag['line'], 'decimal': flag['decimal'],
                'fairChance': round(flag['fairChance'], 4), 'books': flag['books'],
                'at': flag['at'], 'away': flag['away'], 'home': flag['home'], 'kickoff': flag['kickoff'],
            }
            for flag in flags if _before_kick(flag)
        ][:100],
    })
    return added


def _load_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(description='Log prop prices that pay more than the no-vig consensus, and grade earlier flags.')
    parser.add_argument('--book-prices', required=True)
    parser.add_argument('--history', default='assets/price-history.json')
    parser.add_argument('--log', default='assets/prop-consensus.json')
    args = parser.parse_args(argv)
    raw = _load_json(args.book_prices)
    if not isinstance(raw, dict) or not isinstance(raw.get('observations'), list):
        print('book prices unavailable')
        return 0
    history = _load_json(args.history) or {}
    log_path = Path(args.log)
    log = _load_json(log_path) or {}
    if not isinstance(log, dict):
        log = {}
    log.setdefault('alerts', [])
    grade_rows = edge_log.normalize((history.get('observations') or []) + raw['observations'])
    added = update_log(log, edge_log.normalize(raw['observations']), grade_rows)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(json.dumps(log, indent=2) + '\n')
    summary = log['summary']['clv']
    print(json.dumps({'added': added, 'current': len(log['current']), 'scored': summary['n'], 'passes': log['passes']}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
