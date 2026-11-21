"""Walk-forward on free opening and closing NFL lines.

The Sportsbook Reviews Online archive publishes opening and closing spreads
and totals through the 2021-22 season. It has one moneyline column, not an
opening moneyline, and it has no timestamp inside the last three hours, no
Pinnacle-versus-retail split, and no public betting percentage. Those
features stay unavailable here.

A path is adopted only when it beats the baseline on both Brier and log loss
in 2025 and in 2026, with at least 100 scored games in each. Those seasons
are not in this archive, so the served chance stays version 2.
"""

import argparse
import json
import math
import re
import time
import urllib.request
from datetime import date
from html.parser import HTMLParser
from pathlib import Path

ARCHIVE = 'https://www.sportsbookreviewsonline.com/scoresoddsarchives/nfl/nfloddsarchives.htm'
SEASON_PAGES = [
    (2007, 'nfl-odds-2007-08'),
    (2008, 'nfl-odds-2008-09'),
    (2009, 'nfl-odds-2009-10'),
    (2010, 'nfl-odds-2010-11'),
    (2011, 'nfl-odds-2011-12'),
    (2012, 'nfl-odds-2012-13'),
    (2013, 'nfl-odds-2013-14'),
    (2014, 'nfl-odds-2014-15'),
    (2015, 'nfl-odds-2015-16'),
    (2016, 'nfl-odds-2016-17'),
    (2017, 'nfl-odds-2017-18'),
    (2018, 'nfl-odds-2018-19'),
    (2019, 'nfl-odds-2019-20'),
    (2020, 'nfl-odds-2020-21'),
    (2021, 'nfl-odds-2021-22'),
]
TEST_SEASONS = (2025, 2026)
MIN_GAMES = 100
TRAIN_MIN = 200
RIDGE = 40.0
USER_AGENT = (
    'CoachResearch/1.0 (logged-out public odds archive; +https://addversity.github.io/coach/)'
)

# Names as the archive prints them, letters only, lower case.
TEAMS = {
    'arizona': 'ARI', 'atlanta': 'ATL', 'baltimore': 'BAL', 'buffalo': 'BUF',
    'carolina': 'CAR', 'chicago': 'CHI', 'cincinnati': 'CIN', 'cleveland': 'CLE',
    'dallas': 'DAL', 'denver': 'DEN', 'detroit': 'DET', 'greenbay': 'GB',
    'houston': 'HOU', 'indianapolis': 'IND', 'jacksonville': 'JAX',
    'kansascity': 'KC', 'kansas': 'KC', 'kcchiefs': 'KC',
    'lachargers': 'LAC', 'losangeleschargers': 'LAC',
    'sandiego': 'LAC', 'sandiegochargers': 'LAC', 'larams': 'LAR',
    'losangelesrams': 'LAR', 'stlouis': 'LAR', 'saintlouis': 'LAR',
    'lasvegas': 'LV', 'lvraiders': 'LV', 'oakland': 'LV', 'miami': 'MIA', 'minnesota': 'MIN',
    'newengland': 'NE', 'neworleans': 'NO', 'nygiants': 'NYG',
    'newyorkgiants': 'NYG', 'nyjets': 'NYJ', 'newyorkjets': 'NYJ',
    'philadelphia': 'PHI', 'pittsburgh': 'PIT', 'sanfrancisco': 'SF',
    'seattle': 'SEA', 'tampabay': 'TB', 'tampa': 'TB', 'tennessee': 'TEN',
    'washington': 'WAS', 'washingtom': 'WAS', 'buffalobills': 'BUF',
    'houstontexans': 'HOU',
}


def _code(name, season):
    key = _letters(name)
    # In 2016 the Rams were the only Los Angeles club. Later files say LARams
    # or LAChargers, so a bare Los Angeles name after that is not guessed.
    if key == 'losangeles':
        return 'LAR' if season <= 2016 else None
    return TEAMS.get(key)


