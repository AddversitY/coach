"""Logged-out NFL player-prop prices from public sportsbook pages.

No account, no paid proxy, and no Odds API credit. A book that does not
answer is unavailable. A price that was not in the response is not stored.

Normalized prices go to a private file (gitignored backend/data/). The
public coverage file keeps counts only. Raw vendor payloads are not stored.
"""

import csv
import io
import json
import re
import time
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import price_history

# The logged-out FanDuel page sends this client id. It is not an account key.
# The page is read first; this is only the fallback when that page is blocked.
FANDUEL_PUBLIC_CLIENT = 'FhMFpcPWXMeyZxOx'
SCHEDULE_URL = 'https://github.com/nflverse/nflverse-data/releases/download/schedules/games.csv'
EASTERN = ZoneInfo('America/New_York')
PROP_MARKETS = tuple(price_history.PROP_MARKETS)
EVEN_DECIMAL = 1.909091
MAX_GAMES = 16
PROBE_HOURS = 20

NICKNAMES = {
    'cardinals': 'ARI', 'falcons': 'ATL', 'ravens': 'BAL', 'bills': 'BUF',
    'panthers': 'CAR', 'bears': 'CHI', 'bengals': 'CIN', 'browns': 'CLE',
    'cowboys': 'DAL', 'broncos': 'DEN', 'lions': 'DET', 'packers': 'GB',
    'texans': 'HOU', 'colts': 'IND', 'jaguars': 'JAX', 'chiefs': 'KC',
    'raiders': 'LV', 'chargers': 'LAC', 'rams': 'LAR', 'dolphins': 'MIA',
    'vikings': 'MIN', 'patriots': 'NE', 'saints': 'NO', 'giants': 'NYG',
    'jets': 'NYJ', 'eagles': 'PHI', 'steelers': 'PIT', '49ers': 'SF',
    'seahawks': 'SEA', 'buccaneers': 'TB', 'titans': 'TEN', 'commanders': 'WAS',
}

KAMBI_MARKETS = {
    'Total Passing Yards by the Player - Including Overtime': 'player_pass_yds',
    'Total Rushing Yards by the Player - Including Overtime': 'player_rush_yds',
    'Total Receiving Yards by the Player - Including Overtime': 'player_reception_yds',
    'Total Receptions by the Player - Including Overtime': 'player_receptions',
    'Total Pass Attempts by the Player - Including Overtime': 'player_pass_attempts',
    'Total Pass Completions by the Player - Including Overtime': 'player_pass_completions',
    'Total Touchdown Passes Thrown by the Player - Including Overtime': 'player_pass_tds',
    'Touchdown Scorer': 'player_anytime_td',
}

BOVADA_MARKETS = (
    ('Total Player Passing Yards O/U', 'player_pass_yds'),
    ('Total Rushing Yards O/U', 'player_rush_yds'),
    ('Total Receiving Yards O/U', 'player_reception_yds'),
    ('Total Receptions O/U', 'player_receptions'),
    ('Total Player Passing Attempts O/U', 'player_pass_attempts'),
    ('Total Passing Completions O/U', 'player_pass_completions'),
    ('Total Passing Touchdowns O/U', 'player_pass_tds'),
)

FANDUEL_TABS = ('passing-props', 'rushing-props', 'receiving-props', 'td-scorer-props')

# One polite request. These hosts did not return a logged-out prop feed.
PROBES = (
    ('draftkings-public', 'https://sportsbook-nash.draftkings.com/api/sportscontent/dkuspa/v1/leagues/88808'),
    ('betmgm-public', 'https://sports.nj.betmgm.com/en/sports/football-11'),
    ('caesars-public', 'https://api.americanwagering.com/regions/us/locations/nj/brands/czr/sb/v3/sports/americanfootball/events/schedule/'),
    ('espnbet-public', 'https://sportsbook-espnbet.us-default.thescore.bet/graphql'),
    ('fanatics-public', 'https://sportsbook.fanatics.com/'),
    ('hardrock-public', 'https://app.hardrock.bet/sportsbook'),
    ('pinnacle-public', 'https://www.pinnacle.com/config/app.json'),
)


