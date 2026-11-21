"""Save game and prop prices Coach already has, plus an optional public scrape.

The scrape is logged out. It does not use an account, a paid proxy, or a
key stored in the repo. A book that blocks the request is marked unavailable.
Nothing in the saved file is invented. A missing price stays out of the file.

The closing price of a side is the last saved price whose timestamp is
strictly before kickoff. Reading a snapshot does not spend an Odds API credit.
"""

import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

import line_timing

SCHEMA = 'coach-price-history-v1'
GRADE_SCHEMA = 'coach-self-grade-v1'
RETENTION_DAYS = 90
MAX_OBSERVATIONS = 25000
PAUSE_SECONDS = 2
USER_AGENT = (
    'CoachResearch/1.0 (logged-out public odds; +https://addversity.github.io/coach/)'
)

# Real closing prop prices replace last season's median only after this many
# closes of that market. Chosen as the same 1,000-game floor used elsewhere,
# before any graded result existed.
REAL_CLOSE_GATE = 1000

PROP_MARKETS = {
    'player_pass_yds': 'passing yards props',
    'player_rush_yds': 'rushing yards props',
    'player_reception_yds': 'receiving yards props',
    'player_receptions': 'reception props',
    'player_pass_attempts': 'pass attempt props',
    'player_pass_completions': 'pass completion props',
    'player_pass_tds': 'passing touchdown props',
    'player_anytime_td': 'anytime touchdown props',
}
GAME_MARKETS = {
    'h2h': 'moneylines',
    'spreads': 'spreads',
    'totals': 'totals',
}

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
ABBR = {value: key for key, value in TEAMS.items()}
ABBR_ALIASES = {'LA': 'LAR', 'OAK': 'LV', 'SD': 'LAC', 'STL': 'LAR', 'JAC': 'JAX'}


def empty_history():
    return {
        'schema': SCHEMA,
        'updatedAt': None,
        'retentionDays': RETENTION_DAYS,
        'notice': (
            'Prices are observations Coach saved or read from a public logged-out '
            'sportsbook page. A missing book is unavailable. This is not a pick.'
        ),
        'sources': [],
        'observations': [],
        'closes': [],
        'opens': [],
        'moves': [],
        'cadence': [],
        'budget': None,
        'cards': [],
    }


def _now():
    return datetime.now(timezone.utc)


def _iso(at):
    if isinstance(at, datetime):
        if at.tzinfo is None:
            raise ValueError('A timestamp needs a timezone.')
        return at.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')
    text = str(at).strip()
    if not text:
        return None
    parsed = _parse_time(text)
    return _iso(parsed) if parsed else None


def _parse_time(value):
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    if text.endswith('Z'):
        text = text[:-1] + '+00:00'
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _number(value):
    if value is None or value == '':
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if number != number:  # NaN
        return None
    return number


def decimal_from_american(value):
    american = _number(value)
    if american is None or american == 0:
        return None
    if american > 0:
        decimal = 1 + american / 100
    else:
        decimal = 1 + 100 / abs(american)
    if decimal <= 1:
        return None
    return round(decimal, 6)


def _abbr(name):
    if not name:
        return None
    text = str(name).strip()
    if text in ABBR:
        return text
    return TEAMS.get(text)


def _event_parts(event_id):
    """nflverse:2026_11_ARI_KC -> season, week, away, home."""
    text = str(event_id or '')
    if text.startswith('nflverse:'):
        text = text.split(':', 1)[1]
    parts = text.split('_')
    if len(parts) != 4:
        return None
    try:
        season, week = int(parts[0]), int(parts[1])
    except ValueError:
        return None
    away, home = ABBR_ALIASES.get(parts[2], parts[2]), ABBR_ALIASES.get(parts[3], parts[3])
    if away not in ABBR or home not in ABBR:
        return None
    return season, week, away, home


def _observation(row):
    at = _iso(row.get('at'))
    decimal = _number(row.get('decimal'))
    market = str(row.get('market') or '').strip()
    book = str(row.get('book') or '').strip().lower()
    event_id = str(row.get('eventId') or '').strip()
    outcome = str(row.get('outcome') or '').strip()
    if not at or decimal is None or decimal <= 1 or not market or not book or not event_id or not outcome:
        return None
    if row.get('demo') is True:
        return None
    line = _number(row.get('line'))
    player = str(row.get('player') or '').strip()
    kickoff = _iso(row.get('kickoff')) if row.get('kickoff') else None
    parts = _event_parts(event_id)
    parsed = {
        'at': at,
        'source': str(row.get('source') or 'saved'),
        'book': book,
        'eventId': event_id,
        'kickoff': kickoff,
        'season': parts[0] if parts else row.get('season'),
        'week': parts[1] if parts else row.get('week'),
        'away': parts[2] if parts else _abbr(row.get('away')),
        'home': parts[3] if parts else _abbr(row.get('home')),
        'market': market,
        'outcome': outcome,
        'player': player,
        'line': line,
        'decimal': round(decimal, 6),
        'status': str(row.get('status') or 'open'),
    }
    player_id = str(row.get('playerId') or '').strip()
    if re.fullmatch(r'00-\d{7}', player_id):
        parsed['playerId'] = player_id
    return parsed


