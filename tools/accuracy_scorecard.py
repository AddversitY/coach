"""Weekly accuracy scorecard.

After a game finishes, each saved line is scored twice: Coach's chance and
the sportsbook's no-vig closing chance, on that same line. The scores are
Brier and log loss. A lower number is closer to what happened.

A week with no saved close stays unavailable. A chance that was not saved,
and cannot be computed from the served model and the saved close, is left
out. Nothing here is a bet, a unit, a bankroll, or an edge.

Game chances use Coach's Line version 2: the no-vig close, plus rest and
travel when the schedule and the stadium longitude were knowable before
kickoff, then the published recalibration. A usual quarterback, no weighted
outs, and no saved weather forecast add zero, which is what version 2
already does on an ordinary week. Priced props use the served chance written
beside the close. A prop close with no served chance is not scored.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import math
import urllib.request
from datetime import date, datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

SCHEMA = 'coach-accuracy-scorecard-v1'
EASTERN = ZoneInfo('America/New_York')
SCHEDULE_URL = (
    'https://github.com/nflverse/nflverse-data/releases/download/schedules/games.csv'
)
ALIASES = {'LA': 'LAR', 'OAK': 'LV', 'SD': 'LAC', 'STL': 'LAR', 'JAC': 'JAX', 'WSH': 'WAS'}
FAMILIES = ('spreads', 'totals', 'h2h', 'props')
FAMILY_LABELS = {
    'spreads': 'spreads',
    'totals': 'totals',
    'h2h': 'moneylines',
    'props': 'priced props',
}

# Full names match the prices The Odds API stores on a side.
NAMES = {
    'ARI': 'Arizona Cardinals', 'ATL': 'Atlanta Falcons', 'BAL': 'Baltimore Ravens',
    'BUF': 'Buffalo Bills', 'CAR': 'Carolina Panthers', 'CHI': 'Chicago Bears',
    'CIN': 'Cincinnati Bengals', 'CLE': 'Cleveland Browns', 'DAL': 'Dallas Cowboys',
    'DEN': 'Denver Broncos', 'DET': 'Detroit Lions', 'GB': 'Green Bay Packers',
    'HOU': 'Houston Texans', 'IND': 'Indianapolis Colts', 'JAX': 'Jacksonville Jaguars',
    'KC': 'Kansas City Chiefs', 'LV': 'Las Vegas Raiders', 'LAC': 'Los Angeles Chargers',
    'LAR': 'Los Angeles Rams', 'MIA': 'Miami Dolphins', 'MIN': 'Minnesota Vikings',
    'NE': 'New England Patriots', 'NO': 'New Orleans Saints', 'NYG': 'New York Giants',
    'NYJ': 'New York Jets', 'PHI': 'Philadelphia Eagles', 'PIT': 'Pittsburgh Steelers',
    'SF': 'San Francisco 49ers', 'SEA': 'Seattle Seahawks', 'TB': 'Tampa Bay Buccaneers',
    'TEN': 'Tennessee Titans', 'WAS': 'Washington Commanders',
}


def alias(team):
    if not team:
        return None
    text = str(team).strip().upper()
    return ALIASES.get(text, text)


def normal_cdf(x):
    """Same Abramowitz-Stegun approximation as Coach's Line version 2."""
    if x >= 8:
        return 1.0
    if x <= -8:
        return 0.0
    z = abs(x)
    t = 1.0 / (1.0 + 0.2316419 * z)
    density = 0.3989422804014327 * math.exp(-0.5 * z * z)
    poly = t * (
        0.319381530
        + t * (-0.356563782 + t * (1.781477937 + t * (-1.821255978 + t * 1.330274429)))
    )
    tail = density * poly
    return 1.0 - tail if x >= 0 else tail


def no_vig(decimal, other):
    """Proportional no-vig chance of the first price. Missing side stays missing."""
    try:
        left = float(decimal)
        right = float(other)
    except (TypeError, ValueError):
        return None
    if left <= 1 or right <= 1:
        return None
    implied_left = 1.0 / left
    implied_right = 1.0 / right
    total = implied_left + implied_right
    if total <= 0:
        return None
    return implied_left / total