class _Cells(HTMLParser):
    def __init__(self):
        super().__init__()
        self.rows = []
        self._row = None
        self._cell = None

    def handle_starttag(self, tag, attrs):
        if tag == 'tr':
            self._row = []
        elif tag == 'td' and self._row is not None:
            self._cell = []

    def handle_data(self, data):
        if self._cell is not None:
            self._cell.append(data)

    def handle_endtag(self, tag):
        if tag == 'td' and self._cell is not None and self._row is not None:
            self._row.append(''.join(self._cell).strip())
            self._cell = None
        elif tag == 'tr' and self._row is not None:
            if any(self._row):
                self.rows.append(self._row)
            self._row = None


def _letters(name):
    return re.sub(r'[^a-z]', '', str(name or '').lower())


def _points(text):
    raw = str(text or '').strip().lower()
    if raw in ('pk', 'pick', 'pickem', "pick'em"):
        return 0.0
    try:
        return float(raw)
    except ValueError:
        return None


def _whole(text):
    try:
        return int(str(text).strip())
    except ValueError:
        return None


def _game_date(token, season):
    digits = str(token or '').strip()
    if not digits.isdigit():
        return None
    if len(digits) == 3:
        month, day = int(digits[0]), int(digits[1:])
    elif len(digits) == 4:
        month, day = int(digits[:2]), int(digits[2:])
    else:
        return None
    if not 1 <= month <= 12 or not 1 <= day <= 31:
        return None
    year = season if month >= 3 else season + 1
    try:
        return date(year, month, day)
    except ValueError:
        return None


def parse_archive_html(html, season):
    """Pair visitor and home rows. A game with no clear spread and total is skipped."""
    parser = _Cells()
    parser.feed(html)
    body = []
    for row in parser.rows:
        if len(row) < 12:
            continue
        if row[0].lower() == 'date':
            continue
        body.append(row)
    games = []
    unknown = []
    skipped = 0
    index = 0
    while index + 1 < len(body):
        left, right = body[index], body[index + 1]
        sides = {left[2].upper(), right[2].upper()}
        if sides != {'V', 'H'} or left[0] != right[0]:
            skipped += 1
            index += 1
            continue
        index += 2
        game = _pair(left, right, season)
        if game is None:
            skipped += 1
            # A mapped name can still fail when Open and Close on one row mix a
            # spread and a total. Only an unmapped name is reported.
            if _code(left[3], season) is None:
                unknown.append(left[3])
            if _code(right[3], season) is None:
                unknown.append(right[3])
            continue
        games.append(game)
    return games, sorted(set(unknown)), skipped


def _pair(left, right, season):
    played = _game_date(left[0], season)
    if played is None:
        return None
    visitor = left if left[2].upper() == 'V' else right
    home = right if right[2].upper() == 'H' else left
    away_code = _code(visitor[3], season)
    home_code = _code(home[3], season)
    if away_code is None or home_code is None:
        return None
    away_score = _whole(visitor[8])
    home_score = _whole(home[8])
    if away_score is None or home_score is None:
        return None
    spread_row, total_row = _split_line(visitor, home)
    if spread_row is None:
        return None
    open_spread = _points(spread_row[9])
    close_spread = _points(spread_row[10])
    open_total = _points(total_row[9])
    close_total = _points(total_row[10])
    if None in (open_spread, close_spread, open_total, close_total):
        return None
    if open_spread < 0 or close_spread < 0 or open_total <= 0 or close_total <= 0:
        return None
    home_is_favorite = spread_row is home
    sign = 1 if home_is_favorite else -1
    away_ml = _whole(visitor[11])
    home_ml = _whole(home[11])
    return {
        'season': season,
        'date': played.isoformat(),
        'away': away_code,
        'home': home_code,
        'awayScore': away_score,
        'homeScore': home_score,
        'openSpread': sign * open_spread,
        'closeSpread': sign * close_spread,
        'openTotal': open_total,
        'closeTotal': close_total,
        'homeMl': home_ml,
        'awayMl': away_ml,
    }