def _key(row):
    return (
        row['book'], row['eventId'], row['market'], row['player'],
        row['outcome'], row['line'], row['decimal'], row['at'],
    )


def _side_key(row):
    return (row['book'], row['eventId'], row['market'], row['player'], row['outcome'])


def add_observations(history, rows):
    """Append new prices. Identical rows are not stored twice."""
    seen = {_key(row) for row in history['observations']}
    added = 0
    for raw in rows:
        row = _observation(raw)
        if row is None or _key(row) in seen:
            continue
        seen.add(_key(row))
        history['observations'].append(row)
        added += 1
    if added == 0:
        return 0
    _trim(history)
    refresh_derived(history)
    history['updatedAt'] = _iso(_now())
    return added


def _trim(history):
    cutoff = _now() - timedelta(days=RETENTION_DAYS)
    close_ids = set()
    # Retention keeps every row until closes are recomputed; drop only ancient
    # rows beyond the cap after the close pass. The cap prefers newer rows.
    if len(history['observations']) > MAX_OBSERVATIONS:
        history['observations'].sort(key=lambda row: row['at'])
        history['observations'] = history['observations'][-MAX_OBSERVATIONS:]
    kept = []
    for row in history['observations']:
        at = _parse_time(row['at'])
        if at is not None and at < cutoff and _side_key(row) not in close_ids:
            # Ancient rows are dropped after closes are known. First pass keeps
            # them so a close older than the window can still be chosen, then
            # a second trim below removes non-closes.
            kept.append(row)
        else:
            kept.append(row)
    history['observations'] = kept


def recompute_closes(history):
    grouped = {}
    for row in history['observations']:
        grouped.setdefault(_side_key(row), []).append(row)
    closes = []
    for rows in grouped.values():
        rows.sort(key=lambda row: row['at'])
        kickoff = next((row['kickoff'] for row in reversed(rows) if row.get('kickoff')), None)
        chosen = None
        for row in rows:
            if not kickoff:
                continue
            if row['at'] < kickoff:
                chosen = row
        if chosen is None:
            continue
        close = dict(chosen)
        close['close'] = True
        closes.append(close)
    closes.sort(key=lambda row: (row['kickoff'] or '', row['eventId'], row['market'], row['book'], row['player'], row['outcome']))
    history['closes'] = closes
    cutoff = _now() - timedelta(days=RETENTION_DAYS)
    close_keys = {_key(row) for row in closes}
    history['observations'] = [
        row for row in history['observations']
        if (_parse_time(row['at']) or _now()) >= cutoff or _key(row) in close_keys
    ]
    history['observations'].sort(key=lambda row: (row['at'], row['book'], row['eventId'], row['market'], row['player'], row['outcome']))
    return closes


def refresh_derived(history, now=None):
    """Opens, closes, and movement rows. Does not set updatedAt or spend a credit."""
    now = now or _now()
    recompute_closes(history)
    line_timing.recompute_opens(history)
    line_timing.ensure_budget(history, now)
    history['moves'] = line_timing.build_moves(history.get('observations') or [])
    history.setdefault('cadence', [])
    return history


def record_source(history, source, status, detail):
    """Remember a book's last check. An unchanged status is not rewritten."""
    detail = str(detail or '')[:180]
    for row in history['sources']:
        if row['source'] == source and row['status'] == status and row['detail'] == detail:
            return False
    history['sources'] = [row for row in history['sources'] if row['source'] != source]
    history['sources'].append({
        'source': source,
        'status': status,
        'detail': detail,
        'checkedAt': _iso(_now()),
    })
    history['sources'].sort(key=lambda row: row['source'])
    return True


def ingest_snapshot(history, snapshot):
    """Copy quotes from a snapshot Coach already published. No new credit."""
    if not isinstance(snapshot, dict):
        return 0
    events = {}
    for board_name in ('board', 'props'):
        board = snapshot.get(board_name) or {}
        for event in board.get('events') or []:
            if isinstance(event, dict) and event.get('id'):
                events[event['id']] = event
    rows = []
    for board_name in ('props', 'board'):
        board = snapshot.get(board_name) or {}
        for quote in board.get('quotes') or []:
            if not isinstance(quote, dict) or quote.get('demo') is True:
                continue
            selection = quote.get('selection') or {}
            event = events.get(selection.get('eventId')) or {}
            market = selection.get('market')
            player = selection.get('participant') or ''
            if str(market or '').startswith('player_') and not player:
                player = selection.get('outcome') or ''
            rows.append({
                'at': quote.get('collectedAt') or quote.get('sourceAt') or snapshot.get('generatedAt'),
                'source': quote.get('provider') or 'the-odds-api',
                'book': quote.get('bookId') or quote.get('book'),
                'eventId': selection.get('eventId'),
                'kickoff': event.get('startsAt'),
                'away': event.get('away'),
                'home': event.get('home'),
                'market': market,
                'outcome': selection.get('outcome'),
                'player': player if str(market or '').startswith('player_') else '',
                'line': selection.get('point'),
                'decimal': quote.get('decimal'),
                'status': quote.get('status') or 'open',
                'demo': quote.get('demo'),
            })
    return add_observations(history, rows)