def shifted_probability(market, delta_points, sigma):
    if sigma <= 0 or market is None or not math.isfinite(market):
        return None
    base = min(0.98, max(0.02, market))
    shift = normal_cdf(delta_points / sigma) - 0.5
    return min(0.98, max(0.02, base + shift))


def apply_platt(probability, intercept, slope):
    if probability is None:
        return None
    p = min(1.0 - 1e-6, max(1e-6, probability))
    logit = math.log(p / (1.0 - p))
    linear = max(-20.0, min(20.0, intercept + slope * logit))
    return 1.0 / (1.0 + math.exp(-linear))


def scale_and_cap(parts, scales, cap):
    if len(parts) != len(scales):
        raise ValueError('Each nudge needs one scale')
    scaled = [float(part) * float(scale) for part, scale in zip(parts, scales)]
    total = sum(scaled)
    if abs(total) > cap and abs(total) > 1e-12:
        factor = cap / abs(total)
        scaled = [part * factor for part in scaled]
    return scaled


def rest_points(days):
    if days is None:
        return 0.0
    if days <= 5:
        return max(-2.0, (days - 7) * 0.45)
    if days >= 10:
        return min(0.8, (days - 7) * 0.15)
    return 0.0


def travel_points(away_lon, game_lon):
    if away_lon is None or game_lon is None:
        return 0.0
    zones = (game_lon - away_lon) / 15.0
    if abs(zones) < 1.5:
        return 0.0
    return max(-1.0, min(1.0, 0.35 * zones))


def log_loss(probability, outcome):
    p = min(1.0 - 1e-6, max(1e-6, float(probability)))
    y = float(outcome)
    return -(y * math.log(p) + (1.0 - y) * math.log(1.0 - p))


def _round(value):
    if value is None:
        return None
    return round(float(value), 6)


def _count(value):
    number = _num(value)
    if number is None:
        return 0
    return int(number)


def _num(value):
    if value is None or value == '':
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(number):
        return None
    return number


def _parse_time(value):
    if not value:
        return None
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


def eastern_day(value):
    parsed = _parse_time(value) if not isinstance(value, datetime) else value
    if parsed is None:
        return None
    return parsed.astimezone(EASTERN).date()


def blank_tally():
    return {
        'picks': 0,
        'pushes': 0,
        'coachBrier': 0.0,
        'bookBrier': 0.0,
        'coachLogLoss': 0.0,
        'bookLogLoss': 0.0,
        'coachCloser': 0,
        'bookCloser': 0,
        'same': 0,
        'waiting': 0,
    }


def add_line(tally, line):
    result = line.get('result')
    if result == 'push':
        tally['pushes'] += 1
        return
    if result not in (0, 1):
        tally['waiting'] += 1
        return
    coach = line.get('coach')
    book = line.get('book')
    if coach is None or book is None:
        return
    tally['picks'] += 1
    tally['coachBrier'] += (coach - result) ** 2
    tally['bookBrier'] += (book - result) ** 2
    tally['coachLogLoss'] += log_loss(coach, result)
    tally['bookLogLoss'] += log_loss(book, result)
    coach_error = abs(coach - result)
    book_error = abs(book - result)
    if abs(coach_error - book_error) <= 1e-12:
        tally['same'] += 1
    elif coach_error < book_error:
        tally['coachCloser'] += 1
    else:
        tally['bookCloser'] += 1


def finish_tally(tally, *, status, season, week=None, families=None):
    picks = tally['picks']
    row = {
        'picks': picks,
        'pushes': tally['pushes'],
        'coachCloser': tally['coachCloser'],
        'bookCloser': tally['bookCloser'],
        'same': tally['same'],
        'waiting': tally['waiting'],
        'coachBrier': _round(tally['coachBrier'] / picks) if picks else None,
        'bookBrier': _round(tally['bookBrier'] / picks) if picks else None,
        'coachLogLoss': _round(tally['coachLogLoss'] / picks) if picks else None,
        'bookLogLoss': _round(tally['bookLogLoss'] / picks) if picks else None,
    }
    if families is not None:
        row['families'] = families
    if picks:
        row['status'] = 'scored'
    elif status == 'pending':
        row['status'] = 'pending'
    else:
        row['status'] = 'unavailable'
    row['sentence'] = sentence(row, season=season, week=week)
    return row