def _split_line(visitor, home):
    """The larger Open/Close pair is the total. The smaller pair is the spread."""
    visitor_avg = _avg(visitor)
    home_avg = _avg(home)
    if visitor_avg is None or home_avg is None:
        return None, None
    if visitor_avg >= home_avg + 12:
        return home, visitor
    if home_avg >= visitor_avg + 12:
        return visitor, home
    return None, None


def _avg(row):
    opened = _points(row[9])
    closed = _points(row[10])
    if opened is None or closed is None:
        return None
    return (opened + closed) / 2


def assign_weeks(games):
    """A new week starts when the date is six or more days after the week's first game."""
    ordered = sorted(games, key=lambda game: (game['season'], game['date'], game['away'], game['home']))
    current_season = None
    week = 0
    start = None
    for game in ordered:
        played = date.fromisoformat(game['date'])
        if game['season'] != current_season:
            current_season = game['season']
            week = 1
            start = played
        elif (played - start).days >= 6:
            week += 1
            start = played
        game['week'] = week
    return ordered


def _cdf(value):
    return 0.5 * (1 + math.erf(value / math.sqrt(2)))


def _clamp(probability):
    return min(1 - 1e-4, max(1e-4, probability))


def _implied(price):
    if price is None or price == 0:
        return None
    if price < 0:
        return (-price) / ((-price) + 100)
    return 100 / (price + 100)


def no_vig(home, away):
    left = _implied(home)
    right = _implied(away)
    if left is None or right is None or left + right <= 0:
        return None
    return left / (left + right)


def _crossed(open_line, close_line, number):
    low, high = min(open_line, close_line), max(open_line, close_line)
    return low < number < high or low < -number < high


def _features(game):
    move = game['closeSpread'] - game['openSpread']
    return [move, 1.0 if _crossed(game['openSpread'], game['closeSpread'], 3) else 0.0,
            1.0 if _crossed(game['openSpread'], game['closeSpread'], 7) else 0.0]


def _total_features(game):
    return [game['closeTotal'] - game['openTotal']]


def _ridge(rows, target, width, lam=RIDGE):
    if len(rows) < TRAIN_MIN or len(rows) != len(target):
        return None
    mean = sum(target) / len(target)
    columns = []
    centers = []
    scales = []
    for index in range(width):
        values = [row[index] for row in rows]
        center = sum(values) / len(values)
        variance = sum((value - center) ** 2 for value in values) / len(values)
        scale = math.sqrt(variance) if variance > 1e-8 else 1.0
        centers.append(center)
        scales.append(scale)
        columns.append([(value - center) / scale for value in values])
    matrix = [[0.0 for _ in range(width + 1)] for _ in range(width)]
    for column in range(width):
        for other in range(width):
            total = lam if column == other else 0.0
            total += sum(columns[column][i] * columns[other][i] for i in range(len(rows)))
            matrix[column][other] = total
        matrix[column][width] = sum(
            columns[column][i] * (target[i] - mean) for i in range(len(rows))
        )
    for column in range(width):
        pivot = max(range(column, width), key=lambda row: abs(matrix[row][column]))
        matrix[column], matrix[pivot] = matrix[pivot], matrix[column]
        divisor = matrix[column][column]
        if abs(divisor) < 1e-12:
            return None
        for k in range(column, width + 1):
            matrix[column][k] /= divisor
        for row in range(width):
            if row == column:
                continue
            factor = matrix[row][column]
            for k in range(column, width + 1):
                matrix[row][k] -= factor * matrix[column][k]
    beta = [matrix[row][width] for row in range(width)]

    def predict(features):
        value = mean
        for index in range(width):
            value += beta[index] * ((features[index] - centers[index]) / scales[index])
        return value

    return predict


def _sd(values):
    if not values:
        return 13.0
    mean = sum(values) / len(values)
    variance = sum((value - mean) ** 2 for value in values) / len(values)
    return min(16.0, max(8.0, math.sqrt(variance)))