def record_card(history, card):
    """A card Coach showed: the chance and the side, beside the price."""
    chance = _number(card.get('chance'))
    at = _iso(card.get('at'))
    side = str(card.get('side') or '').strip().lower()
    if chance is None or not 0 < chance < 1 or not at or side not in ('over', 'under', 'home', 'away'):
        return False
    row = {
        'at': at,
        'eventId': str(card.get('eventId') or ''),
        'market': str(card.get('market') or ''),
        'player': str(card.get('player') or ''),
        'side': side,
        'outcome': str(card.get('outcome') or ''),
        'line': _number(card.get('line')),
        'decimal': _number(card.get('decimal')),
        'book': str(card.get('book') or '').lower(),
        'chance': round(chance, 6),
    }
    if not row['eventId'] or not row['market']:
        return False
    identity = (row['at'], row['eventId'], row['market'], row['player'], row['side'], row['line'], row['book'])
    existing = {
        (item['at'], item['eventId'], item['market'], item['player'], item['side'], item['line'], item['book'])
        for item in history['cards']
    }
    if identity in existing:
        return False
    history['cards'].append(row)
    history['updatedAt'] = _iso(_now())
    return True


def _implied(decimal):
    if decimal is None or decimal <= 1:
        return None
    return 1 / decimal


def build_grade(history, results=None):
    """Grade stored cards. A result that is not supplied stays unavailable.

    [results] maps (eventId, market, player, side) to 'hit', 'miss', or 'push'.
    CLV is the closing implied probability minus the card's implied probability,
    in probability points, for the same book, market, player and side. One
    snapshot cannot be its own close, so CLV stays empty until a later price
    exists.
    """
    results = results or {}
    closes = {}
    for row in history['closes']:
        closes.setdefault(_side_key(row), []).append(row)
    markets = {**{key: _blank(key) for key in PROP_MARKETS}, **{key: _blank(key) for key in GAME_MARKETS}}
    for row in history['observations']:
        bucket = markets.setdefault(row['market'], _blank(row['market']))
        bucket['savedPrices'] += 1
    for card in history['cards']:
        bucket = markets.setdefault(card['market'], _blank(card['market']))
        bucket['cards'] += 1
        outcome = _card_outcome(card)
        side_rows = closes.get((card['book'], card['eventId'], card['market'], card['player'], outcome), [])
        later = [row for row in side_rows if row['at'] > card['at']]
        close = later[-1] if later else None
        result = results.get((card['eventId'], card['market'], card['player'], card['side']))
        if result not in ('hit', 'miss', 'push'):
            continue
        bucket['graded'] += 1
        if result == 'hit':
            bucket['hits'] += 1
        elif result == 'push':
            bucket['pushes'] += 1
        bucket['chanceSum'] = (bucket['chanceSum'] or 0) + card['chance']
        if close is not None and card.get('decimal'):
            opened = _implied(card['decimal'])
            closed = _implied(close['decimal'])
            if opened is not None and closed is not None:
                bucket['clvSum'] = (bucket['clvSum'] or 0) + (opened - closed)
                bucket['clvCount'] += 1
    prop_closes = sum(1 for row in history['closes'] if str(row['market']).startswith('player_'))
    return {
        'schema': GRADE_SCHEMA,
        'updatedAt': history.get('updatedAt'),
        'propCloses': prop_closes,
        'realCloseGate': REAL_CLOSE_GATE,
        'sources': history.get('sources') or [],
        'markets': markets,
        'notice': (
            'A grade compares a card Coach saved before a later price. '
            'Missing chances and missing closes stay unavailable. '
            'This is a record of those cards, not a pick and not a betting edge.'
        ),
    }


def _blank(market):
    return {
        'market': market,
        'label': PROP_MARKETS.get(market) or GAME_MARKETS.get(market) or market,
        'savedPrices': 0,
        'cards': 0,
        'graded': 0,
        'hits': 0,
        'pushes': 0,
        'chanceSum': None,
        'clvSum': None,
        'clvCount': 0,
    }


