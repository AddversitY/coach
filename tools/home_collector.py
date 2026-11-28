"""DraftKings and BetMGM player-prop prices from a Pennsylvania home connection.

DraftKings and BetMGM answer logged-out prop feeds from a PA residential
connection and block GitHub, Cloudflare and other servers (see
docs/HOME_COLLECTOR.md). The script can run on any machine whose traffic
comes out of that connection.

Logged out, no account, no paid service. BetMGM uses only the anonymous
cookies its own page sets. The script asks the books while a game is inside
one of the six pre-kickoff windows the Worker uses, and each window once per
game. Prices go to the Worker's /v1/book-prices store. A missing price stays
missing.

Standard library only, so it runs from a single downloaded file.

    python home_collector.py            # collect if a window is open
    python home_collector.py --dry-run  # collect and print, push nothing

The ingest secret is read from the BOOK_PROPS_INGEST_SECRET environment
variable. It is never written to disk or printed.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

WORKER = 'https://coach-research.dds-dge.workers.dev'
INDEX_URL = 'https://addversity.github.io/coach/data/coach-index.json'
DK_BASE = 'https://sportsbook-nash.draftkings.com/api/sportscontent/dkuspa/v1/leagues/88808'
# category/subcategory ids read off DraftKings' own league feed, Nov 22, 2026.
DK_SUBCATEGORIES = (
    (1000, 9524),   # Pass Yards O/U
    (1000, 9525),   # Pass TDs O/U
    (1000, 9517),   # Pass Attempts O/U
    (1342, 14114),  # Receiving Yards O/U
    (1342, 14115),  # Receptions O/U
    (1001, 9514),   # Rush Yards O/U
    (1003, 12438),  # TD Scorer (anytime TD is one market in it)
)
DK_MARKETS = {
    'Passing Yards O/U': 'player_pass_yds',
    'Passing Touchdowns O/U': 'player_pass_tds',
    'Passing TDs O/U': 'player_pass_tds',
    'Pass Attempts O/U': 'player_pass_attempts',
    'Passing Attempts O/U': 'player_pass_attempts',
    'Pass Completions O/U': 'player_pass_completions',
    'Passing Completions O/U': 'player_pass_completions',
    'Receiving Yards O/U': 'player_reception_yds',
    'Receptions O/U': 'player_receptions',
    'Rushing Yards O/U': 'player_rush_yds',
    'Anytime Touchdown Scorer': 'player_anytime_td',
}
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36'
EVEN = 1.909091
PAUSE_SECONDS = 3
STORE_CAP = 5000
# Same windows as hosting/book-collect.mjs: (name, minutes before kickoff, early, late).
SLOTS = (
    ('T-24h', 24 * 60, 20, 30), ('T-6h', 6 * 60, 20, 25), ('T-3h', 3 * 60, 20, 25),
    ('T-90m', 90, 15, 20), ('T-30m', 30, 10, 12), ('last', 10, 7, 9),
)
NICK = {
    'cardinals': 'ARI', 'falcons': 'ATL', 'ravens': 'BAL', 'bills': 'BUF', 'panthers': 'CAR',
    'bears': 'CHI', 'bengals': 'CIN', 'browns': 'CLE', 'cowboys': 'DAL', 'broncos': 'DEN',
    'lions': 'DET', 'packers': 'GB', 'texans': 'HOU', 'colts': 'IND', 'jaguars': 'JAX',
    'chiefs': 'KC', 'raiders': 'LV', 'chargers': 'LAC', 'rams': 'LAR', 'dolphins': 'MIA',
    'vikings': 'MIN', 'patriots': 'NE', 'saints': 'NO', 'giants': 'NYG', 'jets': 'NYJ',
    'eagles': 'PHI', 'steelers': 'PIT', '49ers': 'SF', 'seahawks': 'SEA', 'buccaneers': 'TB',
    'titans': 'TEN', 'commanders': 'WAS',
}
SHORT = {'LA': 'LAR', 'JAC': 'JAX', 'WSH': 'WAS', 'LVR': 'LV'}


def parse_time(value):
    text = str(value or '').strip()
    if not text:
        return None
    text = re.sub(r'(\.\d{6})\d+', r'\1', text).replace('Z', '+00:00')
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def iso(moment):
    return moment.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def team_code(participant):
    short = str(((participant or {}).get('metadata') or {}).get('shortName') or '').upper()
    if re.fullmatch(r'[A-Z]{2,3}', short):
        return SHORT.get(short, short)
    words = str((participant or {}).get('name') or '').lower().split()
    return NICK.get(re.sub(r'[^a-z0-9]', '', words[-1])) if words else None


def normalize_person(name):
    text = re.sub(r'\([^)]*\)', ' ', str(name or '').lower()).replace('.', ' ')
    text = re.sub(r"[^a-z\s'-]", ' ', text)
    text = re.sub(r'\b(jr|sr|ii|iii|iv|v)\b', ' ', text)
    collapsed = []
    for part in text.split():
        if collapsed and len(collapsed[-1]) == 1 and len(part) == 1:
            collapsed[-1] += part
        else:
            collapsed.append(part)
    return ' '.join(collapsed)


def decimal_price(selection):
    true = selection.get('trueOdds')
    if isinstance(true, (int, float)) and true > 1:
        return round(float(true), 6)
    shown = (selection.get('displayOdds') or {}).get('decimal')
    try:
        value = float(str(shown))
    except (TypeError, ValueError):
        value = None
    if value and value > 1:
        return round(value, 6)
    american = str((selection.get('displayOdds') or {}).get('american') or '').replace('−', '-').replace('+', '')
    try:
        odds = int(american)
    except ValueError:
        return None
    if odds >= 100:
        return round(1 + odds / 100, 6)
    if odds <= -100:
        return round(1 + 100 / -odds, 6)
    return None


def parse_draftkings(payload, now):
    """Flat DraftKings feed -> rows in the coach-book-prices-v1 shape."""
    payload = payload or {}
    events = {str(e.get('id')): e for e in payload.get('events') or [] if isinstance(e, dict)}
    markets = {str(m.get('id')): m for m in payload.get('markets') or [] if isinstance(m, dict)}
    rows = []
    for selection in payload.get('selections') or []:
        if not isinstance(selection, dict):
            continue
        market = markets.get(str(selection.get('marketId')))
        if not market:
            continue
        kind = DK_MARKETS.get(str((market.get('marketType') or {}).get('name') or ''))
        event = events.get(str(market.get('eventId')))
        if not kind or not event or str(event.get('status') or 'NOT_STARTED') != 'NOT_STARTED':
            continue
        people = selection.get('participants') or []
        player = str((people[0] if people else {}).get('name') or '').strip()
        if not player or ' or ' in player.lower() or '/' in player:
            continue
        if kind == 'player_anytime_td':
            if str(selection.get('outcomeType') or '') != 'Anytime Scorer':
                continue
            outcome, line = 'Yes', 0.5
        else:
            outcome = str(selection.get('outcomeType') or selection.get('label') or '')
            line = selection.get('points')
            if outcome not in ('Over', 'Under') or not isinstance(line, (int, float)):
                continue
            line = float(line)
        price = decimal_price(selection)
        if not price or price > 100:
            continue
        sides = {p.get('venueRole'): p for p in event.get('participants') or []}
        rows.append({
            'at': iso(now), 'book': 'draftkings', 'eventId': str(event.get('id')),
            'kickoff': iso(parse_time(event.get('startEventDate'))) if parse_time(event.get('startEventDate')) else None,
            'away': team_code(sides.get('Away')), 'home': team_code(sides.get('Home')),
            'market': kind, 'outcome': outcome, 'player': player, 'line': line, 'decimal': price,
        })
    return select_main_lines(rows)


def select_main_lines(rows):
    """One line per player: the posted over/under whose over is closest to even."""
    singles, groups = [], {}
    for row in rows:
        if row['market'] == 'player_anytime_td':
            singles.append(row)
            continue
        groups.setdefault((row['book'], row['eventId'], row['market'], row['player'], row['line']), []).append(row)
    chosen = {}
    for key, sides in groups.items():
        over = next((r for r in sides if r['outcome'] == 'Over'), None)
        if not over or not any(r['outcome'] == 'Under' for r in sides):
            continue
        score = (abs(over['decimal'] - EVEN), key[4])
        if key[:4] not in chosen or score < chosen[key[:4]][0]:
            chosen[key[:4]] = (score, sides)
    seen, kept = set(), []
    for row in singles + [r for _, sides in chosen.values() for r in sides]:
        ident = (row['eventId'], row['market'], row['player'], row['outcome'])
        if ident not in seen:
            seen.add(ident)
            kept.append(row)
    return kept


def attach_identity(rows, index):
    """Schedule id and GSIS player id from Coach's published index, as the Worker does."""
    roster = {}
    for player in index.get('players') or []:
        if re.fullmatch(r'00-\d{7}', str(player.get('id') or '')) and player.get('name'):
            roster.setdefault(normalize_person(player['name']), []).append(player)
    out = []
    for row in rows:
        start = parse_time(row.get('kickoff'))
        game, gap = None, None
        for event in index.get('events') or []:
            if event.get('awayCode') != row.get('away') or event.get('homeCode') != row.get('home'):
                continue
            when = parse_time(event.get('startsAt'))
            if start and when and (gap is None or abs(when - start) < gap):
                game, gap = event, abs(when - start)
        if not game or gap.total_seconds() > 36 * 3600:
            continue
        item = {k: v for k, v in row.items() if k not in ('away', 'home')}
        item['eventId'] = game['id']
        hits = roster.get(normalize_person(row['player'])) or []
        if len(hits) > 1:
            hits = [h for h in hits if str(h.get('team') or '').upper() in (row.get('away'), row.get('home'))]
        if len(hits) == 1:
            item['player'], item['playerId'] = hits[0]['name'], hits[0]['id']
        out.append(item)
    return out