def _loss_order(row):
    """Put the lower log loss first. Equal values stay side by side."""
    coach = row.get('coachLogLoss')
    book = row.get('bookLogLoss')
    if coach is None or book is None or book <= coach:
        return (book, coach, 'books', 'Coach')
    return (coach, book, 'Coach', 'books')


def sentence(row, *, season, week=None):
    """Plain language. The first number is the closer chance. Lower is better."""
    status = row.get('status')
    scope = 'This season' if week is None else f'Week {week}'
    if status == 'unavailable':
        if row.get('reason') == 'push':
            if week is None:
                return 'This season is unavailable. Every saved line pushed, so there is no score.'
            return f'Week {week} is unavailable. Every saved line pushed, so there is no score.'
        if row.get('reason') == 'no-chance':
            if week is None:
                return (
                    'This season is unavailable. Closing prices are saved, and '
                    "Coach's chance on those lines was not saved."
                )
            return (
                f'Week {week} is unavailable. Closing prices are saved, and '
                "Coach's chance on those lines was not saved."
            )
        if week is None:
            return (
                'This season is unavailable. No finished week has a saved '
                'closing price and a final result.'
            )
        return (
            f'Week {week} is unavailable. No closing prices were saved for that week.'
        )
    if status == 'pending' or not row.get('picks'):
        if week is None:
            return (
                'This season is unavailable. Closing prices are saved, and '
                'no final result is in yet.'
            )
        return (
            f'Week {week} is unavailable until those games finish. Closing '
            'prices are saved, and no final result is in yet.'
        )
    coach = row['coachBrier']
    book = row['bookBrier']
    if coach is None or book is None:
        if week is None:
            return 'This season is unavailable.'
        return f'Week {week} is unavailable.'
    coach_text = f'{coach:.3f}'
    book_text = f'{book:.3f}'
    gap = abs(coach - book)
    if coach_text == book_text:
        lead = f'{scope} Coach and the books were equally accurate: {coach_text} (lower is better).'
    elif book < coach:
        word = 'slightly ' if gap < 0.01 else ''
        lead = (
            f'{scope} the books were {word}more accurate: {book_text} vs {coach_text} '
            '(lower is better).'
        )
    else:
        word = 'slightly ' if gap < 0.01 else ''
        lead = (
            f'{scope} Coach was {word}more accurate: {coach_text} vs {book_text} '
            '(lower is better).'
        )
    loss_order = _loss_order(row)
    loss = ''
    if loss_order[0] is not None and loss_order[1] is not None:
        first = f'{loss_order[0]:.3f}'
        second = f'{loss_order[1]:.3f}'
        if first == second:
            loss = f' Log loss was {first} for both.'
        else:
            loss = f' Log loss was {first} vs {second}, {loss_order[2]} first.'
    lines = (
        f' {row["picks"]} lines. Coach was closer on {row["coachCloser"]} '
        f'and the books on {row["bookCloser"]}.'
    )
    tied = ''
    if row.get('same'):
        tied = f' They matched on {row["same"]}.'
    missing = _missing_clause(row.get('families'))
    waiting = ''
    families = row.get('families') or {}
    pending = [
        FAMILY_LABELS[key]
        for key in FAMILIES
        if families.get(key, {}).get('status') == 'pending'
    ]
    if pending:
        if len(pending) == 1:
            names = pending[0]
        else:
            names = ', '.join(pending[:-1]) + ' and ' + pending[-1]
        waiting = f' {names[0].upper()}{names[1:]} are still waiting on a final result.'
    elif row.get('waiting'):
        waiting = ' Some saved prices are still waiting on a final result.'
    return (
        f'{lead}{loss}{lines}{tied}{missing}{waiting} '
        'This compares chances with the closing price. It is not a pick.'
    )


def _missing_clause(families):
    if not families:
        return ''
    missing = [
        FAMILY_LABELS[key]
        for key in FAMILIES
        if families.get(key, {}).get('status') == 'unavailable'
    ]
    if not missing or len(missing) == len(FAMILIES):
        return ''
    if len(missing) == 1:
        names = missing[0]
    else:
        names = ', '.join(missing[:-1]) + ' and ' + missing[-1]
    return f' {names[0].upper()}{names[1:]} are unavailable.'


def _half(point):
    return round(float(point) * 2.0) / 2.0