def _card_outcome(card):
    if card.get('outcome'):
        return card['outcome']
    side = card['side']
    if side == 'over':
        return 'Over'
    if side == 'under':
        return 'Under'
    return side


def prop_close_count(history, market):
    return sum(1 for row in history.get('closes') or [] if row.get('market') == market)


def median_or_close(median, close, closes_for_market, gate=REAL_CLOSE_GATE):
    """The walk-forward line. The median stays until enough real closes exist."""
    if close is None or closes_for_market < gate:
        return median
    return close


def load_history(path):
    file = Path(path)
    if not file.exists():
        return empty_history()
    data = json.loads(file.read_text())
    if data.get('schema') != SCHEMA:
        raise ValueError(f'{path} is not a Coach price history file.')
    data.setdefault('sources', [])
    data.setdefault('observations', [])
    data.setdefault('closes', [])
    data.setdefault('opens', [])
    data.setdefault('moves', [])
    data.setdefault('cadence', [])
    data.setdefault('cards', [])
    data.setdefault('budget', None)
    return data


def save_json(path, payload):
    Path(path).write_text(json.dumps(payload, indent=2) + '\n')


class FetchResult:
    def __init__(self, status, body, headers=None):
        self.status = status
        self.body = body
        self.headers = {str(key).lower(): value for key, value in (headers or {}).items()}


def http_fetch(url, headers):
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            return FetchResult(
                response.status,
                response.read(8_000_000).decode('utf-8', 'replace'),
                response.headers,
            )
    except urllib.error.HTTPError as error:
        return FetchResult(error.code, '', getattr(error, 'headers', None))
    except Exception:
        return FetchResult(0, '', {})


def _headers(extra=None):
    headers = {'User-Agent': USER_AGENT, 'Accept': 'application/json,text/html;q=0.8'}
    if extra:
        headers.update(extra)
    return headers


def scrape_public_books(
    history, fetch=http_fetch, pause=time.sleep, private=None, windows=None,
    roster=None, schedule=None, now=None, hours=26,
):
    """Read logged-out prop pages. Prices go to [private] when that file is separate.

    The public history keeps the book status and the count. It does not keep
    the scraped prices. A blocked page is unavailable.
    """
    import book_props
    now = now or _now()
    found = book_props.collect_books(fetch, pause, windows, now, hours)
    added = book_props.apply_collection(history, private, found, roster, schedule)
    try:
        book_props.collect_probes(history, fetch, pause, now)
        if private is not None and private is not history:
            for row in history.get('sources') or []:
                if str(row.get('source') or '').endswith('-public'):
                    record_source(private, row['source'], row['status'], row.get('detail') or '')
    except Exception:
        record_source(history, 'public-books', 'unavailable', 'the public page could not be read')
    return added


def _json(body):
    if not body:
        return None
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return None


def _draftkings(fetch):
    result = fetch(
        'https://sportsbook.draftkings.com/sites/US-VA-SB/api/v5/eventgroups/88808?format=json',
        _headers({'Referer': 'https://sportsbook.draftkings.com/leagues/football/nfl'}),
    )
    if result.status != 200:
        return 'unavailable', [], f'HTTP {result.status or "none"}'
    payload = _json(result.body)
    rows = parse_draftkings(payload) if payload else []
    if not rows:
        return 'unavailable', [], 'the public response had no prices'
    return 'ok', rows, ''


def parse_draftkings(payload):
    group = (payload or {}).get('eventGroup') or {}
    events = {str(event.get('eventId')): event for event in group.get('events') or [] if isinstance(event, dict)}
    rows = []
    for category in group.get('offerCategories') or []:
        for descriptor in category.get('offerSubcategoryDescriptors') or []:
            subcategory = (descriptor or {}).get('offerSubcategory') or {}
            for group_offers in subcategory.get('offers') or []:
                for offer in group_offers or []:
                    if not isinstance(offer, dict):
                        continue
                    event = events.get(str(offer.get('eventId')))
                    market = _book_market(offer.get('label') or category.get('name') or '')
                    if event is None or market is None:
                        continue
                    for outcome in offer.get('outcomes') or []:
                        row = _american_row(
                            book='draftkings',
                            event=event,
                            event_id=str(offer.get('eventId')),
                            market=market,
                            outcome=outcome,
                            player=offer.get('label') if market.startswith('player_') else '',
                        )
                        if row:
                            rows.append(row)
    return rows