def due_slots(minutes_left, done):
    """Same rule as slotsToCapture in hosting/book-collect.mjs."""
    if not minutes_left > 0:
        return []
    due = []
    for i, (name, target, early, late) in enumerate(SLOTS):
        if name in done:
            continue
        on_time = target - late <= minutes_left <= target + early
        next_early = SLOTS[i + 1][1] + SLOTS[i + 1][2] if i + 1 < len(SLOTS) else 0
        missed = next_early < minutes_left < target - late
        if on_time or missed:
            due.append(name)
    return due


def due_games(index, state, now):
    """Games with an open window that this computer has not captured yet."""
    due = {}
    for event in index.get('events') or []:
        start = parse_time(event.get('startsAt'))
        if not start or start <= now:
            continue
        slots = due_slots((start - now).total_seconds() / 60, set((state.get('done') or {}).get(event['id'], [])))
        if slots:
            due[event['id']] = slots
    return due


def merge_store(stored, rows, now):
    """Keep the cron's prices; replace only the same book/game/market/player/side."""
    cutoff = now.timestamp() - 36 * 3600
    merged = {}
    for item in (stored or {}).get('observations') or []:
        kick = parse_time(item.get('kickoff'))
        if kick and kick.timestamp() < cutoff:
            continue
        merged[(item.get('book'), item.get('eventId'), item.get('market'), item.get('player'), item.get('outcome'))] = item
    for item in rows:
        merged[(item['book'], item['eventId'], item['market'], item['player'], item['outcome'])] = item
    observations = sorted(merged.values(), key=lambda r: str(r.get('at') or ''), reverse=True)[:STORE_CAP]
    return {'schema': 'coach-book-prices-v1', 'observations': observations}