def normalize_person(name):
    text = str(name or '').lower()
    text = re.sub(r'\([^)]*\)', ' ', text)
    text = text.replace('.', ' ')
    text = re.sub(r"[^a-z\s'-]", ' ', text)
    text = re.sub(r'\b(jr|sr|ii|iii|iv|v)\b', ' ', text)
    parts = re.sub(r'\s+', ' ', text).strip().split()
    collapsed = []
    for part in parts:
        if collapsed and len(collapsed[-1]) == 1 and len(part) == 1:
            collapsed[-1] += part
        else:
            collapsed.append(part)
    return ' '.join(collapsed)


def team_abbr(label):
    text = str(label or '').strip()
    if not text:
        return None
    if text in price_history.ABBR:
        return text
    found = price_history.TEAMS.get(text)
    if found:
        return found
    nickname = re.sub(r'[^a-z0-9]', '', text.lower().split()[-1])
    return NICKNAMES.get(nickname)


def _iso(value):
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z')
    if isinstance(value, (int, float)) and value > 10_000_000_000:
        return _iso(datetime.fromtimestamp(value / 1000, timezone.utc))
    return price_history._iso(value)


def _now(now=None):
    return now or datetime.now(timezone.utc)


def event_wanted(kickoff, windows, now, hours=26):
    start = price_history._parse_time(kickoff)
    if start is None or start <= now:
        return False
    if windows:
        return any(abs((start - window).total_seconds()) <= 45 * 60 for window in windows)
    return start <= now + timedelta(hours=hours)


def select_main_lines(rows):
    """One posted line per player. The closest-to-even over is the main line.

    Anytime touchdowns stay as posted. No line is created.
    """
    singles = []
    groups = {}
    for row in rows:
        if row.get('market') == 'player_anytime_td':
            singles.append(row)
            continue
        if row.get('line') is None or row.get('outcome') not in ('Over', 'Under'):
            continue
        key = (row['book'], row['eventId'], row['market'], row['player'], row['line'])
        groups.setdefault(key, []).append(row)
    chosen = {}
    for key, sides in groups.items():
        outcomes = {row['outcome'] for row in sides}
        if outcomes != {'Over', 'Under'} and 'Over' not in outcomes:
            continue
        if 'Over' not in outcomes or 'Under' not in outcomes:
            continue
        over = next(row for row in sides if row['outcome'] == 'Over')
        identity = key[:4]
        distance = abs(over['decimal'] - EVEN_DECIMAL)
        current = chosen.get(identity)
        if current is None or (distance, key[4]) < current[0]:
            chosen[identity] = ((distance, key[4]), sides)
    kept = list(singles)
    for _identity, (_score, sides) in chosen.items():
        kept.extend(sides)
    return kept


def build_roster(rows):
    latest = {}
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        player_id = str(row.get('playerId') or '')
        name = str(row.get('name') or '').strip()
        if not re.fullmatch(r'00-\d{7}', player_id) or not name:
            continue
        stamp = (int(row.get('season') or 0), int(row.get('week') or 0), str(row.get('date') or ''))
        previous = latest.get(player_id)
        if previous is not None and stamp <= previous['stamp']:
            continue
        latest[player_id] = {
            'stamp': stamp,
            'playerId': player_id,
            'name': name,
            'norm': normalize_person(name),
            'team': str(row.get('team') or '').upper(),
        }
    by_name = {}
    for item in latest.values():
        by_name.setdefault(item['norm'], []).append(item)
    return by_name


def match_player(name, teams, roster):
    hits = (roster or {}).get(normalize_person(name)) or []
    if len(hits) == 1:
        return hits[0]
    clubs = {team for team in teams if team}
    narrowed = [hit for hit in hits if hit['team'] in clubs]
    if len(narrowed) == 1:
        return narrowed[0]
    return None