def _fanduel(fetch):
    page = fetch('https://sportsbook.fanduel.com/navigation/nfl', _headers({'Accept': 'text/html'}))
    if page.status != 200 or not page.body:
        return 'unavailable', [], f'HTTP {page.status or "none"}'
    found = re.search(r'"clientId":"([0-9a-f]{16,})"', page.body)
    if not found:
        return 'unavailable', [], 'the public page had no logged-out feed'
    url = (
        'https://api.sportsbook.fanduel.com/sbapi/content-managed-page'
        f'?page=CUSTOM&customPageId=nfl&pbHorizontal=false&_ak={found.group(1)}'
        '&timezone=America/New_York'
    )
    result = fetch(url, _headers({
        'x-sportsbook-region': 'NJ',
        'Referer': 'https://sportsbook.fanduel.com/navigation/nfl',
    }))
    if result.status != 200:
        return 'unavailable', [], f'HTTP {result.status or "none"}'
    rows = parse_fanduel(_json(result.body))
    if not rows:
        return 'unavailable', [], 'the public response had no prices'
    return 'ok', rows, ''


def parse_fanduel(payload):
    attachments = (payload or {}).get('attachments') or {}
    events = attachments.get('events') or {}
    rows = []
    for market in (attachments.get('markets') or {}).values():
        if not isinstance(market, dict):
            continue
        name = _book_market(market.get('marketName') or '')
        event = events.get(str(market.get('eventId'))) or {}
        if name is None or not event:
            continue
        for runner in market.get('runners') or []:
            odds = ((runner.get('winRunnerOdds') or {}).get('trueOdds') or {}).get('decimalOdds') or {}
            decimal = _number(odds.get('decimalOdds'))
            if decimal is None or decimal <= 1:
                american = (((runner.get('winRunnerOdds') or {}).get('americanDisplayOdds') or {}).get('americanOdds'))
                decimal = decimal_from_american(american)
            if decimal is None:
                continue
            rows.append({
                'at': _iso(_now()),
                'book': 'fanduel',
                'eventId': str(market.get('eventId')),
                'kickoff': event.get('openDate'),
                'away': _abbr(_team_from_name(event.get('name'), 0)),
                'home': _abbr(_team_from_name(event.get('name'), 1)),
                'market': name,
                'outcome': runner.get('runnerName') or '',
                'player': runner.get('runnerName') if name.startswith('player_') else '',
                'line': _number(runner.get('handicap')),
                'decimal': decimal,
                'status': 'open',
            })
    return [row for row in rows if row['outcome']]


def _betmgm(fetch):
    page = fetch('https://sports.nj.betmgm.com/en/sports/football-11', _headers({'Accept': 'text/html'}))
    if page.status != 200 or not page.body:
        return 'unavailable', [], f'HTTP {page.status or "none"}'
    found = re.search(r'x-bwin-accessid(?:=|":"|": ")([A-Za-z0-9-]{16,})', page.body)
    if not found:
        return 'unavailable', [], 'the public page had no logged-out feed'
    url = (
        'https://sports.nj.betmgm.com/cds-api/bettingoffer/fixtures'
        f'?x-bwin-accessid={found.group(1)}&lang=en-us&country=US&userCountry=US'
        '&subdivision=US-New%20Jersey&fixtureTypes=Standard&sportIds=11'
        '&isPriceBoost=false&statisticsModes=None&skip=0&take=50'
    )
    result = fetch(url, _headers({'Referer': 'https://sports.nj.betmgm.com/en/sports/football-11'}))
    if result.status != 200:
        return 'unavailable', [], f'HTTP {result.status or "none"}'
    rows = parse_betmgm(_json(result.body))
    if not rows:
        return 'unavailable', [], 'the public response had no prices'
    return 'ok', rows, ''


def parse_betmgm(payload):
    rows = []
    for fixture in (payload or {}).get('fixtures') or []:
        if not isinstance(fixture, dict):
            continue
        for game in fixture.get('games') or []:
            market = _book_market(game.get('name') or '')
            if market is None:
                continue
            for result in game.get('results') or []:
                decimal = _number(result.get('odds'))
                if decimal is None or decimal <= 1:
                    decimal = decimal_from_american(result.get('americanOdds'))
                if decimal is None:
                    continue
                rows.append({
                    'at': _iso(_now()),
                    'book': 'betmgm',
                    'eventId': str(fixture.get('id')),
                    'kickoff': fixture.get('startDate'),
                    'market': market,
                    'outcome': result.get('name') or '',
                    'player': (game.get('name') or '') if market.startswith('player_') else '',
                    'line': _number(result.get('attr') or game.get('attr')),
                    'decimal': decimal,
                    'status': 'open',
                })
    return [row for row in rows if row['outcome']]