class _Board:
    def __init__(self):
        self.n = 0
        self.brier = 0.0
        self.log_loss = 0.0

    def add(self, probability, hit):
        p = _clamp(probability)
        y = 1.0 if hit else 0.0
        self.n += 1
        self.brier += (p - y) ** 2
        self.log_loss += -(math.log(p) if hit else math.log(1 - p))

    def finish(self):
        if self.n:
            self.brier /= self.n
            self.log_loss /= self.n
        return {
            'n': self.n,
            'brier': None if self.n == 0 else round(self.brier, 4),
            'logLoss': None if self.n == 0 else round(self.log_loss, 4),
        }


def score_games(games):
    """Week by week. A week is fit on earlier weeks only."""
    ordered = assign_weeks(games)
    weeks = {}
    for index, game in enumerate(ordered):
        weeks.setdefault((game['season'], game['week']), []).append(index)
    keys = sorted(weeks)
    seasons = {}
    for key_index, key in enumerate(keys):
        season, week = key
        train = []
        for earlier in keys[:key_index]:
            train.extend(weeks[earlier])
        cover_rows = [_features(ordered[i]) for i in train]
        cover_target = [
            ordered[i]['homeScore'] - ordered[i]['awayScore'] - ordered[i]['closeSpread']
            for i in train
        ]
        total_rows = [_total_features(ordered[i]) for i in train]
        total_target = [
            ordered[i]['homeScore'] + ordered[i]['awayScore'] - ordered[i]['closeTotal']
            for i in train
        ]
        margin_target = [
            (ordered[i]['homeScore'] - ordered[i]['awayScore']) - ordered[i]['closeSpread']
            for i in train
        ]
        cover_fit = _ridge(cover_rows, cover_target, 3)
        total_fit = _ridge(total_rows, total_target, 1)
        margin_fit = _ridge(cover_rows, margin_target, 3)
        if cover_fit is None or total_fit is None or margin_fit is None:
            continue
        cover_sd = _sd(cover_target)
        total_sd = _sd(total_target)
        margin_sd = _sd([
            ordered[i]['homeScore'] - ordered[i]['awayScore'] for i in train
        ])
        bucket = seasons.setdefault(season, {
            'coverModel': _Board(), 'coverFlat': _Board(),
            'totalModel': _Board(), 'totalFlat': _Board(),
            'moneyModel': _Board(), 'moneyPrice': _Board(),
        })
        for index in weeks[key]:
            game = ordered[index]
            margin = game['homeScore'] - game['awayScore']
            points = game['homeScore'] + game['awayScore']
            if abs(margin - game['closeSpread']) >= 1e-9:
                cover = margin > game['closeSpread']
                bucket['coverFlat'].add(0.5, cover)
                bucket['coverModel'].add(_cdf(cover_fit(_features(game)) / cover_sd), cover)
            if abs(points - game['closeTotal']) >= 1e-9:
                over = points > game['closeTotal']
                bucket['totalFlat'].add(0.5, over)
                bucket['totalModel'].add(_cdf(total_fit(_total_features(game)) / total_sd), over)
            if margin != 0:
                home_win = margin > 0
                price = no_vig(game['homeMl'], game['awayMl'])
                if price is not None:
                    bucket['moneyPrice'].add(price, home_win)
                    bucket['moneyModel'].add(
                        _cdf((game['closeSpread'] + margin_fit(_features(game))) / margin_sd),
                        home_win,
                    )
    report = {}
    for season, boards in seasons.items():
        report[str(season)] = {name: board.finish() for name, board in boards.items()}
    return report


def _better(model, baseline):
    if model['n'] < MIN_GAMES or baseline['n'] < MIN_GAMES:
        return False
    return model['brier'] < baseline['brier'] and model['logLoss'] < baseline['logLoss']


def adopted(report):
    """True only when covers, totals, and moneylines all improve in both test seasons."""
    for season in TEST_SEASONS:
        row = report.get(str(season))
        if row is None:
            return False
        if not _better(row['coverModel'], row['coverFlat']):
            return False
        if not _better(row['totalModel'], row['totalFlat']):
            return False
        if not _better(row['moneyModel'], row['moneyPrice']):
            return False
    return True