def load_schedule_text(text):
    games = []
    for row in csv.DictReader(io.StringIO(text)):
        if row.get('game_type') not in (None, '', 'REG'):
            continue
        away = price_history.ABBR_ALIASES.get(row.get('away_team') or '', row.get('away_team'))
        home = price_history.ABBR_ALIASES.get(row.get('home_team') or '', row.get('home_team'))
        away, home = team_abbr(away), team_abbr(home)
        try:
            season, week = int(row['season']), int(row['week'])
        except (KeyError, TypeError, ValueError):
            continue
        if not away or not home:
            continue
        kickoff = _schedule_kickoff(row.get('gameday'), row.get('gametime'))
        games.append({
            'season': season,
            'week': week,
            'away': away,
            'home': home,
            'kickoff': kickoff,
            'eventId': f'nflverse:{season}_{week}_{away}_{home}',
        })
    return games


def _schedule_kickoff(day, clock):
    if not day:
        return None
    clock = clock or '12:00'
    try:
        local = datetime.strptime(f'{day} {clock}', '%Y-%m-%d %H:%M').replace(tzinfo=EASTERN)
    except ValueError:
        return None
    return _iso(local)


def match_event(away, home, kickoff, schedule):
    start = price_history._parse_time(kickoff)
    candidates = [
        game for game in schedule or []
        if {game['away'], game['home']} == {away, home} and away and home
    ]
    if not candidates or start is None:
        return None
    def distance(game):
        parsed = price_history._parse_time(game.get('kickoff'))
        if parsed is None:
            return timedelta(days=999)
        return abs(parsed - start)
    best = min(candidates, key=distance)
    if distance(best) > timedelta(hours=36):
        return None
    # Keep the book's home/away order only when it matches the schedule.
    if best['away'] != away or best['home'] != home:
        return None
    return best


def attach_identity(rows, roster, schedule):
    attached = []
    for row in rows:
        item = dict(row)
        away, home = team_abbr(item.get('away')), team_abbr(item.get('home'))
        item['away'], item['home'] = away, home
        game = match_event(away, home, item.get('kickoff'), schedule)
        if game:
            item['eventId'] = game['eventId']
            item['season'] = game['season']
            item['week'] = game['week']
            item['kickoff'] = item.get('kickoff') or game['kickoff']
        elif away and home and item.get('kickoff'):
            item['eventId'] = f"unmatched:{away}:{home}:{item['kickoff']}"
        else:
            continue
        player = match_player(item.get('player'), (away, home), roster)
        if player:
            item['player'] = player['name']
            item['playerId'] = player['playerId']
        attached.append(item)
    return attached


def consensus_adoption(scores):
    """Use a no-vig consensus only when it wins both scores in both seasons.

    A missing season stays off. This does not invent a score.
    """
    missing = []
    for year in (2025, 2026):
        row = (scores or {}).get(year)
        if not row or not row.get('games'):
            missing.append(str(year))
    if missing:
        return {
            'adopted': False,
            'reason': 'unavailable',
            'detail': 'Two-sided closes are unavailable for ' + ' and '.join(missing) + '.',
        }
    for year in (2025, 2026):
        row = scores[year]
        try:
            better = (
                float(row['consensusBrier']) < float(row['modelBrier'])
                and float(row['consensusLogLoss']) < float(row['modelLogLoss'])
            )
        except (KeyError, TypeError, ValueError):
            return {'adopted': False, 'reason': 'unavailable', 'detail': f'{year} scores are unavailable.'}
        if not better:
            return {
                'adopted': False,
                'reason': 'did-not-beat',
                'detail': f'The consensus did not beat the current chance on both scores in {year}.',
            }
    return {
        'adopted': True,
        'reason': 'both-seasons',
        'detail': 'The consensus was closer on Brier and log loss in both 2025 and 2026.',
    }


def _checked_recently(history, source, now):
    for row in (history or {}).get('sources') or []:
        if row.get('source') != source:
            continue
        checked = price_history._parse_time(row.get('checkedAt'))
        if checked is None:
            return False
        return now - checked < timedelta(hours=PROBE_HOURS)
    return False


def _row(book, source, event_id, kickoff, away, home, market, outcome, player, line, decimal, now):
    if decimal is None or decimal <= 1 or not outcome or not market:
        return None
    return {
        'at': _iso(now),
        'source': source,
        'book': book,
        'eventId': event_id,
        'kickoff': kickoff,
        'away': away,
        'home': home,
        'market': market,
        'outcome': outcome,
        'player': player or '',
        'line': line,
        'decimal': round(float(decimal), 6),
        'status': 'open',
    }