def _pinnacle(fetch):
    config = fetch('https://www.pinnacle.com/config/app.json', _headers())
    if config.status != 200:
        return 'unavailable', [], f'HTTP {config.status or "none"}'
    payload = _json(config.body) or {}
    haywire = ((payload.get('api') or {}).get('haywire') or {})
    key = haywire.get('apiKey')
    guest = (((haywire.get('routes') or {}).get('nolicense') or {}).get('guestRoot'))
    version = haywire.get('apiVersion') or '0.1'
    if not key or not guest:
        return 'unavailable', [], 'the public page had no logged-out feed'
    # The key stays in this request. It is not returned and not written.
    result = fetch(
        f'{guest}/{version}/sports/15/leagues?brandId=0',
        _headers({'X-API-Key': key}),
    )
    if result.status != 200:
        return 'unavailable', [], f'HTTP {result.status or "none"}'
    leagues = _json(result.body)
    league_id = _nfl_league_id(leagues)
    if league_id is None:
        return 'unavailable', [], 'the public response had no NFL league'
    matchups = fetch(
        f'{guest}/{version}/leagues/{league_id}/matchups?brandId=0',
        _headers({'X-API-Key': key}),
    )
    markets = fetch(
        f'{guest}/{version}/leagues/{league_id}/markets/straight?brandId=0',
        _headers({'X-API-Key': key}),
    )
    if matchups.status != 200 or markets.status != 200:
        return 'unavailable', [], f'HTTP {matchups.status or markets.status or "none"}'
    rows = parse_pinnacle(_json(matchups.body), _json(markets.body))
    if not rows:
        return 'unavailable', [], 'the public response had no prices'
    return 'ok', rows, ''


def _nfl_league_id(payload):
    rows = payload if isinstance(payload, list) else (payload or {}).get('leagues') or []
    for row in rows:
        if not isinstance(row, dict):
            continue
        name = str(row.get('name') or '')
        if name.strip().upper() == 'NFL':
            return row.get('id')
    return None


def parse_pinnacle(matchups, markets):
    events = {}
    for row in matchups or []:
        if isinstance(row, dict) and row.get('id') is not None:
            events[row['id']] = row
    rows = []
    for market in markets or []:
        if not isinstance(market, dict):
            continue
        event = events.get(market.get('matchupId'))
        kind = _book_market(str(market.get('type') or ''))
        if event is None or kind is None:
            continue
        for price in market.get('prices') or []:
            decimal = _number(price.get('price'))
            if decimal is None or decimal <= 1:
                continue
            designation = str(price.get('designation') or price.get('participantId') or '')
            rows.append({
                'at': _iso(_now()),
                'book': 'pinnacle',
                'eventId': str(market.get('matchupId')),
                'kickoff': event.get('startTime'),
                'market': kind,
                'outcome': designation,
                'player': '',
                'line': _number(price.get('points')),
                'decimal': decimal,
                'status': 'open',
            })
    return [row for row in rows if row['outcome']]


def _book_market(label):
    text = str(label or '').lower()
    if 'receiving yard' in text or 'reception yard' in text or 'rec yds' in text:
        return 'player_reception_yds'
    if 'reception' in text and 'yard' not in text:
        return 'player_receptions'
    if 'rushing yard' in text or 'rush yds' in text:
        return 'player_rush_yds'
    if 'passing yard' in text or 'pass yds' in text:
        return 'player_pass_yds'
    if 'total' in text or text in ('over/under', 'ou'):
        return 'totals'
    if 'spread' in text or 'handicap' in text or 'point spread' in text:
        return 'spreads'
    if 'moneyline' in text or text in ('money line', 'ml', 'h2h'):
        return 'h2h'
    return None


def _team_from_name(name, index):
    parts = re.split(r'\s+@\s+|\s+v\s+|\s+vs\.?\s+', str(name or ''), maxsplit=1)
    if len(parts) != 2:
        return None
    return parts[index].strip()


def _american_row(book, event, event_id, market, outcome, player):
    if not isinstance(outcome, dict):
        return None
    decimal = decimal_from_american(outcome.get('oddsAmerican'))
    if decimal is None:
        decimal = _number(outcome.get('oddsDecimal'))
    if decimal is None or decimal <= 1:
        return None
    name = outcome.get('label') or outcome.get('participant') or ''
    return {
        'at': _iso(_now()),
        'book': book,
        'eventId': event_id,
        'kickoff': event.get('startDate') or event.get('startTime'),
        'away': _abbr(event.get('teamName1') or event.get('awayTeamName')),
        'home': _abbr(event.get('teamName2') or event.get('homeTeamName')),
        'market': market,
        'outcome': name,
        'player': player if market.startswith('player_') else '',
        'line': _number(outcome.get('line')),
        'decimal': decimal,
        'status': 'open',
    }


def _api_key():
    return (os.environ.get('THE_ODDS_API_KEY') or os.environ.get('ODDS_API_KEY') or '').strip()


def _api_get(path, params, fetch, key):
    query = dict(params)
    query['apiKey'] = key
    url = 'https://api.the-odds-api.com/v4/' + path + '?' + urllib.parse.urlencode(query)
    return fetch(url, _headers())