def _family(market):
    if market in ('spreads', 'totals', 'h2h'):
        return market
    if str(market).startswith('player_') or market in (
        'passing_yards', 'rushing_yards', 'receiving_yards', 'receptions',
    ):
        return 'props'
    return None


def load_json(path):
    file = Path(path)
    if not file.exists():
        return None
    return json.loads(file.read_text())


def schedule_from_history(payload):
    games = []
    for row in (payload or {}).get('games') or []:
        played = _schedule_game(
            season=row.get('season'),
            week=row.get('week'),
            day=row.get('date'),
            away=row.get('away'),
            home=row.get('home'),
            home_score=row.get('homeScore'),
            away_score=row.get('awayScore'),
        )
        if played:
            games.append(played)
    return games


def schedule_from_csv(text):
    games = []
    for row in csv.DictReader(io.StringIO(text)):
        if row.get('game_type') not in (None, '', 'REG'):
            continue
        played = _schedule_game(
            season=row.get('season'),
            week=row.get('week'),
            day=row.get('gameday'),
            away=row.get('away_team'),
            home=row.get('home_team'),
            home_score=row.get('home_score'),
            away_score=row.get('away_score'),
        )
        if played:
            games.append(played)
    return games


def _schedule_game(*, season, week, day, away, home, home_score, away_score):
    try:
        season = int(season)
        week = int(week)
        played_on = date.fromisoformat(str(day)[:10])
    except (TypeError, ValueError):
        return None
    away_code = alias(away)
    home_code = alias(home)
    if away_code not in NAMES or home_code not in NAMES:
        return None
    return {
        'season': season,
        'week': week,
        'date': played_on,
        'away': away_code,
        'home': home_code,
        'home_score': _score(home_score),
        'away_score': _score(away_score),
    }


def _score(value):
    number = _num(value)
    if number is None:
        return None
    if abs(number - round(number)) > 1e-6 or number < 0 or number > 100:
        return None
    return int(round(number))


def fetch_schedule(url=SCHEDULE_URL, timeout=20):
    request = urllib.request.Request(url, headers={'User-Agent': 'CoachResearch/1.0'})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return schedule_from_csv(response.read().decode('utf-8', 'replace'))


def merge_schedule(primary, fallback):
    """Prefer a row that has a final score. Do not invent one."""
    merged = {}
    for source in (fallback or [], primary or []):
        for game in source:
            key = (game['season'], game['week'], game['away'], game['home'])
            current = merged.get(key)
            if current is None:
                merged[key] = dict(game)
                continue
            if current['home_score'] is None and game['home_score'] is not None:
                merged[key] = dict(game)
            elif current['date'] != game['date'] and game['home_score'] is not None:
                merged[key] = dict(game)
    return list(merged.values())


def _result_index(schedule):
    found = {}
    for game in schedule:
        found[(game['season'], game['week'], game['away'], game['home'])] = game
    return found


def _rest_days(schedule, team, kickoff_day):
    earlier = [
        game['date']
        for game in schedule
        if kickoff_day is not None
        and game['date'] < kickoff_day
        and team in (game['away'], game['home'])
    ]
    if not earlier:
        return None
    return (kickoff_day - max(earlier)).days


def _model_bits(model):
    version = (model or {}).get('v2') or {}
    scales = version.get('scales') or {}
    cover = version.get('coverCalibration') or {}
    total = version.get('totalCalibration') or {}
    try:
        parsed = {
            'sigma': float(version['sigma']),
            'totalSigma': float(version.get('totalSigma') or version['sigma']),
            'marginCap': float(version.get('marginCap') or 4),
            'totalCap': float(version.get('totalCap') or 6),
            'scales': [float(scales[key]) for key in ('qb', 'injury', 'rest', 'travel')],
            'totalScales': [
                float(scales[key]) for key in ('weather', 'injuryTotal', 'qbTotal')
            ],
            'cover': (float(cover.get('intercept') or 0), float(cover.get('slope') or 1)),
            'total': (float(total.get('intercept') or 0), float(total.get('slope') or 1)),
            'lon': {
                team: _num((context or {}).get('homeLon'))
                for team, context in (version.get('teams') or {}).items()
            },
        }
    except (KeyError, TypeError, ValueError):
        return None
    if parsed['sigma'] <= 0 or parsed['totalSigma'] <= 0:
        return None
    return parsed