def _kambi_number(value):
    number = price_history._number(value)
    if number is None:
        return None
    if isinstance(value, int) or (isinstance(value, str) and value.isdigit()):
        return number / 1000
    if number >= 100:
        return number / 1000
    return number


def parse_kambi_event(payload, now=None):
    now = _now(now)
    rows = []
    events = {
        event.get('id'): event
        for event in (payload or {}).get('events') or []
        if isinstance(event, dict)
    }
    for offer in (payload or {}).get('betOffers') or []:
        if not isinstance(offer, dict):
            continue
        market = KAMBI_MARKETS.get((offer.get('criterion') or {}).get('englishLabel') or '')
        event = events.get(offer.get('eventId')) or {}
        if market is None or not event:
            continue
        for outcome in offer.get('outcomes') or []:
            if str(outcome.get('status') or 'OPEN').upper() in ('SUSPENDED', 'CLOSED', 'REMOVED'):
                continue
            label = outcome.get('englishLabel') or outcome.get('label') or ''
            if market == 'player_anytime_td':
                side, player = 'Yes', outcome.get('participant') or label
                line = 0.5
            elif label in ('Over', 'Under'):
                side, player = label, outcome.get('participant') or ''
                line = _kambi_number(outcome.get('line'))
            else:
                continue
            decimal = _kambi_number(outcome.get('odds'))
            if decimal is not None and decimal <= 1:
                decimal = price_history.decimal_from_american(outcome.get('oddsAmerican'))
            row = _row(
                'betrivers', 'betrivers-public', str(event.get('id')),
                event.get('start'), event.get('awayName'), event.get('homeName'),
                market, side, player, line, decimal, now,
            )
            if row and (market == 'player_anytime_td' or row['line'] is not None):
                rows.append(row)
    return select_main_lines(rows)


def parse_bovada(payload, now=None):
    now = _now(now)
    rows = []
    blocks = payload if isinstance(payload, list) else [payload or {}]
    for block in blocks:
        for event in (block or {}).get('events') or []:
            if not isinstance(event, dict) or event.get('type') not in (None, 'GAMEEVENT'):
                continue
            away, home = _split_matchup(event.get('description'))
            kickoff = _iso(event.get('startTime'))
            for group in event.get('displayGroups') or []:
                for market in group.get('markets') or []:
                    kind = _bovada_market(market.get('descriptionKey') or market.get('description') or '')
                    period = (market.get('period') or {}).get('description') or 'Game'
                    if kind is None or period not in ('Game', 'G') or str(market.get('status') or 'O').upper() in ('S', 'SUSPENDED', 'CLOSED'):
                        continue
                    player = _bovada_player(market.get('descriptionKey') or market.get('description') or '')
                    for outcome in market.get('outcomes') or []:
                        if str(outcome.get('status') or 'O').upper() in ('S', 'SUSPENDED', 'CLOSED'):
                            continue
                        side = outcome.get('description') or ''
                        if side not in ('Over', 'Under'):
                            continue
                        price = outcome.get('price') or {}
                        row = _row(
                            'bovada', 'bovada-public', str(event.get('id')),
                            kickoff, away, home, kind, side, player,
                            price_history._number(price.get('handicap')),
                            price_history._number(price.get('decimal')),
                            now,
                        )
                        if row and row['line'] is not None:
                            rows.append(row)
    return select_main_lines(rows)


def _bovada_market(label):
    text = str(label)
    if any(word in text for word in ('Longest', 'Alternate', '&', 'Most ')):
        return None
    for prefix, market in BOVADA_MARKETS:
        if text.startswith(prefix):
            return market
    return None


def _bovada_player(label):
    parts = str(label).split(' - ', 1)
    return parts[1].strip() if len(parts) == 2 else ''


def _split_matchup(name):
    parts = re.split(r'\s+@\s+|\s+v\s+|\s+vs\.?\s+', str(name or ''), maxsplit=1)
    if len(parts) != 2:
        return None, None
    return parts[0].strip(), parts[1].strip()