def capture_dense(
    history, snapshot, fetch=http_fetch, pause=time.sleep, now=None, key='',
    private=None, windows=None, roster=None, schedule=None,
):
    """Scrape when a pre-kickoff slot is due. Spend Odds API credits only inside the cap.

    The key is used on the request and is not written to the history.
    """
    now = now or _now()
    key = (key or '').strip()
    summary = {'slots': 0, 'scraped': False, 'gameCredits': 0, 'propCredits': 0}
    if key and line_timing.season_months(now):
        events = _api_get(
            'sports/americanfootball_nfl/events',
            {'dateFormat': 'iso'},
            fetch,
            key,
        )
        if events.status == 200:
            event_payload = _json(events.body)
            remaining = line_timing.header_int(events.headers, 'x-requests-remaining')
            budget = line_timing.ensure_budget(history, now)
            # A missing header is not a number. Do not keep an older one.
            budget['requestsRemaining'] = remaining
        else:
            record_source(
                history,
                'the-odds-api-events',
                'unavailable',
                line_timing.redact(f'events HTTP {events.status or "none"}', key),
            )
            event_payload = None
            budget = line_timing.ensure_budget(history, now)
            budget['requestsRemaining'] = None
    else:
        event_payload = None
        remaining = (history.get('budget') or {}).get('requestsRemaining')

    # Fold free-event kickoffs into the due check by stashing them on a
    # temporary list the planner already understands: observation kickoffs.
    # A kickoff without a price is not an observation. Keep them beside cadence.
    if event_payload:
        history['eventKickoffs'] = []
        for event in event_payload:
            if not isinstance(event, dict) or not event.get('commence_time'):
                continue
            history['eventKickoffs'].append({
                'id': str(event.get('id') or ''),
                'kickoff': event.get('commence_time'),
                'home': line_timing._abbr(event.get('home_team')),
                'away': line_timing._abbr(event.get('away_team')),
            })
    work = _due_with_events(history, snapshot, now)
    if not work:
        history.pop('eventKickoffs', None)
        return summary
    summary['slots'] = len(work)
    if windows is None:
        windows = [kickoff for _cluster, _slot, kickoff in work]
    if line_timing.season_months(now) or work:
        scrape_public_books(
            history, fetch=fetch, pause=pause, private=private, windows=windows,
            roster=roster, schedule=schedule, now=now,
        )
        summary['scraped'] = True
    for cluster, slot, _kickoff in work:
        line_timing.record_attempt(history, cluster, slot, 'checked', now)
    budget = line_timing.ensure_budget(history, now)
    remaining = budget.get('requestsRemaining')
    needs_game = any(
        not line_timing.slot_covered(history, cluster, slot, now)
        for cluster, slot, _kickoff in work
    )
    in_season = line_timing.season_months(now)
    if key and in_season and needs_game:
        allowed, reason = line_timing.allow_spend(budget, 'game', remaining)
        if not allowed:
            record_source(history, 'the-odds-api-dense', 'unavailable', reason)
        else:
            result = _api_get(
                'sports/americanfootball_nfl/odds',
                {
                    'bookmakers': ','.join(line_timing.GAME_BOOKS),
                    'markets': 'h2h,spreads,totals',
                    'oddsFormat': 'decimal',
                    'dateFormat': 'iso',
                },
                fetch,
                key,
            )
            charged = line_timing.charged_amount(result.headers, line_timing.GAME_LINE_COST, result.status)
            remaining = line_timing.header_int(result.headers, 'x-requests-remaining')
            line_timing.record_spend(budget, 'game', charged, remaining)
            summary['gameCredits'] = charged
            rows = line_timing.parse_odds_api(_json(result.body), line_timing._iso(now)) if result.status == 200 else []
            if rows:
                add_observations(history, rows)
            record_source(
                history,
                'the-odds-api-dense',
                'ok' if rows else 'unavailable',
                line_timing.redact(
                    f'{len(rows)} game prices, {charged} credits' if rows else f'HTTP {result.status or "none"}',
                    key,
                ),
            )
    needs_prop = any(line_timing.SLOT_MINUTES[slot] <= 6 * 60 for _cluster, slot, _kickoff in work)
    event_id = line_timing.earliest_prop_event(event_payload, now) if event_payload else None
    if key and in_season and needs_prop and event_id and not any(
        line_timing.prop_slot_covered(history, event_id, slot) for _cluster, slot, _kickoff in work
    ):
        budget = line_timing.ensure_budget(history, now)
        remaining = budget.get('requestsRemaining')
        allowed, reason = line_timing.allow_spend(budget, 'prop', remaining)
        if not allowed:
            record_source(history, 'the-odds-api-props', 'unavailable', reason)
        else:
            market = line_timing.rotating_prop_market(budget.get('propSpent') or 0)
            result = _api_get(
                f'sports/americanfootball_nfl/events/{urllib.parse.quote(event_id)}/odds',
                {
                    'bookmakers': ','.join(line_timing.GAME_BOOKS),
                    'markets': market,
                    'oddsFormat': 'decimal',
                    'dateFormat': 'iso',
                },
                fetch,
                key,
            )
            charged = line_timing.charged_amount(result.headers, line_timing.PROP_COST, result.status)
            remaining = line_timing.header_int(result.headers, 'x-requests-remaining')
            line_timing.record_spend(budget, 'prop', charged, remaining)
            summary['propCredits'] = charged
            rows = line_timing.parse_odds_api(_json(result.body), line_timing._iso(now)) if result.status == 200 else []
            if rows:
                add_observations(history, rows)
            record_source(
                history,
                'the-odds-api-props',
                'ok' if rows else 'unavailable',
                line_timing.redact(
                    f'{len(rows)} {market} prices, {charged} credits' if rows else f'HTTP {result.status or "none"}',
                    key,
                ),
            )
    history.pop('eventKickoffs', None)
    refresh_derived(history, now)
    return summary