def _group_games(closes):
    labeled = {}
    for row in closes:
        away = alias(row.get('away'))
        home = alias(row.get('home'))
        kick = row.get('kickoff')
        if row.get('season') and row.get('week') and away and home and kick:
            labeled[(away, home, kick)] = (int(row['season']), int(row['week']))
    games = {}
    for row in closes:
        if row.get('market') not in ('spreads', 'totals', 'h2h'):
            continue
        away = alias(row.get('away'))
        home = alias(row.get('home'))
        kick = row.get('kickoff')
        if not away or not home or not kick:
            continue
        placed = labeled.get((away, home, kick))
        if placed is None and row.get('season') and row.get('week'):
            placed = (int(row['season']), int(row['week']))
        if placed is None:
            continue
        season, week = placed
        key = (season, week, away, home)
        bucket = games.setdefault(key, {'kickoff': kick, 'rows': []})
        bucket['rows'].append(row)
        if kick < bucket['kickoff']:
            bucket['kickoff'] = kick
    return games


def _book_pairs(rows, left_name, right_name, *, lined):
    books = {}
    for row in rows:
        outcome = str(row.get('outcome') or '')
        if outcome not in (left_name, right_name):
            continue
        decimal = _num(row.get('decimal'))
        if decimal is None or decimal <= 1:
            continue
        side = books.setdefault(str(row.get('book') or '').lower(), {})
        current = side.get(outcome)
        if current is None or str(row.get('at') or '') >= str(current.get('at') or ''):
            side[outcome] = row
    pairs = []
    for book, sides in books.items():
        left = sides.get(left_name)
        right = sides.get(right_name)
        if left is None or right is None:
            continue
        left_line = _num(left.get('line'))
        right_line = _num(right.get('line'))
        if lined:
            if left_line is None or right_line is None:
                continue
            if abs(left_line - right_line) > 0.11 and abs(left_line + right_line) > 0.11:
                continue
            point = _half(left_line)
        else:
            point = None
        chance = no_vig(left.get('decimal'), right.get('decimal'))
        if chance is None:
            continue
        pairs.append({'book': book, 'line': point, 'chance': chance})
    return pairs


def _consensus(pairs):
    if not pairs:
        return None
    pinnacle = [row for row in pairs if row['book'] == 'pinnacle']
    if pinnacle:
        pinnacle.sort(key=lambda row: (row['line'] is None, row['line'] or 0, row['book']))
        chosen = pinnacle[0]
        return {'line': chosen['line'], 'chance': chosen['chance'], 'source': 'pinnacle'}
    if pairs[0]['line'] is None:
        chance = sum(row['chance'] for row in pairs) / len(pairs)
        return {'line': None, 'chance': chance, 'source': 'books'}
    counts = {}
    for row in pairs:
        counts.setdefault(row['line'], []).append(row)
    best = max(counts, key=lambda line: (len(counts[line]), -abs(line)))
    chosen = counts[best]
    chance = sum(row['chance'] for row in chosen) / len(chosen)
    return {'line': best, 'chance': chance, 'source': 'books'}


def _margin_residual(bits, schedule, away, home, kickoff_day):
    home_rest = rest_points(_rest_days(schedule, home, kickoff_day))
    away_rest = rest_points(_rest_days(schedule, away, kickoff_day))
    travel = travel_points(bits['lon'].get(away), bits['lon'].get(home))
    # Quarterback and injuries stay zero: those snapshots were not saved.
    # Weather stays zero: no pre-kickoff forecast was saved for the total.
    parts = scale_and_cap(
        [0.0, 0.0, home_rest - away_rest, travel],
        bits['scales'],
        bits['marginCap'],
    )
    total_parts = scale_and_cap([0.0, 0.0, 0.0], bits['totalScales'], bits['totalCap'])
    return sum(parts), sum(total_parts)