def http_json(url, data=None, headers=None, timeout=25):
    request = urllib.request.Request(url, data=data, headers={'User-Agent': UA, 'Accept': 'application/json', 'Accept-Language': 'en-US,en;q=0.9', **(headers or {})}, method='POST' if data else 'GET')
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as error:
        return error.code, None
    except (urllib.error.URLError, TimeoutError, ValueError):
        return 0, None


def collect_draftkings(fetch, pause, now):
    rows, statuses = [], []
    for number, (category, sub) in enumerate(DK_SUBCATEGORIES):
        if number:
            pause(PAUSE_SECONDS)
        status, body = fetch(f'{DK_BASE}/categories/{category}/subcategories/{sub}')
        statuses.append(status)
        if status == 200 and body:
            rows.extend(parse_draftkings(body, now))
    unique = {(r['eventId'], r['market'], r['player'], r['outcome']): r for r in rows}
    return list(unique.values()), statuses


# ---- BetMGM (logged out) ----------------------------------------------------
BM_HOME = 'https://www.pa.betmgm.com'
BM_PAGE = BM_HOME + '/en/sports/football-11/betting/usa-9/nfl-35'
BM_HAPPENING = {
    'PassingYards': 'player_pass_yds', 'ReceivingYards': 'player_reception_yds',
    'Reception': 'player_receptions', 'RushingYards': 'player_rush_yds',
    'PassAttempt': 'player_pass_attempts', 'TouchdownPass': 'player_pass_tds',
    'PassCompleted': 'player_pass_completions',
}


def _bm_params(market):
    return {p.get('key'): p.get('value') for p in market.get('parameters') or []}


