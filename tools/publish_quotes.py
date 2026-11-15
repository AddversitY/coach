"""Opt-in, budgeted NFL price pilot. Never exports provider payloads or keys.

Input is the v1 schedule from publish_snapshot.py. The default and every safely
unavailable case preserve that schedule. Private state contains only a credit
ledger and already-normalized observations, never raw responses. Authentication
uses x-api-key, as documented at https://the-odds-api.com/liveapi/guides/v4/.
"""
import argparse
import copy
import json
import math
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from publish_snapshot import TEAMS, ALIASES, SOURCE, iso

MARKETS = ('player_pass_yds', 'player_receptions', 'player_rush_yds', 'player_reception_yds')
BOOKS = {'draftkings': 'DraftKings', 'fanduel': 'FanDuel', 'betmgm': 'BetMGM',
         'williamhill_us': 'Caesars', 'espnbet': 'ESPN BET', 'fanatics': 'Fanatics',
         'betrivers': 'BetRivers', 'hardrockbet': 'Hard Rock Bet',
         'ballybet': 'Bally Bet', 'fliff': 'Fliff'}
PROVIDER = 'the-odds-api'
TTL = timedelta(hours=18)
COST, DAILY_CAP, MONTHLY_CAP, RESERVE = 4, 4, 60, 50
ROOT = Path(__file__).resolve().parents[1]


def at(value):
    if not isinstance(value, str):
        raise ValueError('Missing timestamp.')
    value = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if value.tzinfo is None:
        raise ValueError('Timestamp must include a timezone.')
    return value.astimezone(timezone.utc)


def canonical(value):
    if value in TEAMS.values():
        return value
    return TEAMS.get(ALIASES.get(value, value))


def validate_schedule(schedule, now):
    if schedule.get('schemaVersion') != 1 or schedule.get('odds', {}).get('status') != 'not_configured':
        raise ValueError('A version-one schedule is required.')
    source = schedule['schedule']
    fetched = at(source['fetchedAt'])
    generated = at(schedule['generatedAt'])
    if (source.get('source') != 'nflverse' or fetched > generated or
            generated > now + timedelta(minutes=5) or now - fetched > timedelta(hours=24)):
        raise ValueError('Schedule provenance is unavailable or outdated.')
    board, props = schedule['board'], schedule['props']
    if board != props or board.get('demo') is not False or board.get('quotes') != [] or at(board['fetchedAt']) != fetched:
        raise ValueError('Only an attributed schedule without prices can enter the pilot.')
    ids = set()
    for event in board['events']:
        if (not re.fullmatch(r'nflverse:[A-Za-z0-9_]+', event['id']) or event['id'] in ids or
                canonical(event['home']) != event['home'] or canonical(event['away']) != event['away'] or
                event['home'] == event['away'] or event.get('league') != 'NFL' or
                event.get('sport') != 'american_football'):
            raise ValueError('Invalid schedule identity.')
        at(event['startsAt'])
        ids.add(event['id'])
    return schedule