def favorite_cover_rate(games):
    """Home or away favorite covered the close. Used to catch a flipped spread sign."""
    decided = 0
    covers = 0
    for game in games:
        close = game['closeSpread']
        if close == 0:
            continue
        margin = game['homeScore'] - game['awayScore']
        favorite_margin = margin if close > 0 else -margin
        if abs(favorite_margin - abs(close)) < 1e-9:
            continue
        decided += 1
        if favorite_margin > abs(close):
            covers += 1
    if decided == 0:
        return None, 0
    return covers / decided, decided


def fetch_pages(pause=time.sleep):
    games = []
    unknown = []
    skipped = 0
    for season, slug in SEASON_PAGES:
        url = f'https://www.sportsbookreviewsonline.com/scoresoddsarchives/{slug}'
        request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
        with urllib.request.urlopen(request, timeout=30) as response:
            html = response.read().decode('utf-8', 'replace')
        parsed, missing, missed = parse_archive_html(html, season)
        games.extend(parsed)
        unknown.extend(missing)
        skipped += missed
        pause(2)
    return games, sorted(set(unknown)), skipped


def build_report(games, unknown, skipped):
    rate, decided = favorite_cover_rate(games)
    if rate is None or not 0.45 <= rate <= 0.55:
        raise SystemExit(
            f'Favorite cover rate {rate} on {decided} games is outside 45 to 55 percent. '
            'The spread sign was not used.'
        )
    seasons = score_games(games)
    present = sorted({game['season'] for game in games})
    return {
        'schema': 'coach-line-movement-backtest-v1',
        'adopted': adopted(seasons),
        'source': ARCHIVE,
        'seasonsPresent': present,
        'gamesParsed': len(games),
        'rowsSkipped': skipped,
        'unknownTeams': unknown,
        'favoriteCoverRate': None if rate is None else round(rate, 4),
        'favoriteDecided': decided,
        'testSeasons': list(TEST_SEASONS),
        'testSeasonOpens': 'unavailable',
        'lateMove': 'unavailable',
        'bookDisagreement': 'unavailable',
        'againstPublic': 'unavailable',
        'steam': 'unavailable',
        'endzone': (
            'EndzoneAPI advertises a free key and, on the public pages read without an account, '
            'player-prop opens and closes since 2023. Historical game opens were not downloaded. '
            'No account was created.'
        ),
        'servedVersion2': {
            'source': 'assets/nfl-model.json v2.backtest',
            'games': 2899,
            'coverBrier': 0.250187,
            'coverLogLoss': 0.693524,
            'seasons': '2015-2026',
            'hasEdge': False,
        },
        'note': (
            'The movement chance is fit week by week on earlier weeks only. '
            'Covers and totals are compared with a flat 50 percent, which is the closing number '
            'when the file has no spread price or total price. Moneylines are compared with the '
            'no-vig closing price. 2025 and 2026 opening lines are not in this archive, so the '
            'movement chance is not served. Version 2 stays the game number. This is not a pick.'
        ),
        'seasons': seasons,
    }


def main(argv):
    parser = argparse.ArgumentParser(description='Score open-to-close movement on the free archive.')
    parser.add_argument('--output', default='assets/line-movement-backtest.json')
    parser.add_argument('--fetch', action='store_true')
    parser.add_argument('--html-dir')
    args = parser.parse_args(argv)
    if args.fetch:
        games, unknown, skipped = fetch_pages()
    elif args.html_dir:
        games = []
        unknown = []
        skipped = 0
        folder = Path(args.html_dir)
        for season, slug in SEASON_PAGES:
            html = (folder / f'{slug}.html').read_text()
            parsed, missing, missed = parse_archive_html(html, season)
            games.extend(parsed)
            unknown.extend(missing)
            skipped += missed
        unknown = sorted(set(unknown))
    else:
        raise SystemExit('Pass --fetch or --html-dir. Nothing is invented.')
    report = build_report(games, unknown, skipped)
    Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({
        'adopted': report['adopted'],
        'gamesParsed': report['gamesParsed'],
        'favoriteCoverRate': report['favoriteCoverRate'],
        'unknownTeams': report['unknownTeams'],
        'seasons': sorted(report['seasons']),
    }, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main(__import__('sys').argv[1:]))