def parse_betmgm(payload, now):
    """BetMGM cds-api fixtures -> rows in the coach-book-prices-v1 shape (main lines only)."""
    rows = []
    for fixture in (payload or {}).get('fixtures') or []:
        name = str((fixture.get('name') or {}).get('value') or '')
        if ' @ ' not in name or str(fixture.get('stage') or 'PreMatch') != 'PreMatch':
            continue
        away_name, home_name = name.split(' @ ', 1)
        away, home = team_code({'name': away_name}), team_code({'name': home_name})
        kickoff = parse_time(fixture.get('startDate'))
        people = {str(p.get('id')): str((p.get('name') or {}).get('value') or '').strip() for p in fixture.get('participants') or []}
        for market in fixture.get('optionMarkets') or []:
            params = _bm_params(market)
            if market.get('status') not in (None, 'Visible') or params.get('Period') != 'FullTime':
                continue
            player = people.get(str(params.get('FixtureParticipant')), '')
            if not player or params.get('Happening') in (None, 'Point'):
                continue
            options = market.get('options') or []
            if params.get('Happening') == 'Touchdown' and params.get('MarketSubType') == 'PlayerTD':
                if str(params.get('DecimalValue')) not in ('0.5',) or len(options) != 1:
                    continue
                price = (options[0].get('price') or {}).get('odds')
                if isinstance(price, (int, float)) and 1 < price <= 100:
                    rows.append({'at': iso(now), 'book': 'betmgm', 'eventId': fixture.get('id'), 'kickoff': iso(kickoff) if kickoff else None,
                                 'away': away, 'home': home, 'market': 'player_anytime_td', 'outcome': 'Yes', 'player': player, 'line': 0.5, 'decimal': round(float(price), 6)})
                continue
            kind = BM_HAPPENING.get(params.get('Happening'))
            if not kind or params.get('MarketSubType') == 'YesNo' or len(options) != 2:
                continue
            if kind == 'player_reception_yds' and 'Reception Yards' not in str((market.get('name') or {}).get('value')):
                continue
            for option in options:
                side = (option.get('parameters') or {}).get('optionTypes') or []
                outcome = side[0] if side and side[0] in ('Over', 'Under') else ''
                price = (option.get('price') or {}).get('odds')
                try:
                    line = float(params.get('DecimalValue'))
                except (TypeError, ValueError):
                    line = None
                if outcome and line is not None and isinstance(price, (int, float)) and 1 < price <= 100:
                    rows.append({'at': iso(now), 'book': 'betmgm', 'eventId': fixture.get('id'), 'kickoff': iso(kickoff) if kickoff else None,
                                 'away': away, 'home': home, 'market': kind, 'outcome': outcome, 'player': player, 'line': line, 'decimal': round(float(price), 6)})
    return select_main_lines(rows)


def collect_betmgm(now):
    """Logged out: a plain browser-like session (anonymous cookies only) plus the public access id."""
    import http.cookiejar
    import urllib.parse
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    base = {'User-Agent': UA, 'Accept-Language': 'en-US,en;q=0.9'}

    def get(url, headers=None):
        request = urllib.request.Request(url, headers={**base, **(headers or {})})
        try:
            with opener.open(request, timeout=30) as response:
                return response.status, response.read().decode('utf-8', 'replace')
        except urllib.error.HTTPError as error:
            return error.code, ''
        except (urllib.error.URLError, TimeoutError):
            return 0, ''

    status, _ = get(BM_PAGE, {'Accept': 'text/html'})
    if status != 200:
        return [], [status]
    browser_url = urllib.parse.quote(BM_HOME + '/api/clientconfig', safe='')
    status, text = get(BM_HOME + '/en/api/clientconfig?browserUrl=' + browser_url,
                       {'x-bwin-browser-url': browser_url, 'x-from-product': 'host-app', 'x-bwin-sports-api': 'prod', 'x-bwin-sf-api': 'prod'})
    found = re.search(r'"publicAccessId":"([^"]+)"', text or '')
    if status != 200 or not found:
        return [], [status]
    query = urllib.parse.urlencode({
        'x-bwin-accessid': found.group(1), 'lang': 'en-us', 'country': 'US', 'userCountry': 'US', 'subdivision': 'US-Pennsylvania',
        'offerMapping': 'All', 'scoreboardMode': 'Full', 'fixtureTypes': 'Standard', 'state': 'Latest',
        'sportIds': 11, 'regionIds': 9, 'competitionIds': 35, 'skip': 0, 'take': 50})
    status, text = get(BM_HOME + '/cds-api/bettingoffer/fixtures?' + query, {
        'Accept': 'application/json, text/plain, */*', 'Referer': BM_PAGE, 'Origin': BM_HOME,
        'x-bwin-browser-url': BM_PAGE, 'sec-fetch-site': 'same-origin', 'sec-fetch-mode': 'cors'})
    try:
        body = json.loads(text) if status == 200 else None
    except ValueError:
        body = None
    return (parse_betmgm(body, now) if body else []), [status]


