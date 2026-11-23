"""Pre-kickoff snapshots, credit budget, and line-movement features.

The free Odds API plan is 500 credits a month. The backend already uses a
documented share of that plan. This module spends only the slice named below,
and only after a free events call reports that the reserve would survive.
Public sportsbook pages cost nothing. A missing number stays missing.
"""

from datetime import datetime, timedelta, timezone

# Documented in backend/README.md and docs/PROVIDERS.md. Not a new measurement.
FREE_PLAN_CREDITS = 500
BACKEND_MAIN_LINE = 240
BACKEND_PROPS = 60
BACKEND_PINNACLE = 36
CREDIT_RESERVE = 50
# 16 game-line calls x 3 credits. One call covers every game still on the board.
GAME_LINE_CAP = 48
GAME_LINE_COST = 3
# 16 single-market prop calls. One market on the earliest game, not every prop.
PROP_CAP = 16
PROP_COST = 1

# Minutes before kickoff. "last" is the final look, about 10 minutes out.
SLOTS = (
    ('T-24h', 24 * 60),
    ('T-6h', 6 * 60),
    ('T-3h', 3 * 60),
    ('T-90m', 90),
    ('T-30m', 30),
    ('last', 10),
)
SLOT_MINUTES = dict(SLOTS)
LATE_MINUTES = 180
STEAM_MINUTES = 20
STEAM_BOOKS = 3
KEY_NUMBERS = (3, 7)
DISAGREEMENT_HOURS = 2

# Ten books. A bookmakers list of up to ten counts as one region, so three
# markets cost 3 credits whichever region a book belongs to. Pinnacle (an eu
# book) replaces Fliff here so every snapshot has a sharp reference for line
# shopping (tools/line_shop.py) at no extra cost. Its logged-out page is
# blocked from GitHub's servers (HTTP 403).
GAME_BOOKS = (
    'draftkings', 'fanduel', 'betmgm', 'williamhill_us', 'espnbet',
    'fanatics', 'betrivers', 'hardrockbet', 'ballybet', 'pinnacle',
)
SHARP_BOOK = 'pinnacle'
RETAIL_BOOKS = set(GAME_BOOKS) - {SHARP_BOOK}
PROP_MARKETS = (
    'player_pass_yds', 'player_rush_yds', 'player_reception_yds', 'player_receptions',
)

TEAMS = {
    'Arizona Cardinals': 'ARI', 'Atlanta Falcons': 'ATL', 'Baltimore Ravens': 'BAL',
    'Buffalo Bills': 'BUF', 'Carolina Panthers': 'CAR', 'Chicago Bears': 'CHI',
    'Cincinnati Bengals': 'CIN', 'Cleveland Browns': 'CLE', 'Dallas Cowboys': 'DAL',
    'Denver Broncos': 'DEN', 'Detroit Lions': 'DET', 'Green Bay Packers': 'GB',
    'Houston Texans': 'HOU', 'Indianapolis Colts': 'IND', 'Jacksonville Jaguars': 'JAX',
    'Kansas City Chiefs': 'KC', 'Las Vegas Raiders': 'LV', 'Los Angeles Chargers': 'LAC',
    'Los Angeles Rams': 'LAR', 'Miami Dolphins': 'MIA', 'Minnesota Vikings': 'MIN',
    'New England Patriots': 'NE', 'New Orleans Saints': 'NO', 'New York Giants': 'NYG',
    'New York Jets': 'NYJ', 'Philadelphia Eagles': 'PHI', 'Pittsburgh Steelers': 'PIT',
    'San Francisco 49ers': 'SF', 'Seattle Seahawks': 'SEA', 'Tampa Bay Buccaneers': 'TB',
    'Tennessee Titans': 'TEN', 'Washington Commanders': 'WAS',
}
NAMES = {code: name for name, code in TEAMS.items()}