def _due_with_events(history, snapshot, now):
    """Due slots from the snapshot, saved prices, and the free events list."""
    work = line_timing.due_work(history, snapshot, now)
    seen = {(cluster, slot) for cluster, slot, _kickoff in work}
    for event in history.get('eventKickoffs') or []:
        parsed = line_timing._parse(event.get('kickoff'))
        if parsed is None or parsed <= now or (parsed - now) > timedelta(hours=26):
            continue
        cluster = line_timing._iso(line_timing.cluster_kickoff(parsed))
        minutes = (parsed - now).total_seconds() / 60
        for slot in line_timing.slots_to_capture(minutes, line_timing.attempted_slots(history, cluster)):
            if (cluster, slot) in seen:
                continue
            seen.add((cluster, slot))
            work.append((cluster, slot, parsed))
    return work


def main(argv):
    import argparse
    parser = argparse.ArgumentParser(description='Update Coach price history without a new paid feed.')
    parser.add_argument('--history', default='assets/price-history.json')
    parser.add_argument('--grade-output', default='assets/self-grade.json')
    parser.add_argument('--moves-output', default='assets/line-moves.json')
    parser.add_argument('--snapshot')
    parser.add_argument('--snapshot-url')
    parser.add_argument('--scrape', action='store_true')
    parser.add_argument('--dense', action='store_true', help='Scrape and maybe spend credits only when a pre-kickoff slot is due.')
    parser.add_argument('--grade', action='store_true')
    parser.add_argument('--book-store', default='backend/data/book-props.json')
    parser.add_argument('--coverage', default='assets/book-price-coverage.json')
    parser.add_argument('--roster', default='assets/nfl-player-stats.json')
    parser.add_argument('--schedule', default='backend/data/games.csv')
    args = parser.parse_args(argv)
    history = load_history(args.history)
    snapshot = None
    if args.snapshot or args.snapshot_url:
        if args.snapshot_url:
            result = http_fetch(args.snapshot_url, _headers())
            if result.status != 200 or not result.body:
                record_source(history, 'the-odds-api', 'unavailable', f'published snapshot HTTP {result.status or "none"}')
                snapshot = None
            else:
                snapshot = _json(result.body)
                record_source(history, 'the-odds-api', 'ok' if snapshot else 'unavailable', 'published snapshot')
        else:
            snapshot = json.loads(Path(args.snapshot).read_text())
            record_source(history, 'the-odds-api', 'ok', 'local published snapshot')
        if snapshot:
            ingest_snapshot(history, snapshot)
    private = None
    if args.dense or args.scrape:
        import book_props
        private = load_history(args.book_store)
        roster = book_props.load_roster_file(args.roster) if Path(args.roster).exists() else {}
        schedule = book_props.ensure_schedule(args.schedule, http_fetch)
        if args.dense:
            capture_dense(
                history, snapshot, key=_api_key(), private=private,
                roster=roster, schedule=schedule,
            )
        else:
            scrape_public_books(history, private=private, roster=roster, schedule=schedule)
        Path(args.book_store).parent.mkdir(parents=True, exist_ok=True)
        save_json(args.book_store, private)
        save_json(args.coverage, book_props.coverage_document(private))
        secret = os.environ.get('BOOK_PROPS_INGEST_SECRET') or ''
        if secret:
            pushed = book_props.push_latest(
                private,
                os.environ.get('BOOK_PROPS_INGEST_URL') or '',
                secret,
                http_fetch,
            )
            if not pushed:
                record_source(history, 'book-props-worker', 'unavailable', 'the private store was not accepted')
    refresh_derived(history)
    if args.grade or args.scrape or args.dense or args.snapshot or args.snapshot_url:
        save_json(args.history, history)
        save_json(args.grade_output, build_grade(history))
        save_json(args.moves_output, line_timing.moves_document(history))
    return 0


if __name__ == '__main__':
    raise SystemExit(main(__import__('sys').argv[1:]))