def run(args, fetch=http_json, pause=time.sleep, now=None):
    now = now or datetime.now(timezone.utc)
    folder = Path(args.folder)
    folder.mkdir(parents=True, exist_ok=True)
    state_file = folder / 'collector-state.json'
    try:
        state = json.loads(state_file.read_text())
    except (OSError, ValueError):
        state = {}
    status, index = fetch(INDEX_URL)
    if status != 200 or not index:
        return log(folder, now, f'Coach schedule unavailable (HTTP {status}); nothing collected.')
    due = due_games(index, state, now)
    if not due and not args.force:
        return log(folder, now, 'No pre-kickoff window open.', quiet=True)
    books = [b.strip() for b in str(getattr(args, 'books', 'draftkings')).split(',') if b.strip()]
    rows, parts = [], []
    if 'draftkings' in books:
        dk_rows, statuses = collect_draftkings(fetch, pause, now)
        dk_rows = attach_identity(dk_rows, index)
        rows += dk_rows
        parts.append(f'DraftKings HTTP {sorted(set(statuses))} {len(dk_rows)}')
    if 'betmgm' in books:
        if 'draftkings' in books:
            pause(PAUSE_SECONDS)
        try:
            bm_rows, bm_status = collect_betmgm(now)
        except Exception:  # one book failing must not stop the other
            bm_rows, bm_status = [], ['error']
        bm_rows = attach_identity(bm_rows, index)
        rows += bm_rows
        parts.append(f'BetMGM HTTP {sorted(set(map(str, bm_status)))} {len(bm_rows)}')
    if not args.force:
        rows = [r for r in rows if r['eventId'] in due]
    message = f'{"; ".join(parts)}; {len(rows)} prices for {len({r["eventId"] for r in rows})} games.'
    if args.dry_run:
        print(json.dumps(rows[:10], indent=1))
        return log(folder, now, message + ' Dry run, nothing pushed.')
    secret = os.environ.get('BOOK_PROPS_INGEST_SECRET', '')
    pushed = 'not pushed (BOOK_PROPS_INGEST_SECRET is not set)'
    if rows and secret:
        code, stored = fetch(WORKER + '/v1/book-prices')
        if code == 200 and isinstance(stored, dict):
            # The Worker that is live today replaces the whole store, so the
            # other books stay in this body. Once the Worker's book merge is
            # deployed, a cron row newer than this copy is kept.
            body = json.dumps(merge_store(stored, rows, now)).encode('utf-8')
            code, _ = fetch(WORKER + '/v1/book-prices', body, {'Content-Type': 'application/json', 'Authorization': f'Bearer {secret}'})
            pushed = f'pushed (HTTP {code})' if code == 200 else f'push failed (HTTP {code})'
        else:
            pushed = f'not pushed: could not read the current store (HTTP {code})'
    if pushed.startswith('pushed'):
        done = state.setdefault('done', {})
        for event_id, slots in due.items():
            if any(r['eventId'] == event_id for r in rows):
                done[event_id] = sorted(set(done.get(event_id, [])) | set(slots))
        cutoff = now.timestamp() - 3 * 86400
        state['done'] = {k: v for k, v in done.items() if any(e['id'] == k and (parse_time(e.get('startsAt')) or now).timestamp() > cutoff for e in index.get('events') or [])}
        state_file.write_text(json.dumps(state, indent=1))
    return log(folder, now, f'{message} {pushed}.')


def log(folder, now, message, quiet=False):
    line = f'{iso(now)} {message}'
    if not quiet:
        print(line)
        try:
            with open(Path(folder) / 'collector.log', 'a', encoding='utf-8') as handle:
                handle.write(line + '\n')
        except OSError:
            pass
    return line


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--folder', default=str(Path(__file__).resolve().parent))
    parser.add_argument('--dry-run', action='store_true', help='collect and print, push nothing')
    parser.add_argument('--books', default='draftkings,betmgm', help='comma list: draftkings,betmgm')
    parser.add_argument('--force', action='store_true', help='collect now even if no window is open')
    run(parser.parse_args(argv))
    return 0


if __name__ == '__main__':
    sys.exit(main())