def parse_fanduel_page(payload, now=None):
    now = _now(now)
    attachments = (payload or {}).get('attachments') or {}
    events = attachments.get('events') or {}
    rows = []
    for market in (attachments.get('markets') or {}).values():
        if not isinstance(market, dict):
            continue
        event = events.get(str(market.get('eventId'))) or {}
        kind, player = _fanduel_market(market.get('marketName') or '')
        if kind is None or not event:
            continue
        away, home = _split_matchup(event.get('name'))
        for runner in market.get('runners') or []:
            if str(runner.get('runnerStatus') or 'ACTIVE').upper() in ('SUSPENDED', 'CLOSED', 'REMOVED'):
                continue
            name = runner.get('runnerName') or ''
            side = 'Over' if name == 'Over' or name.endswith(' Over') else 'Under' if name == 'Under' or name.endswith(' Under') else None
            if kind == 'player_anytime_td' and side is None:
                if not _one_player(name):
                    continue
                side, who, line = 'Yes', name, 0.5
            elif side:
                who, line = player, price_history._number(runner.get('handicap'))
            else:
                continue
            odds = ((runner.get('winRunnerOdds') or {}).get('trueOdds') or {}).get('decimalOdds') or {}
            decimal = price_history._number(odds.get('decimalOdds'))
            if decimal is None or decimal <= 1:
                american = ((runner.get('winRunnerOdds') or {}).get('americanDisplayOdds') or {}).get('americanOdds')
                decimal = price_history.decimal_from_american(american)
            row = _row(
                'fanduel', 'fanduel-public', str(market.get('eventId')),
                event.get('openDate'), away, home, kind, side, who, line, decimal, now,
            )
            if row and (kind == 'player_anytime_td' or row['line'] is not None):
                rows.append(row)
    return select_main_lines(rows)


def _one_player(name):
    text = str(name or '').strip()
    lowered = text.lower()
    if not text or ' or ' in lowered or '/' in text:
        return False
    if lowered.endswith(' defense') or 'd/st' in lowered:
        return False
    return True


def _mentions_yards(text):
    return 'yard' in text or re.search(r'\byds?\b', text) is not None


def _fanduel_market(label):
    text = str(label or '')
    lowered = text.lower()
    if any(word in lowered for word in (
        'alt ', 'alternate', 'longest', 'quarter', 'half', 'most ', 'combined',
        '1st', '2nd', '3rd', '4th', 'team total',
    )):
        return None, ''
    player = text.split(' - ', 1)[0].strip() if ' - ' in text else ''
    if 'pass' in lowered and _mentions_yards(lowered) and 'rush' not in lowered:
        return 'player_pass_yds', player
    if 'rush' in lowered and _mentions_yards(lowered) and 'receiv' not in lowered and 'pass' not in lowered:
        return 'player_rush_yds', player
    if 'receiv' in lowered and _mentions_yards(lowered):
        return 'player_reception_yds', player
    if 'reception' in lowered:
        return 'player_receptions', player
    if 'pass' in lowered and 'attempt' in lowered:
        return 'player_pass_attempts', player
    if 'completion' in lowered:
        return 'player_pass_completions', player
    if 'pass' in lowered and ('touchdown' in lowered or re.search(r'\btds?\b', lowered)):
        return 'player_pass_tds', player
    if 'any time' in lowered or 'anytime' in lowered:
        return 'player_anytime_td', player
    return None, ''


def _json(body):
    if not body:
        return None
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return None


def _pick_games(events, windows, now, hours):
    chosen = []
    for event in events:
        if event_wanted(event.get('kickoff'), windows, now, hours):
            chosen.append(event)
    chosen.sort(key=lambda event: event.get('kickoff') or '')
    return chosen[:MAX_GAMES]