def game_lines(closes, schedule, model, now):
    bits = _model_bits(model)
    results = _result_index(schedule)
    lines = []
    waiting_keys = set()
    for (season, week, away, home), game in sorted(_group_games(closes).items()):
        kickoff = _parse_time(game['kickoff'])
        if kickoff is None:
            continue
        final = results.get((season, week, away, home))
        finished = (
            final is not None
            and final['home_score'] is not None
            and final['away_score'] is not None
            and kickoff <= now
        )
        if bits is None:
            if not finished:
                waiting_keys.add((season, week))
            continue
        residual, total_residual = _margin_residual(
            bits, schedule, away, home, eastern_day(kickoff),
        )
        specs = (
            ('spreads', NAMES[home], NAMES[away], True),
            ('totals', 'Over', 'Under', True),
            ('h2h', NAMES[home], NAMES[away], False),
        )
        for market, left, right, lined in specs:
            rows = [row for row in game['rows'] if row.get('market') == market]
            agreed = _consensus(_book_pairs(rows, left, right, lined=lined))
            if agreed is None:
                continue
            if not finished:
                waiting_keys.add((season, week, market))
                continue
            home_score = final['home_score']
            away_score = final['away_score']
            if market == 'spreads':
                margin = home_score - away_score
                cover = margin + agreed['line']
                if abs(cover) <= 1e-9:
                    result = 'push'
                else:
                    result = 1 if cover > 0 else 0
                coach = apply_platt(
                    shifted_probability(agreed['chance'], residual, bits['sigma']),
                    bits['cover'][0],
                    bits['cover'][1],
                )
            elif market == 'totals':
                total = home_score + away_score - agreed['line']
                if abs(total) <= 1e-9:
                    result = 'push'
                else:
                    result = 1 if total > 0 else 0
                coach = apply_platt(
                    shifted_probability(agreed['chance'], total_residual, bits['totalSigma']),
                    bits['total'][0],
                    bits['total'][1],
                )
            else:
                if home_score == away_score:
                    result = 'push'
                else:
                    result = 1 if home_score > away_score else 0
                coach = shifted_probability(agreed['chance'], residual, bits['sigma'])
            if coach is None:
                continue
            line_label = 'ml' if agreed['line'] is None else f'{agreed["line"]:.1f}'
            lines.append({
                'id': f'game:{season}:{week}:{away}:{home}:{market}:{line_label}',
                'season': season,
                'week': week,
                'family': market,
                'market': market,
                'coach': _round(coach),
                'book': _round(agreed['chance']),
                'result': result,
                'frozen': True,
                'source': 'served-v2',
            })
    return lines, waiting_keys


def prop_lines(props, chances):
    lookup = {}
    for row in chances or []:
        key = (
            int(row['season']),
            int(row['week']),
            str(row['playerId']),
            str(row['metric']),
            _half(row['line']),
        )
        chance = _num(row.get('coach'))
        if chance is None or not 0 < chance < 1:
            continue
        lookup[key] = chance
    chosen = {}
    order = []
    for row in props or []:
        metric = str(row.get('metric') or '')
        if metric == 'anytime_td':
            continue
        try:
            key = (
                int(row['season']),
                int(row['week']),
                str(row['playerId']),
                metric,
                _half(row['line']),
            )
        except (KeyError, TypeError, ValueError):
            continue
        coach = lookup.get(key)
        book = _num(row.get('prior'))
        actual = _num(row.get('actual'))
        line = _num(row.get('line'))
        if coach is None or book is None or not 0 < book < 1 or actual is None or line is None:
            continue
        if abs(actual - line) <= 1e-9:
            result = 'push'
        else:
            result = 1 if actual > line else 0
        built = {
            'id': f'prop:{key[0]}:{key[1]}:{key[2]}:{key[3]}:{key[4]:.1f}',
            'season': key[0],
            'week': key[1],
            'family': 'props',
            'market': metric,
            'coach': _round(coach),
            'book': _round(book),
            'result': result,
            'frozen': True,
            'source': 'served-prop',
        }
        # One result is one line. A second saved close for that line, often
        # from another event id, would double-count it. Prefer the close
        # that includes Pinnacle, then the quote with more books.
        rank = (
            0 if row.get('pinnacle') is None else 1,
            _count(row.get('books')),
            -_count(row.get('stale')),
        )
        current = chosen.get(key)
        if current is None or rank >= current[0]:
            if current is None:
                order.append(key)
            chosen[key] = (rank, built)
    return [chosen[key][1] for key in order]


def _saved_weeks(closes, props):
    weeks = set()
    for season, week, _away, _home in _group_games(closes):
        weeks.add((season, week))
    for row in props or []:
        try:
            weeks.add((int(row['season']), int(row['week'])))
        except (KeyError, TypeError, ValueError):
            continue
    return weeks