def dataset_context(dataset, event, now):
    """Validate the dated history source before considering any player rows."""
    try:
        research_day = now.astimezone(ZoneInfo('America/New_York')).date()
        game_day = at(event['startsAt']).astimezone(ZoneInfo('America/New_York')).date()
        season = game_day.year - (1 if game_day.month <= 2 else 0)
        cutoff_text = dataset.get('cutoff')
        if not isinstance(cutoff_text, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', cutoff_text):
            return None
        cutoff = date.fromisoformat(cutoff_text)
        retrieved = at(dataset.get('retrievedAt'))
        retrieval_day = retrieved.astimezone(ZoneInfo('America/New_York')).date()
        if (type(dataset.get('currentSeason')) is not int or dataset['currentSeason'] != season or
                retrieved > now or cutoff > min(research_day, retrieval_day) or
                research_day - cutoff > timedelta(days=21)):
            return None
        return cutoff, research_day, game_day, season
    except (ValueError, TypeError, AttributeError):
        return None


def player_directory(dataset, event, now):
    """Latest known club BEFORE both research and game day; exact names only.

    Ambiguous names, same-date conflicting teams/names, old-season players and
    players without a stable nflverse id are absent rather than guessed.
    """
    context = dataset_context(dataset, event, now)
    if context is None:
        return {}
    source_cutoff, research_day, game_day, season = context
    observation_before = min(research_day, game_day)
    latest = {}
    for row in dataset.get('rows', []):
        day, player_id = row.get('date', ''), row.get('playerId', '')
        if not re.fullmatch(r'00-\d{7}', player_id) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', day):
            continue
        try:
            row_day = date.fromisoformat(day)
        except ValueError:
            continue
        if row_day >= observation_before or row_day > source_cutoff:
            continue
        prior = latest.get(player_id, [])
        if not prior or day > prior[0]['date']:
            latest[player_id] = [row]
        elif day == prior[0]['date']:
            prior.append(row)
    names = {}
    for player_id, rows in latest.items():
        identities = {(r.get('name'), canonical(r.get('team'))) for r in rows}
        if (len(identities) != 1 or rows[0].get('season') != season or
                research_day - date.fromisoformat(rows[0]['date']) > timedelta(days=35)):
            continue
        name, team = next(iter(identities))
        if (not isinstance(name, str) or name != name.strip() or not name or len(name) > 100
                or re.search(r'[<>@?\r\n]', name)):
            continue
        # Include all latest names first so a same-name player on another club
        # also makes this identity ambiguous.
        names.setdefault(name, []).append(dict(playerId=player_id, name=name, team=team, asOf=rows[0]['date']))
    return {name: identities[0] for name, identities in names.items()
            if len(identities) == 1 and identities[0]['team'] in (event['away'], event['home'])}


def match_event(upstream, schedule_events, now):
    pairs = []
    used_ids = set()
    for source in upstream:
        if not isinstance(source, dict) or source.get('sport_key') != 'americanfootball_nfl':
            continue
        provider_id = source.get('id', '')
        if not re.fullmatch(r'[a-f0-9]{32}', provider_id) or provider_id in used_ids:
            raise ValueError('Ambiguous provider event identity.')
        used_ids.add(provider_id)
        kick = at(source.get('commence_time'))
        if kick <= now:
            continue
        matches = [event for event in schedule_events
                   if at(event['startsAt']) > now and canonical(source.get('away_team')) == event['away']
                   and canonical(source.get('home_team')) == event['home']
                   and abs(kick - at(event['startsAt'])) <= timedelta(minutes=5)]
        if len(matches) > 1:
            raise ValueError('Ambiguous schedule match.')
        if matches:
            pairs.append((matches[0], source))
    schedule_ids = [pair[0]['id'] for pair in pairs]
    if len(schedule_ids) != len(set(schedule_ids)):
        raise ValueError('Multiple provider events match one scheduled game.')
    return min(pairs, key=lambda pair: (pair[0]['startsAt'], pair[0]['id'])) if pairs else None


def normalize_quotes(raw, event, provider_event, directory, now):
    # Repeat the event match against the actual odds response, not just the free
    # index. A crossed cache/response must never attach prices to another game.
    if (raw.get('id') != provider_event['id'] or raw.get('sport_key') != 'americanfootball_nfl' or
            canonical(raw.get('home_team')) != event['home'] or canonical(raw.get('away_team')) != event['away'] or
            abs(at(raw.get('commence_time')) - at(event['startsAt'])) > timedelta(minutes=5)):
        raise ValueError('Odds response disagrees with the scheduled event.')
    quotes, identities, seen = [], {}, set()
    if not isinstance(raw.get('bookmakers'), list):
        raise ValueError('No bookmaker observations.')
    for book in raw['bookmakers']:
        if not isinstance(book, dict) or book.get('key') not in BOOKS:
            continue
        book_id = book['key']
        for market in book.get('markets', []):
            if not isinstance(market, dict) or market.get('key') not in MARKETS:
                continue
            source = at(market.get('last_update'))
            if source > now + timedelta(seconds=5) or now - source > TTL:
                continue
            for outcome in market.get('outcomes', []):
                if not isinstance(outcome, dict):
                    continue
                name, side, point, price = [outcome.get(k) for k in ('description', 'name', 'point', 'price')]
                if (name not in directory or side not in ('Over', 'Under') or
                        isinstance(point, bool) or not isinstance(point, (int, float)) or
                        not math.isfinite(point) or not 0 <= point <= 1000 or point * 2 != int(point * 2) or
                        isinstance(price, bool) or not isinstance(price, (int, float)) or
                        not math.isfinite(price) or not 1 < price <= 1001):
                    continue
                key = (book_id, market['key'], name, side, point)
                if key in seen:
                    # Conflicting or duplicated observations fail closed.
                    raise ValueError('Duplicate exact quote identity.')
                seen.add(key)
                identities[name] = directory[name]
                quotes.append(dict(selection=dict(eventId=event['id'], market=market['key'], outcome=side,
                    participant=name, point=float(point), period='full_game', rules='player_prop_unverified'),
                    bookId=book_id, book=BOOKS[book_id], provider=PROVIDER, decimal=float(price),
                    sourceAt=iso(source), collectedAt=iso(now), status='open', demo=False))
    quotes.sort(key=lambda q: (q['selection']['participant'], q['selection']['market'], q['selection']['point'], q['selection']['outcome'], q['bookId']))
    if len(quotes) > 2000:
        raise ValueError('Unexpected pilot observation count.')
    return quotes, [identities[name] for name in sorted(identities)]


def publish_observations(schedule, event, quotes, players, fetched_at, now, fixture=False):
    # Construct a public allowlist instead of copying arbitrary input fields.
    events = [{key: e[key] for key in ('id', 'away', 'home', 'startsAt', 'sport', 'league')}
              for e in schedule['board']['events']]
    result = dict(schemaVersion=2, generatedAt=iso(now),
        schedule=dict(source='nflverse', sourceUrl=SOURCE, license='CC BY 4.0',
            licenseUrl='https://creativecommons.org/licenses/by/4.0/',
            fetchedAt=schedule['schedule']['fetchedAt'], windowDays=14),
        board=dict(events=events, quotes=[], fetchedAt=schedule['schedule']['fetchedAt'],
            demo=False, notices=['Actual NFL schedule from nflverse.']))
    result['odds'] = dict(status='limited', provider=PROVIDER, fetchedAt=iso(fetched_at),
        coverage=dict(eventId=event['id'], markets=list(MARKETS), players=players, outsideCoverage='unavailable'))
    if fixture:
        # The app explicitly rejects this marker: offline test prices cannot be
        # accidentally deployed as real observations.
        result['odds']['testFixture'] = True
    result['props'] = dict(events=copy.deepcopy(events), quotes=quotes,
        fetchedAt=iso(fetched_at), demo=False,
        notices=['Limited NFL price snapshot from The Odds API. Other games and markets have no prices.'])
    return result


class Provider:
    def __init__(self, key, fixture_dir=None):
        self.key, self.fixture_dir = key, fixture_dir

    def request(self, event_id=None):
        if self.fixture_dir:
            name = 'odds.json' if event_id else 'events.json'
            raw = json.loads((self.fixture_dir / name).read_text(encoding='utf-8'))
            headers = json.loads((self.fixture_dir / 'headers.json').read_text(encoding='utf-8'))
            return raw, headers.get('odds' if event_id else 'events', {})
        path = '/v4/sports/americanfootball_nfl/events'
        params = {'dateFormat': 'iso'}
        if event_id:
            if not re.fullmatch(r'[a-f0-9]{32}', event_id):
                raise ValueError('Invalid provider event id.')
            path += '/' + event_id + '/odds'
            params.update(bookmakers=','.join(BOOKS), markets=','.join(MARKETS), oddsFormat='decimal')
        url = 'https://api.the-odds-api.com' + path + '?' + urllib.parse.urlencode(params)
        request = urllib.request.Request(url, headers={'x-api-key': self.key, 'User-Agent': 'OddsEdge publication pilot'})
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                raise ValueError('Provider redirects are not accepted.')
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
                body = response.read(2_000_001)
                if len(body) > 2_000_000:
                    raise ValueError('Unexpected provider response size.')
                return json.loads(body), {k.lower(): v for k, v in response.headers.items()}
        except Exception:
            # urllib errors may include URLs/bodies. Never include upstream text.
            raise ValueError('Provider request unavailable.') from None


def credits(headers, key):
    value = str(headers.get(key, ''))
    if not re.fullmatch(r'\d+', value):
        raise ValueError('Provider credit accounting is unavailable.')
    return int(value)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    temporary.replace(path)


def cached_quotes(cache, directory, fetched):
    """Validate normalized private cache again; never trust a raw cached body."""
    if not cache.get('quotes') or len(cache['quotes']) > 2000:
        raise ValueError('Invalid saved observations.')
    allowed = {'selection', 'bookId', 'book', 'provider', 'decimal', 'sourceAt', 'collectedAt', 'status', 'demo'}
    selection_keys = {'eventId', 'market', 'outcome', 'participant', 'point', 'period', 'rules'}
    seen, names = set(), set()
    for q in cache['quotes']:
        s = q['selection']
        point, price = s['point'], q['decimal']
        if (set(q) != allowed or set(s) != selection_keys or s['eventId'] != cache['event']['id'] or
                s['market'] not in MARKETS or s['outcome'] not in ('Over', 'Under') or
                s['participant'] not in directory or s['period'] != 'full_game' or s['rules'] != 'player_prop_unverified' or
                q['bookId'] not in BOOKS or q['book'] != BOOKS[q['bookId']] or q['provider'] != PROVIDER or
                q['demo'] is not False or q['status'] != 'open' or at(q['collectedAt']) != fetched or
                at(q['sourceAt']) > fetched + timedelta(seconds=5) or fetched - at(q['sourceAt']) > TTL or
                isinstance(point, bool) or not isinstance(point, (int, float)) or not math.isfinite(point) or
                not 0 <= point <= 1000 or point * 2 != int(point * 2) or
                isinstance(price, bool) or not isinstance(price, (int, float)) or not math.isfinite(price) or not 1 < price <= 1001):
            raise ValueError('Invalid saved exact quote identity.')
        identity = (q['bookId'], json.dumps(s, sort_keys=True))
        if identity in seen:
            raise ValueError('Duplicate saved quote identity.')
        seen.add(identity)
        names.add(s['participant'])
    if names != {p['name'] for p in cache['players']} or len(names) != len(cache['players']):
        raise ValueError('Invalid saved player coverage.')
    return cache['quotes']


def run(schedule, dataset, now, *, enabled=False, key='', state_dir=None, fixture_dir=None,
        provider=None, initialize_state=False, refresh_window=None):
    validate_schedule(schedule, now)
    if not enabled or (not key and fixture_dir is None):
        return copy.deepcopy(schedule), 'Schedule only; price pilot disabled or no server key; zero odds credits.'
    upcoming = [event for event in schedule['board']['events'] if at(event['startsAt']) > now]
    if upcoming and not any(dataset_context(dataset, event, now) for event in upcoming):
        return copy.deepcopy(schedule), 'Schedule only; bundled player identity provenance is unavailable.'
    if state_dir is None:
        raise ValueError('A private persistent state directory is required.')
    state_dir = Path(state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    lock = state_dir / 'publication.lock'
    try:
        descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        return copy.deepcopy(schedule), 'Schedule only; another pilot publication is running.'
    os.close(descriptor)
    try:
        ledger_path, cache_path = state_dir / 'ledger.json', state_dir / 'quotes.json'
        if not ledger_path.exists():
            if not initialize_state:
                return copy.deepcopy(schedule), 'Schedule only; private pilot credit ledger unavailable.'
            write_json(ledger_path, {'version': 1, 'fixture': fixture_dir is not None, 'reservations': [], 'providerUsed': 0})
        ledger = json.loads(ledger_path.read_text(encoding='utf-8'))
        if (set(ledger) != {'version', 'fixture', 'reservations', 'providerUsed'} or ledger.get('version') != 1
                or type(ledger.get('providerUsed')) is not int or ledger['providerUsed'] < 0
                or ledger.get('fixture') is not (fixture_dir is not None)
                or not isinstance(ledger.get('reservations'), list)):
            raise ValueError('Private credit ledger is invalid.')
        for entry in ledger['reservations']:
            if (set(entry) != {'at', 'credits'} or type(entry.get('credits')) is not int
                    or entry['credits'] != COST or at(entry['at']) > now + timedelta(seconds=5)):
                raise ValueError('Private credit ledger is invalid.')
            at(entry['at'])
        if cache_path.exists():
            cache = json.loads(cache_path.read_text(encoding='utf-8'))
            fetched = at(cache['fetchedAt'])
            events = [e for e in schedule['board']['events'] if e['id'] == cache['event']['id'] and e == cache['event'] and at(e['startsAt']) > now]
            if (events and timedelta(0) <= now - fetched < TTL and
                    all(now - at(q['sourceAt']) <= TTL for q in cache['quotes'])):
                # Revalidate cached raw-independent identities against current
                # bundled history and current event before reusing observations.
                directory = player_directory(dataset, events[0], now)
                if all(directory.get(p['name']) == p for p in cache['players']):
                    quotes = cached_quotes(cache, directory, fetched)
                    return publish_observations(schedule, events[0], quotes, cache['players'], fetched, now, fixture_dir is not None), 'Reused saved price observations; zero odds credits.'
        spent_day = sum(e['credits'] for e in ledger['reservations'] if at(e['at']).date() == now.date())
        spent_month = sum(e['credits'] for e in ledger['reservations'] if at(e['at']).strftime('%Y-%m') == now.strftime('%Y-%m'))
        if spent_day + COST > DAILY_CAP or spent_month + COST > MONTHLY_CAP:
            return copy.deepcopy(schedule), 'Schedule only; pilot credit cap reached.'
        if not any(at(e['startsAt']) > now for e in schedule['board']['events']):
            return copy.deepcopy(schedule), 'Schedule only; no upcoming pilot game.'
        if refresh_window is not None and min(at(e['startsAt']) for e in upcoming) - now > refresh_window:
            return copy.deepcopy(schedule), 'Schedule only; next game is outside the pregame refresh window; zero odds credits.'
        source = provider or Provider(key, fixture_dir)
        upstream, headers = source.request()
        if not isinstance(upstream, list) or credits(headers, 'x-requests-last') != 0:
            raise ValueError('Free event index or credit accounting is invalid.')
        provider_used = credits(headers, 'x-requests-used')
        if provider_used != ledger['providerUsed']:
            return copy.deepcopy(schedule), 'Schedule only; provider usage differs from quota checkpoint; manual reconciliation required.'
        if credits(headers, 'x-requests-remaining') < RESERVE + COST:
            return copy.deepcopy(schedule), 'Schedule only; protected provider credit reserve.'
        pair = match_event(upstream, schedule['board']['events'], now)
        if not pair:
            return copy.deepcopy(schedule), 'Schedule only; no exact upcoming provider match.'
        event, provider_event = pair
        directory = player_directory(dataset, event, now)
        if not directory:
            return copy.deepcopy(schedule), 'Schedule only; no unambiguous bundled player identities.'
        # Reserve the maximum before the paid call, even if it times out or its
        # response is invalid. Never retry a possibly charged request.
        ledger['reservations'].append({'at': iso(now), 'credits': COST})
        ledger['providerUsed'] = provider_used + COST
        write_json(ledger_path, ledger)
        raw, headers = source.request(provider_event['id'])
        observed_used = credits(headers, 'x-requests-used')
        if observed_used != provider_used + credits(headers, 'x-requests-last'):
            ledger['blocked'] = True
            write_json(ledger_path, ledger)
            raise ValueError('Provider usage accounting changed unexpectedly.')
        if credits(headers, 'x-requests-last') > COST or credits(headers, 'x-requests-remaining') < RESERVE:
            # Unexpected billing must require manual investigation, rather than
            # silently resuming with an understated ledger on a later day.
            ledger['blocked'] = True
            write_json(ledger_path, ledger)
            raise ValueError('Provider credit accounting exceeded the pilot budget.')
        ledger['providerUsed'] = observed_used
        write_json(ledger_path, ledger)
        quotes, players = normalize_quotes(raw, event, provider_event, directory, now)
        if not quotes:
            return copy.deepcopy(schedule), 'Schedule only; no validated exact price observations.'
        write_json(cache_path, dict(event=event, quotes=quotes, players=players, fetchedAt=iso(now)))
        return publish_observations(schedule, event, quotes, players, now, now, fixture_dir is not None), 'Published limited NFL price observations; at most four odds credits.'
    finally:
        lock.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--schedule', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--state-dir', type=Path, default=ROOT / '.tools' / 'odds-publish-state')
    parser.add_argument('--fixture-dir', type=Path)
    parser.add_argument('--initialize-state', action='store_true',
                        help='Explicit one-time approved creation of the private credit ledger. Never enable routinely.')
    args = parser.parse_args()
    schedule = json.loads(args.schedule.read_text(encoding='utf-8'))
    now = datetime.now(timezone.utc)
    # Private normalized cache/ledger must never be inside the published folder.
    if args.state_dir.resolve().is_relative_to(args.output.parent.resolve()):
        raise ValueError('Private state must be outside the published output folder.')
    enabled = os.environ.get('ODDS_PUBLISH_ENABLED') == '1'
    key = os.environ.get('THE_ODDS_API_KEY', '').strip()
    dataset = json.loads((ROOT / 'assets/nfl-player-stats.json').read_text(encoding='utf-8')) if enabled and (key or args.fixture_dir) else {}
    try:
        result, message = run(schedule, dataset, now, enabled=enabled, key=key,
                              state_dir=args.state_dir, fixture_dir=args.fixture_dir,
                              initialize_state=args.initialize_state, refresh_window=timedelta(hours=6))
    except (ValueError, KeyError, TypeError, OSError, json.JSONDecodeError):
        # Provider/network/cache failure should retain a valid current schedule.
        validate_schedule(schedule, now)
        result, message = schedule, 'Schedule only; price publication unavailable; no retries.'
    write_json(args.output, result)
    print(message)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Price publication failed safely; preserve the previous deployment.', file=sys.stderr)
        raise SystemExit(1)