def collect_betrivers(fetch, pause, windows, now, hours):
    listed = fetch(
        'https://eu-offering-api.kambicdn.com/offering/v2018/rsiusnj/listView/american_football/nfl.json?lang=en_US&market=US',
        price_history._headers(),
    )
    if listed.status != 200:
        return 'unavailable', [], f'HTTP {listed.status or "none"}'
    payload = _json(listed.body) or {}
    events = []
    for wrapper in payload.get('events') or []:
        event = (wrapper or {}).get('event') or wrapper
        if not isinstance(event, dict) or event.get('state') not in (None, 'NOT_STARTED'):
            continue
        events.append({
            'id': event.get('id'),
            'kickoff': event.get('start'),
            'away': event.get('awayName'),
            'home': event.get('homeName'),
        })
    games = _pick_games(events, windows, now, hours)
    if not games:
        return 'unavailable', [], 'no game in the capture window'
    rows = []
    for index, game in enumerate(games):
        if index:
            pause(1)
        result = fetch(
            f"https://eu-offering-api.kambicdn.com/offering/v2018/rsiusnj/betoffer/event/{game['id']}.json?lang=en_US&market=US",
            price_history._headers(),
        )
        if result.status != 200:
            continue
        rows.extend(parse_kambi_event(_json(result.body), now))
    if not rows:
        return 'unavailable', [], 'the public response had no prop prices'
    return 'ok', rows, f'{len(rows)} prices across {len(games)} games'


def collect_bovada(fetch, windows, now, hours):
    result = fetch(
        'https://www.bovada.lv/services/sports/event/v2/events/A/description/football/nfl',
        price_history._headers(),
    )
    if result.status != 200:
        return 'unavailable', [], f'HTTP {result.status or "none"}'
    rows = parse_bovada(_json(result.body), now)
    kept = []
    games = set()
    for row in rows:
        if event_wanted(row.get('kickoff'), windows, now, hours):
            kept.append(row)
            games.add(row.get('eventId'))
    if not kept:
        return 'unavailable', [], 'the public response had no prop prices in the capture window'
    if len(games) > MAX_GAMES:
        soonest = sorted(games)[:MAX_GAMES]
        kept = [row for row in kept if row.get('eventId') in set(soonest)]
    return 'ok', kept, f'{len(kept)} prices across {len({row.get("eventId") for row in kept})} games'


def _fanduel_list(fetch, client):
    return fetch(
        'https://sbapi.nj.sportsbook.fanduel.com/api/content-managed-page'
        f'?page=CUSTOM&customPageId=nfl&pbHorizontal=false&_ak={client}&timezone=America/New_York',
        price_history._headers({'x-sportsbook-region': 'NJ'}),
    )


def collect_fanduel(fetch, pause, windows, now, hours):
    page = fetch('https://sportsbook.fanduel.com/navigation/nfl', price_history._headers({'Accept': 'text/html'}))
    client = FANDUEL_PUBLIC_CLIENT
    if page.status == 200 and page.body:
        # The page also embeds a longer id that is not the odds-feed client.
        found = re.search(r'"clientId":"([A-Za-z0-9]{16})"', page.body)
        if found:
            client = found.group(1)
    listed = _fanduel_list(fetch, client)
    if listed.status != 200 and client != FANDUEL_PUBLIC_CLIENT:
        client = FANDUEL_PUBLIC_CLIENT
        listed = _fanduel_list(fetch, client)
    if listed.status != 200:
        return 'unavailable', [], f'HTTP {listed.status or "none"}'
    events = []
    for event in (( _json(listed.body) or {}).get('attachments') or {}).get('events', {}).values():
        if not isinstance(event, dict) or '@' not in str(event.get('name') or ''):
            continue
        events.append({'id': event.get('eventId'), 'kickoff': event.get('openDate'), 'name': event.get('name')})
    games = _pick_games(events, windows, now, hours)
    if not games:
        return 'unavailable', [], 'no game in the capture window'
    rows = []
    calls = 0
    for game in games:
        for tab in FANDUEL_TABS:
            pause(0.75)
            calls += 1
            result = fetch(
                'https://sbapi.nj.sportsbook.fanduel.com/api/event-page'
                f"?_ak={client}&eventId={game['id']}&tab={tab}",
                price_history._headers({'x-sportsbook-region': 'NJ'}),
            )
            if result.status != 200:
                continue
            rows.extend(parse_fanduel_page(_json(result.body), now))
    if not rows:
        return 'unavailable', [], 'the public response had no prop prices'
    return 'ok', rows, f'{len(rows)} prices across {len(games)} games'