def _logic_id(row):
    """One game market is one line, even if a later close reprint moves the number."""
    text = str(row.get('id') or '')
    if text.startswith('game:'):
        parts = text.split(':')
        if len(parts) >= 6:
            return ':'.join(parts[:6])
    return text


def _freeze(previous, fresh):
    """A stored chance stays. A corrected result may replace a missing one."""
    stored = {}
    for row in (previous or {}).get('lines') or []:
        if row.get('coach') is not None and row.get('book') is not None and _logic_id(row):
            stored[_logic_id(row)] = row
    kept = []
    seen = set()
    for row in fresh:
        key = _logic_id(row)
        prior = stored.get(key)
        if prior is not None:
            merged = dict(prior)
            merged['frozen'] = True
            if prior.get('result') not in (0, 1, 'push'):
                merged['result'] = row['result']
            kept.append(merged)
        else:
            kept.append(row)
        seen.add(key)
    for key, prior in stored.items():
        if key not in seen and prior.get('result') in (0, 1, 'push'):
            kept.append(prior)
    kept.sort(key=lambda row: (row['season'], row['week'], row['id']))
    return kept


def build_scorecard(*, closes, schedule, model, props, chances, previous, now, season):
    fresh = []
    game_rows, waiting = game_lines(closes, schedule, model, now)
    fresh.extend(game_rows)
    fresh.extend(prop_lines(props, chances))
    lines = _freeze(previous, fresh)
    saved = _saved_weeks(closes, props)
    open_families = {}
    for key in waiting:
        if len(key) == 2:
            open_families.setdefault(key, set()).update(FAMILIES)
        elif len(key) == 3:
            open_families.setdefault((key[0], key[1]), set()).add(key[2])
    settled_props = set()
    for row in props or []:
        if row.get('actual') is None:
            continue
        try:
            settled_props.add((int(row['season']), int(row['week'])))
            open_families.setdefault((int(row['season']), int(row['week'])), set()).add('props')
        except (KeyError, TypeError, ValueError):
            continue
    for (season_id, week_id, _away, _home), game in _group_games(closes).items():
        families = open_families.setdefault((season_id, week_id), set())
        for row in game['rows']:
            family = _family(row.get('market'))
            if family:
                families.add(family)
    seasons = {row[0] for row in saved}
    seasons.update(row['season'] for row in lines)
    if season is None:
        season = max(seasons) if seasons else None
    season_lines = [row for row in lines if season is None or row['season'] == season]
    weeks_present = {row[1] for row in saved if row[0] == season}
    weeks_present.update(row['week'] for row in season_lines)
    schedule_weeks = [
        game['week']
        for game in schedule
        if game['season'] == season and game['home_score'] is not None
    ]
    upper = max(schedule_weeks + list(weeks_present), default=0)
    if upper:
        weeks_present.update(range(1, upper + 1))
    week_rows = []
    for week in sorted(weeks_present):
        week_lines = [row for row in season_lines if row['week'] == week]
        opened = open_families.get((season, week), set())
        waiting_week = any(key[0] == season and key[1] == week for key in waiting)
        decided = any(row.get('result') in (0, 1) for row in week_lines)
        pushed = any(row.get('result') == 'push' for row in week_lines)
        if decided:
            status, reason = 'pending', 'no-result'
        elif waiting_week:
            status, reason = 'pending', 'no-result'
        elif pushed:
            status, reason = 'unavailable', 'push'
        elif (season, week) in settled_props and not week_lines:
            status, reason = 'unavailable', 'no-chance'
        elif opened:
            status, reason = 'pending', 'no-result'
        else:
            status, reason = 'unavailable', 'no-close'
        built = _week_row(
            week_lines,
            status=status,
            season=season,
            week=week,
            open_families=opened,
        )
        built['reason'] = reason
        built['sentence'] = sentence(built, season=season, week=week)
        week_rows.append(built)
    season_open = set()
    for (season_id, _week), families in open_families.items():
        if season_id == season:
            season_open.update(families)
    season_row = _week_row(
        [row for row in season_lines if row.get('result') in (0, 1, 'push')],
        status='pending' if season_open else 'unavailable',
        season=season,
        week=None,
        open_families=season_open,
    )
    if season_row['status'] != 'scored':
        if any(row['status'] == 'pending' for row in week_rows):
            season_row['reason'] = 'no-result'
            season_row['status'] = 'pending'
        elif any(row.get('reason') == 'no-chance' for row in week_rows):
            season_row['reason'] = 'no-chance'
            season_row['status'] = 'unavailable'
        else:
            season_row['reason'] = 'no-close'
        season_row['sentence'] = sentence(season_row, season=season, week=None)
    elif any(row['status'] == 'pending' for row in week_rows):
        if 'waiting on a final result' not in season_row['sentence']:
            season_row['sentence'] = season_row['sentence'].replace(
                ' This compares',
                ' Later weeks with a saved close are still waiting on a final result. This compares',
                1,
            )
    return {
        'schema': SCHEMA,
        'updatedAt': now.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z'),
        'season': season,
        'notice': (
            'Brier and log loss compare Coach\'s chance with the book\'s no-vig '
            'closing chance on the same line. Lower is better. A week with no '
            'saved close is unavailable. This is not a pick.'
        ),
        'lines': lines,
        'weeks': week_rows,
        'seasonToDate': season_row,
    }