def budget_template(month=None):
    """The credit plan, with this job's spend still at zero."""
    return {
        'freePlanCredits': FREE_PLAN_CREDITS,
        'backendMainLine': BACKEND_MAIN_LINE,
        'backendProps': BACKEND_PROPS,
        'backendPinnacle': BACKEND_PINNACLE,
        'reserve': CREDIT_RESERVE,
        'gameLineCap': GAME_LINE_CAP,
        'propCap': PROP_CAP,
        'gameLineCost': GAME_LINE_COST,
        'propCost': PROP_COST,
        'month': month,
        'gameLineSpent': 0,
        'propSpent': 0,
        'requestsRemaining': None,
        'note': (
            'The free plan is 500 credits a month. The backend already plans about 240 '
            'for moneylines, spreads and totals, at most 60 for props, and at most 36 '
            'for Pinnacle, and it holds 50 in reserve. This capture may spend 48 on '
            'game lines (16 calls of 3 credits) and 16 on one prop market (16 calls of '
            '1 credit). 240+60+36+48+16=400, and the 50 reserve is not spent by this job. '
            'A call is skipped when remaining credits are unknown or below 50 plus the '
            'call, or when this job\'s own cap is used up. Logged-out sportsbook pages '
            'cost nothing. This is not a pick.'
        ),
    }


def ensure_budget(history, now):
    """Keep one month of spend. A new month starts the counters over."""
    current = budget_template(now.strftime('%Y-%m'))
    stored = history.get('budget')
    if not isinstance(stored, dict) or stored.get('month') != current['month']:
        history['budget'] = current
        return history['budget']
    for key, value in current.items():
        if key in ('gameLineSpent', 'propSpent', 'requestsRemaining'):
            continue
        stored[key] = value
    stored.setdefault('gameLineSpent', 0)
    stored.setdefault('propSpent', 0)
    stored.setdefault('requestsRemaining', None)
    history['budget'] = stored
    return stored


def allow_spend(budget, kind, remaining):
    """Whether one Odds API call may be made. Remaining must be a real header."""
    cost = GAME_LINE_COST if kind == 'game' else PROP_COST
    cap = GAME_LINE_CAP if kind == 'game' else PROP_CAP
    spent_key = 'gameLineSpent' if kind == 'game' else 'propSpent'
    spent = int(budget.get(spent_key) or 0)
    if remaining is None:
        return False, 'remaining credits are unavailable'
    if remaining < CREDIT_RESERVE + cost:
        return False, 'the reserve would be used'
    if spent + cost > cap:
        return False, 'the monthly cap for this capture is spent'
    return True, ''


def record_spend(budget, kind, charged, remaining):
    spent_key = 'gameLineSpent' if kind == 'game' else 'propSpent'
    budget[spent_key] = int(budget.get(spent_key) or 0) + int(charged)
    if remaining is not None:
        budget['requestsRemaining'] = remaining
    return budget


# How far before the target a run still counts, and how long after it we
# still accept a late run. The windows do not overlap, so T-30m is not also
# "last".
SLOT_EARLY = {
    'T-24h': 20, 'T-6h': 20, 'T-3h': 20, 'T-90m': 15, 'T-30m': 10, 'last': 7,
}
SLOT_LATE = {
    'T-24h': 30, 'T-6h': 25, 'T-3h': 25, 'T-90m': 20, 'T-30m': 12, 'last': 9,
}


def slots_to_capture(minutes_left, attempted):
    """Slots whose window is open, or the one we are late for but not past.

    On time means within that slot's early and late minutes. If the window
    was missed, the slot is still taken once, until the next slot's early
    window begins. Kickoff itself is not a slot.
    """
    if minutes_left <= 0:
        return []
    attempted = set(attempted or ())
    due = []
    for index, (name, target) in enumerate(SLOTS):
        if name in attempted:
            continue
        early = SLOT_EARLY[name]
        late = SLOT_LATE[name]
        on_time = (target - late) <= minutes_left <= (target + early)
        if index + 1 < len(SLOTS):
            next_name, next_target = SLOTS[index + 1]
            next_early = next_target + SLOT_EARLY[next_name]
        else:
            next_early = 0
        missed = minutes_left < (target - late) and minutes_left > next_early
        if on_time or missed:
            due.append(name)
    return due


def cluster_kickoff(parsed):
    """Games that start within the same half hour share one capture."""
    minute = 0 if parsed.minute < 30 else 30
    bucket = parsed.replace(minute=minute, second=0, microsecond=0)
    return bucket