def collect_probes(history, fetch, pause, now):
    """One request for each book that has not returned a logged-out feed."""
    first = True
    for source, url in PROBES:
        if _checked_recently(history, source, now):
            continue
        if not first:
            pause(price_history.PAUSE_SECONDS)
        first = False
        try:
            if source == 'pinnacle-public':
                status, detail = _probe_pinnacle(fetch)
            else:
                result = fetch(url, price_history._headers())
                status = 'unavailable'
                detail = f'HTTP {result.status or "none"}'
                if result.status == 200:
                    detail = 'the public page had no prop prices'
        except Exception:
            status, detail = 'unavailable', 'the public page could not be read'
        price_history.record_source(history, source, status, detail)


def _probe_pinnacle(fetch):
    config = fetch('https://www.pinnacle.com/config/app.json', price_history._headers())
    if config.status != 200:
        return 'unavailable', f'HTTP {config.status or "none"}'
    payload = _json(config.body) or {}
    haywire = ((payload.get('api') or {}).get('haywire') or {})
    key = haywire.get('apiKey')
    guest = (((haywire.get('routes') or {}).get('nolicense') or {}).get('guestRoot'))
    version = haywire.get('apiVersion') or '0.1'
    if not key or not guest:
        return 'unavailable', 'the public page had no logged-out feed'
    # The key is sent and then dropped. It is not returned and not written.
    result = fetch(
        f'{str(guest).rstrip("/")}/{version}/sports/15/leagues?brandId=0',
        price_history._headers({'X-API-Key': key}),
    )
    if result.status != 200:
        return 'unavailable', f'HTTP {result.status or "none"}'
    return 'unavailable', 'the public response had no prop prices'


def collect_books(fetch, pause, windows, now, hours=26):
    jobs = (
        ('bovada-public', lambda: collect_bovada(fetch, windows, now, hours)),
        ('betrivers-public', lambda: collect_betrivers(fetch, pause, windows, now, hours)),
        ('fanduel-public', lambda: collect_fanduel(fetch, pause, windows, now, hours)),
    )
    found = []
    for index, (source, reader) in enumerate(jobs):
        if index:
            pause(price_history.PAUSE_SECONDS)
        try:
            status, rows, detail = reader()
        except Exception:
            status, rows, detail = 'unavailable', [], 'the public page could not be read'
        found.append((source, status, rows, detail))
    return found


def apply_collection(history, private, found, roster, schedule):
    """Prices go to the private history. The public file keeps the status only."""
    added = 0
    for source, status, rows, detail in found:
        target = private if private is not None else history
        if status != 'ok':
            price_history.record_source(history, source, 'unavailable', detail or 'unavailable')
            if private is not None:
                price_history.record_source(private, source, 'unavailable', detail or 'unavailable')
            continue
        tagged = attach_identity(rows, roster, schedule)
        count = price_history.add_observations(target, tagged)
        added += count
        matched = sum(1 for row in tagged if row.get('playerId'))
        text = f'{count} new prices, {matched} with a player id'
        state = 'ok' if count or tagged else 'unavailable'
        if not tagged:
            text = 'the public page had no prices'
        price_history.record_source(history, source, state, text)
        if private is not None and private is not history:
            price_history.record_source(private, source, state, text)
    return added