def _week_row(lines, *, status, season, week, open_families=()):
    families = {}
    for key in FAMILIES:
        group = [row for row in lines if row.get('family') == key]
        tally = blank_tally()
        for row in group:
            add_line(tally, row)
        if tally['picks']:
            family_status = 'scored'
        elif key in open_families:
            family_status = 'pending'
        else:
            family_status = 'unavailable'
        families[key] = finish_tally(tally, status=family_status, season=season, week=week)
        families[key].pop('sentence', None)
        families[key].pop('families', None)
    tally = blank_tally()
    for row in lines:
        add_line(tally, row)
    overall = 'scored' if tally['picks'] else status
    finished = finish_tally(
        tally, status=overall, season=season, week=week, families=families,
    )
    if week is not None:
        finished['season'] = season
        finished['week'] = week
    finished['families'] = families
    return finished


def build_from_files(
    *,
    history_path,
    results_path,
    model_path,
    props_path,
    chances_path,
    output_path,
    now=None,
    schedule=None,
    fetch=True,
):
    now = now or datetime.now(timezone.utc)
    history = load_json(history_path) or {}
    results = schedule_from_history(load_json(results_path) or {})
    fetched = []
    if fetch and schedule is None:
        try:
            fetched = fetch_schedule()
        except Exception:
            fetched = []
    games = merge_schedule(schedule if schedule is not None else fetched, results)
    model = load_json(model_path) or {}
    props_file = load_json(props_path) or {}
    props = props_file.get('rows') if isinstance(props_file, dict) else []
    chances_file = load_json(chances_path) or {}
    chances = chances_file.get('rows') if isinstance(chances_file, dict) else []
    previous = load_json(output_path) if output_path else None
    season = None
    dated = [game['season'] for game in games]
    if dated:
        season = max(dated)
    card = build_scorecard(
        closes=history.get('closes') or [],
        schedule=games,
        model=model,
        props=props,
        chances=chances,
        previous=previous,
        now=now,
        season=season,
    )
    if output_path:
        Path(output_path).write_text(json.dumps(card, indent=2) + '\n')
    return card


def main():
    parser = argparse.ArgumentParser(description='Build the weekly accuracy scorecard')
    parser.add_argument('--history', default='assets/price-history.json')
    parser.add_argument('--history-results', default='assets/nfl-history.json')
    parser.add_argument('--model', default='assets/nfl-model.json')
    parser.add_argument('--props', default='assets/prop-closes.json')
    parser.add_argument('--prop-chances', default='assets/prop-served-chances.json')
    parser.add_argument('--output', default='assets/accuracy-scorecard.json')
    parser.add_argument('--no-fetch', action='store_true')
    args = parser.parse_args()
    card = build_from_files(
        history_path=args.history,
        results_path=args.history_results,
        model_path=args.model,
        props_path=args.props,
        chances_path=args.prop_chances,
        output_path=args.output,
        fetch=not args.no_fetch,
    )
    season = card['seasonToDate']
    print(
        f"season {card['season']}: {season['status']} "
        f"picks={season['picks']} coach={season['coachBrier']} book={season['bookBrier']}"
    )


if __name__ == '__main__':
    main()