def _parse(value):
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)
    text = str(value).strip()
    if text.endswith('Z'):
        text = text[:-1] + '+00:00'
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _iso(parsed):
    return parsed.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')


def kickoffs_from(history, snapshot):
    """Kickoff times already known. No network call."""
    found = []
    seen = set()
    for event in ((snapshot or {}).get('board') or {}).get('events') or []:
        if isinstance(event, dict) and event.get('startsAt'):
            found.append(event['startsAt'])
    for event in ((snapshot or {}).get('props') or {}).get('events') or []:
        if isinstance(event, dict) and event.get('startsAt'):
            found.append(event['startsAt'])
    for row in (history or {}).get('observations') or []:
        if row.get('kickoff'):
            found.append(row['kickoff'])
    unique = []
    for value in found:
        parsed = _parse(value)
        if parsed is None:
            continue
        text = _iso(parsed)
        if text in seen:
            continue
        seen.add(text)
        unique.append(parsed)
    unique.sort()
    return unique


def attempted_slots(history, cluster_iso):
    names = []
    for row in history.get('cadence') or []:
        if row.get('kickoff') == cluster_iso and row.get('slot'):
            names.append(row['slot'])
    return names


def record_attempt(history, cluster_iso, slot, status, now):
    history.setdefault('cadence', [])
    for row in history['cadence']:
        if row.get('kickoff') == cluster_iso and row.get('slot') == slot:
            row['status'] = status
            row['attemptedAt'] = _iso(now)
            return
    history['cadence'].append({
        'slot': slot,
        'kickoff': cluster_iso,
        'status': status,
        'attemptedAt': _iso(now),
    })
    cutoff = _iso(now - timedelta(days=14))
    history['cadence'] = [
        row for row in history['cadence'] if (row.get('attemptedAt') or '') >= cutoff
    ]
    history['cadence'].sort(key=lambda row: (row.get('kickoff') or '', row.get('slot') or ''))


def due_work(history, snapshot, now):
    """(cluster iso, slot, kickoff datetime) rows that still need a snapshot."""
    work = []
    for kickoff in kickoffs_from(history, snapshot):
        if kickoff <= now:
            continue
        if (kickoff - now) > timedelta(hours=26):
            continue
        cluster = _iso(cluster_kickoff(kickoff))
        minutes = (kickoff - now).total_seconds() / 60
        for slot in slots_to_capture(minutes, attempted_slots(history, cluster)):
            work.append((cluster, slot, kickoff))
    return work


def season_months(now):
    """August through February. The offseason does not call the odds host."""
    return now.month in (8, 9, 10, 11, 12, 1, 2)


def header_int(headers, name):
    if not headers:
        return None
    raw = headers.get(name) or headers.get(name.lower())
    if raw is None or raw == '':
        return None
    try:
        return int(float(raw))
    except (TypeError, ValueError):
        return None


def charged_amount(headers, planned, status):
    """The header is the charge. A missing header on a failed or opaque call counts as the planned cost."""
    reported = header_int(headers, 'x-requests-last')
    if reported is not None:
        return max(reported, 0)
    if status == 200 or status == 0 or status >= 400:
        return planned
    return planned


def redact(text, key):
    text = '' if text is None else str(text)
    if key:
        text = text.replace(key, '[redacted]')
    return text[:180]


def _number(value):
    if value is None or value == '':
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if number != number:
        return None
    return number


def _abbr(name):
    if not name:
        return None
    text = str(name).strip()
    if text in NAMES:
        return text
    return TEAMS.get(text)


def _home_name(row):
    home = row.get('home')
    if home in NAMES:
        return NAMES[home]
    return None


def _is_home_outcome(outcome, row):
    text = str(outcome or '').strip().lower()
    if not text:
        return False
    home = row.get('home')
    if home and text == str(home).strip().lower():
        return True
    name = _home_name(row)
    return bool(name and text == name.lower())