def coverage_document(history, consensus=None):
    consensus = consensus or consensus_adoption({2025: None, 2026: None})
    books = {}
    markets = {}
    games = set()
    matched, unmatched = set(), set()
    for row in history.get('observations') or []:
        if not str(row.get('market') or '').startswith('player_'):
            continue
        book = books.setdefault(row['book'], {
            'book': row['book'], 'status': 'ok', 'prices': 0, 'closes': 0,
            'matchedPlayers': 0, 'unmatchedPlayers': 0,
        })
        book['prices'] += 1
        market = markets.setdefault(row['market'], {'market': row['market'], 'prices': 0, 'closes': 0})
        market['prices'] += 1
        games.add(row.get('eventId'))
        if row.get('playerId'):
            matched.add((row['book'], row['playerId']))
        elif row.get('player'):
            unmatched.add((row['book'], row['player']))
    for row in history.get('closes') or []:
        if not str(row.get('market') or '').startswith('player_'):
            continue
        if row['book'] in books:
            books[row['book']]['closes'] += 1
        if row['market'] in markets:
            markets[row['market']]['closes'] += 1
    for book, people in _people_by_book(matched, unmatched):
        if book in books:
            books[book]['matchedPlayers'] = people[0]
            books[book]['unmatchedPlayers'] = people[1]
    for source in history.get('sources') or []:
        name = str(source.get('source') or '')
        book = name.replace('-public', '')
        if source.get('status') == 'unavailable':
            books.setdefault(book, {
                'book': book, 'status': 'unavailable', 'prices': 0, 'closes': 0,
                'matchedPlayers': 0, 'unmatchedPlayers': 0, 'detail': source.get('detail') or 'unavailable',
            })
    return {
        'schema': 'coach-book-price-coverage-v1',
        'updatedAt': history.get('updatedAt'),
        'store': (
            'Normalized prices are in the gitignored file backend/data/book-props.json, '
            'kept between runs by the GitHub Actions cache. The Worker durable object '
            'keeps the latest snapshot when BOOK_PROPS_INGEST_SECRET is set. '
            'Raw book payloads are not stored. This public file has counts only.'
        ),
        'consensusAdopted': bool(consensus.get('adopted')),
        'consensusReason': consensus.get('detail') or 'unavailable',
        'games': len([game for game in games if game]),
        'prices': sum(book['prices'] for book in books.values()),
        'closes': sum(book['closes'] for book in books.values()),
        'books': sorted(books.values(), key=lambda row: row['book']),
        'markets': markets,
        'notice': (
            'A price that is not in the private store is unavailable. '
            'The no-vig consensus is not on the card. This is a comparison, not a pick.'
        ),
    }


def _people_by_book(matched, unmatched):
    books = {}
    for book, _player in matched:
        books.setdefault(book, [set(), set()])[0].add(_player)
    for book, player in unmatched:
        books.setdefault(book, [set(), set()])[1].add(player)
    for book, (yes, no) in books.items():
        yield book, (len(yes), len(no))


def load_roster_file(path):
    file = Path(path)
    if not file.exists():
        return {}
    payload = json.loads(file.read_text())
    rows = payload.get('rows') if isinstance(payload, dict) else payload
    return build_roster(rows)


def ensure_schedule(path, fetch):
    file = Path(path)
    if file.exists() and file.stat().st_size > 1000:
        return load_schedule_text(file.read_text())
    result = fetch(SCHEDULE_URL, price_history._headers())
    if result.status != 200 or not result.body or 'game_id' not in result.body[:200]:
        return []
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(result.body)
    return load_schedule_text(result.body)


def latest_snapshot(history):
    """The newest timestamp for each book. Older rows stay in the private file."""
    newest = {}
    for row in history.get('observations') or []:
        if not str(row.get('market') or '').startswith('player_'):
            continue
        newest[row['book']] = max(newest.get(row['book']) or '', row['at'])
    rows = [
        row for row in history.get('observations') or []
        if str(row.get('market') or '').startswith('player_') and row['at'] == newest.get(row['book'])
    ]
    return {
        'schema': 'coach-book-prices-v1',
        'updatedAt': history.get('updatedAt'),
        'observations': rows,
        'notice': 'Logged-out prices. A missing price is unavailable. This is a comparison, not a pick.',
    }


def push_latest(history, url, secret, fetch):
    if not url or not secret:
        return False
    target = url.rstrip('/')
    if not target.endswith('/v1/book-prices'):
        target = target + '/v1/book-prices'
    payload = json.dumps(latest_snapshot(history)).encode()
    request = urllib.request.Request(
        target,
        data=payload,
        headers={
            'Content-Type': 'application/json',
            'Authorization': f'Bearer {secret}',
            'User-Agent': price_history.USER_AGENT,
        },
        method='POST',
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return 200 <= response.status < 300
    except Exception:
        return False