def _median_posted(values):
    """A saved line, not an average of two lines."""
    ordered = sorted(value for value in values if value is not None)
    if not ordered:
        return None
    return ordered[len(ordered) // 2]


def _before(row, kickoff):
    at = _parse(row.get('at'))
    start = _parse(kickoff)
    return at is not None and start is not None and at < start


def recompute_opens(history):
    """The first saved price strictly before kickoff. One row can be both open and close."""
    grouped = {}
    for row in history.get('observations') or []:
        key = (
            row.get('book'), row.get('eventId'), row.get('market'),
            row.get('player'), row.get('outcome'),
        )
        grouped.setdefault(key, []).append(row)
    opens = []
    for rows in grouped.values():
        rows.sort(key=lambda row: row.get('at') or '')
        kickoff = next((row.get('kickoff') for row in reversed(rows) if row.get('kickoff')), None)
        chosen = None
        for row in rows:
            if not kickoff:
                continue
            if row['at'] < kickoff:
                chosen = row
                break
        if chosen is None:
            continue
        opened = dict(chosen)
        opened['open'] = True
        opens.append(opened)
    opens.sort(key=lambda row: (
        row.get('kickoff') or '', row.get('eventId') or '', row.get('market') or '',
        row.get('book') or '', row.get('player') or '', row.get('outcome') or '',
    ))
    history['opens'] = opens
    return opens


def _crossed(path):
    found = []
    for earlier, later in zip(path, path[1:]):
        low, high = min(earlier, later), max(earlier, later)
        for number in KEY_NUMBERS:
            if number in found:
                continue
            if low < number < high or low < -number < high:
                found.append(number)
    return found


def _series(points):
    """points are (datetime, line) already one line per timestamp."""
    ordered = sorted(points, key=lambda item: item[0])
    collapsed = []
    for at, line in ordered:
        if collapsed and collapsed[-1][0] == at:
            continue
        collapsed.append((at, line))
    return collapsed


def _late_pair(series, kickoff):
    """(from_line, to_line) inside the last three hours, or (None, None)."""
    if not series:
        return None, None
    cutoff = kickoff - timedelta(minutes=LATE_MINUTES)
    before = [item for item in series if item[0] <= cutoff]
    inside = [item for item in series if cutoff < item[0] < kickoff]
    if not inside:
        return None, None
    if before:
        return before[-1][1], inside[-1][1]
    if len(inside) >= 2:
        return inside[0][1], inside[-1][1]
    return None, None


def _steam(book_series):
    """Three or more books moving the same way inside 20 minutes. Otherwise None."""
    changes = []
    for book, series in book_series.items():
        ordered = _series(series)
        for earlier, later in zip(ordered, ordered[1:]):
            minutes = (later[0] - earlier[0]).total_seconds() / 60
            if minutes <= 0 or minutes > STEAM_MINUTES:
                continue
            delta = later[1] - earlier[1]
            if delta == 0:
                continue
            changes.append((later[0], book, -1 if delta < 0 else 1))
    best = None
    for moment, book, sign in changes:
        window = [
            item for item in changes
            if item[2] == sign and abs((item[0] - moment).total_seconds()) <= STEAM_MINUTES * 60
        ]
        books = sorted({item[1] for item in window})
        if len(books) < STEAM_BOOKS:
            continue
        span = max(item[0] for item in window) - min(item[0] for item in window)
        candidate = {
            'books': books,
            'minutes': int(round(span.total_seconds() / 60)),
            'direction': 'home' if sign < 0 else 'away',
            'at': _iso(moment),
        }
        if best is None or len(books) > len(best['books']) or (
            len(books) == len(best['books']) and candidate['at'] > best['at']
        ):
            best = candidate
    return best


def _disagreement(home_by_book, close_at):
    """Pinnacle minus the other books, within two hours of the last price."""
    if close_at is None:
        return None, None
    window = timedelta(hours=DISAGREEMENT_HOURS)
    pinnacle = None
    retail = []
    for book, series in home_by_book.items():
        recent = [item for item in series if abs(item[0] - close_at) <= window and item[0] <= close_at]
        if not recent:
            continue
        line = recent[-1][1]
        if book == SHARP_BOOK:
            pinnacle = line
        else:
            retail.append(line)
    retail_line = _median_posted(retail)
    if pinnacle is None or retail_line is None:
        return None, None
    return pinnacle, retail_line


def build_moves(observations):
    """One row per game, market, and prop side. Missing features are null."""
    groups = {}
    for row in observations or []:
        market = row.get('market')
        event_id = row.get('eventId')
        if not market or not event_id:
            continue
        player = row.get('player') or ''
        side = ''
        if str(market).startswith('player_'):
            side = str(row.get('outcome') or '')
        groups.setdefault((event_id, market, player, side), []).append(row)
    moves = []
    for (event_id, market, player, side), rows in groups.items():
        kickoff = next((row.get('kickoff') for row in reversed(rows) if row.get('kickoff')), None)
        start = _parse(kickoff)
        if start is None:
            continue
        sample = next((row for row in rows if row.get('home') and row.get('away')), rows[0])
        home_by_book = {}
        consensus = {}
        for row in rows:
            if not _before(row, kickoff):
                continue
            at = _parse(row.get('at'))
            line = _number(row.get('line'))
            book = str(row.get('book') or '').lower()
            if at is None or not book:
                continue
            if market == 'spreads':
                if line is None or not _is_home_outcome(row.get('outcome'), row):
                    continue
            elif market == 'totals' or str(market).startswith('player_'):
                if line is None:
                    continue
                if side and str(row.get('outcome') or '') != side:
                    continue
            elif market == 'h2h':
                if not _is_home_outcome(row.get('outcome'), row):
                    continue
                line = _number(row.get('decimal'))
                if line is None:
                    continue
            else:
                continue
            home_by_book.setdefault(book, []).append((at, line))
            consensus.setdefault(at, []).append(line)
        if not consensus:
            continue
        series = _series((at, _median_posted(lines)) for at, lines in consensus.items())
        series = [item for item in series if item[1] is not None]
        if not series:
            continue
        books_at_open = consensus.get(series[0][0]) or []
        book_label = 'median' if len(books_at_open) > 1 else (
            next(iter(home_by_book)) if len(home_by_book) == 1 else 'median'
        )
        if len(home_by_book) == 1:
            book_label = next(iter(home_by_book))
        open_at, open_line = series[0]
        close_at, close_line = series[-1]
        same_snapshot = open_at == close_at
        late_from, late_to = _late_pair(series, start)
        path = [line for _, line in series]
        keys = _crossed(path) if market == 'spreads' and not same_snapshot else None
        if market != 'spreads':
            keys = None
        pinnacle, retail = (None, None)
        if market == 'spreads':
            pinnacle, retail = _disagreement(home_by_book, close_at)
        steam = _steam(home_by_book) if market == 'spreads' and not same_snapshot else None
        moves.append({
            'eventId': event_id,
            'market': market,
            'home': sample.get('home'),
            'away': sample.get('away'),
            'homeName': _home_name(sample),
            'awayName': NAMES.get(sample.get('away')),
            'book': book_label,
            'player': player,
            'outcome': side,
            'kickoff': _iso(start),
            'openLine': open_line,
            'openAt': _iso(open_at),
            'closeLine': close_line,
            'closeAt': _iso(close_at),
            'openToClose': None if same_snapshot else round(close_line - open_line, 4),
            'lateFrom': late_from,
            'lateTo': late_to,
            'lateMove': None if late_from is None or late_to is None else round(late_to - late_from, 4),
            'keyNumbers': keys,
            'pinnacleLine': pinnacle,
            'retailLine': retail,
            'steam': steam,
            'againstPublic': 'unavailable',
        })
    moves.sort(key=lambda row: (
        row.get('kickoff') or '', row.get('eventId') or '', row.get('market') or '',
        row.get('player') or '', row.get('outcome') or '',
    ))
    return moves


def moves_document(history):
    budget = history.get('budget') or budget_template()
    return {
        'schema': 'coach-line-moves-v1',
        'updatedAt': history.get('updatedAt'),
        'adopted': False,
        'notice': (
            'Movement is computed from saved prices. A missing price stays unavailable. '
            'The served chance is unchanged. This is a comparison, not a pick.'
        ),
        'budget': {
            'freePlanCredits': budget.get('freePlanCredits'),
            'gameLineCap': budget.get('gameLineCap'),
            'propCap': budget.get('propCap'),
            'gameLineSpent': budget.get('gameLineSpent'),
            'propSpent': budget.get('propSpent'),
            'reserve': budget.get('reserve'),
            'month': budget.get('month'),
            'note': budget.get('note'),
        },
        'moves': history.get('moves') or [],
    }


def parse_odds_api(payload, at):
    """Rows from a game-odds or event-odds response. The key is not read."""
    if isinstance(payload, dict):
        payload = [payload]
    if not isinstance(payload, list):
        return []
    rows = []
    for event in payload:
        if not isinstance(event, dict):
            continue
        event_id = str(event.get('id') or '').strip()
        home = event.get('home_team')
        away = event.get('away_team')
        kickoff = event.get('commence_time')
        if not event_id or not home or not away:
            continue
        for book in event.get('bookmakers') or []:
            if not isinstance(book, dict):
                continue
            book_key = str(book.get('key') or '').strip().lower()
            if not book_key:
                continue
            for market in book.get('markets') or []:
                if not isinstance(market, dict):
                    continue
                kind = str(market.get('key') or '')
                for outcome in market.get('outcomes') or []:
                    if not isinstance(outcome, dict):
                        continue
                    decimal = _number(outcome.get('price'))
                    if decimal is None or decimal <= 1:
                        continue
                    player = ''
                    name = outcome.get('name') or ''
                    if kind.startswith('player_'):
                        player = str(outcome.get('description') or '').strip()
                        if not player:
                            continue
                    rows.append({
                        'at': at,
                        'source': 'the-odds-api',
                        'book': book_key,
                        'eventId': event_id,
                        'kickoff': kickoff,
                        'away': _abbr(away),
                        'home': _abbr(home),
                        'market': kind,
                        'outcome': name,
                        'player': player,
                        'line': _number(outcome.get('point')),
                        'decimal': decimal,
                        'status': 'open',
                    })
    return rows


def events_kickoffs(payload):
    kickoffs = []
    if not isinstance(payload, list):
        return kickoffs
    for event in payload:
        if isinstance(event, dict) and event.get('commence_time'):
            parsed = _parse(event['commence_time'])
            if parsed is not None:
                kickoffs.append(parsed)
    return kickoffs


def earliest_prop_event(payload, now, horizon_minutes=6 * 60 + 20):
    """The soonest game inside the late window. None when the list is empty."""
    if not isinstance(payload, list):
        return None
    chosen = None
    for event in payload:
        if not isinstance(event, dict) or not event.get('id') or not event.get('commence_time'):
            continue
        start = _parse(event['commence_time'])
        if start is None or start <= now:
            continue
        minutes = (start - now).total_seconds() / 60
        if minutes > horizon_minutes:
            continue
        if chosen is None or start < chosen[0]:
            chosen = (start, str(event['id']))
    return None if chosen is None else chosen[1]


def rotating_prop_market(spent):
    return PROP_MARKETS[int(spent) % len(PROP_MARKETS)]


def slot_covered(history, cluster_iso, slot, now):
    """True when a game line was already saved inside this slot's window."""
    target = SLOT_MINUTES[slot]
    for row in history.get('observations') or []:
        if row.get('market') not in ('h2h', 'spreads', 'totals'):
            continue
        start = _parse(row.get('kickoff'))
        at = _parse(row.get('at'))
        if start is None or at is None or at >= start:
            continue
        if _iso(cluster_kickoff(start)) != cluster_iso:
            continue
        minutes_left = (start - at).total_seconds() / 60
        if (target - 45) <= minutes_left <= (target + 30):
            return True
    return False


def prop_slot_covered(history, event_id, slot):
    target = SLOT_MINUTES[slot]
    for row in history.get('observations') or []:
        if row.get('eventId') != event_id or not str(row.get('market') or '').startswith('player_'):
            continue
        start = _parse(row.get('kickoff'))
        at = _parse(row.get('at'))
        if start is None or at is None or at >= start:
            continue
        minutes_left = (start - at).total_seconds() / 60
        if (target - 45) <= minutes_left <= (target + 30):
            return True
    return False
