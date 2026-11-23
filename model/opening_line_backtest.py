"""Does Coach beat the opening line? Scored by closing line value.

Opening and closing spreads and totals for 2007-2021 come from the free
Sportsbook Reviews Online archive (one consensus number per game, not a
single book). Coach's pregame predictions come from the walk-forward team
ratings in elo_backtest.py (each week fit only on earlier weeks; the closing
line is never a feature).

Questions:
1. Does the line move toward Coach? Regress (close - open) on (Coach - open).
2. Rule: bet the opener when Coach disagrees with it by at least K points.
   Closing line value (CLV) = the chance the opener bet wins, judged by the
   closing number and the historical spread of results around closing lines
   (key numbers included), times the -110 payout, minus one. Also the actual
   result at the opener.

Output: research/opening-line/backtest.json. Nothing here is a pick.
"""

from __future__ import annotations

import argparse
import json
import re
import time
import urllib.request
from pathlib import Path

import numpy as np
import pandas as pd

ARCHIVE = 'https://www.sportsbookreviewsonline.com/scoresoddsarchives/nfl-odds-{}/'
SEASONS = range(2007, 2022)
PAYOUT = 1 + 100 / 110
THRESHOLDS = (1.0, 2.0, 3.0, 4.0)
SEED = 20261123

NAMES = {
    'Arizona': ['ARI'], 'Atlanta': ['ATL'], 'Baltimore': ['BAL'], 'Buffalo': ['BUF'], 'BuffaloBills': ['BUF'],
    'Carolina': ['CAR'], 'Chicago': ['CHI'], 'Cincinnati': ['CIN'], 'Cleveland': ['CLE'], 'Dallas': ['DAL'],
    'Denver': ['DEN'], 'Detroit': ['DET'], 'GreenBay': ['GB'], 'Houston': ['HOU'], 'HoustonTexans': ['HOU'],
    'Indianapolis': ['IND'], 'Jacksonville': ['JAX'], 'KCChiefs': ['KC'], 'Kansas': ['KC'], 'KansasCity': ['KC'],
    'LAChargers': ['LAC'], 'LARams': ['LA'], 'LVRaiders': ['LV'], 'LasVegas': ['LV'], 'LosAngeles': ['LA', 'LAC'],
    'Miami': ['MIA'], 'Minnesota': ['MIN'], 'NYGiants': ['NYG'], 'NYJets': ['NYJ'], 'NewEngland': ['NE'],
    'NewOrleans': ['NO'], 'NewYork': ['NYG', 'NYJ'], 'Oakland': ['LV'], 'Philadelphia': ['PHI'],
    'Pittsburgh': ['PIT'], 'SanDiego': ['LAC'], 'SanFrancisco': ['SF'], 'Seattle': ['SEA'], 'St.Louis': ['LA'],
    'Tampa': ['TB'], 'TampaBay': ['TB'], 'Tennessee': ['TEN'], 'Washingtom': ['WAS'], 'Washington': ['WAS'],
}


def fetch_archive(cache: Path) -> dict[int, Path]:
    cache.mkdir(parents=True, exist_ok=True)
    out = {}
    for season in SEASONS:
        path = cache / f'sbr-{season}.htm'
        if not path.exists():
            label = f'{season}-{str(season + 1)[-2:]}'
            request = urllib.request.Request(ARCHIVE.format(label), headers={'User-Agent': 'Mozilla/5.0'})
            try:
                path.write_bytes(urllib.request.urlopen(request, timeout=60).read())
            except Exception as error:  # noqa: BLE001 - a missing season is reported, not invented
                print('skip', season, error)
                continue
            time.sleep(1)
        out[season] = path
    return out


def _num(value):
    text = str(value).strip().lower()
    if text in ('pk', "pk'", 'p'):
        return 0.0
    text = re.sub(r'[^0-9.\-]', '', text)
    try:
        return float(text)
    except ValueError:
        return None


def parse_season(path: Path, season: int) -> pd.DataFrame:
    table = pd.read_html(path, flavor='lxml')[0]
    table.columns = [str(c) for c in table.iloc[0]]
    table = table.iloc[1:].reset_index(drop=True)
    rows = []
    for i in range(0, len(table) - 1, 2):
        away, home = table.iloc[i], table.iloc[i + 1]
        if away['VH'] != 'V' or home['VH'] != 'H':
            if not (away['VH'] == 'N' and home['VH'] == 'N'):
                continue
        date = str(away['Date']).zfill(4)
        month = int(date[:-2])
        year = season if month >= 8 else season + 1
        record = {'season': season, 'date': f'{year}-{month:02d}-{int(date[-2:]):02d}',
                  'awayName': away['Team'], 'homeName': home['Team']}
        for when in ('Open', 'Close'):
            a, h = _num(away[when]), _num(home[when])
            if a is None or h is None:
                record[when.lower() + 'Margin'] = None
                record[when.lower() + 'Total'] = None
                continue
            # The bigger number is the total; the smaller is the favorite's spread,
            # posted on the favorite's row.
            if a > h:
                record[when.lower() + 'Total'], record[when.lower() + 'Margin'] = a, h  # home favored by h
            else:
                record[when.lower() + 'Total'], record[when.lower() + 'Margin'] = h, -a  # away favored by a
        rows.append(record)
    return pd.DataFrame(rows)


def attach_game_ids(odds: pd.DataFrame, schedule: pd.DataFrame) -> pd.DataFrame:
    sched = schedule[schedule.game_type == 'REG'][['game_id', 'season', 'gameday', 'away_team', 'home_team']]
    index = {}
    for row in sched.itertuples():
        index.setdefault((row.gameday, row.home_team), []).append(row)
    ids, swapped = [], []
    for row in odds.itertuples():
        found, flip = None, False
        for code in NAMES.get(row.homeName, []):
            for game in index.get((row.date, code), []):
                if game.away_team in NAMES.get(row.awayName, []):
                    found = game.game_id
        if found is None:  # Neutral-site games can list the teams the other way.
            for code in NAMES.get(row.awayName, []):
                for game in index.get((row.date, code), []):
                    if game.away_team in NAMES.get(row.homeName, []):
                        found, flip = game.game_id, True
        ids.append(found)
        swapped.append(flip)
    odds = odds.assign(game_id=ids, swapped=swapped)
    for when in ('open', 'close'):
        odds.loc[odds.swapped, when + 'Margin'] = -odds.loc[odds.swapped, when + 'Margin']
    return odds[odds.game_id.notna()]


def residual_table(schedule: pd.DataFrame, last_season: int):
    """Results around the closing spread and total, from seasons before the test."""
    s = schedule[(schedule.game_type == 'REG') & schedule.result.notna() & schedule.spread_line.notna()
                 & (schedule.season >= 1999) & (schedule.season <= last_season)]
    return (s.result - s.spread_line).values, (s.total - s.total_line).dropna().values


def win_chance(residuals: np.ndarray, threshold: float, side: int) -> float | None:
    """Chance the bet wins, pushes removed. side=+1 needs residual > threshold, -1 needs < threshold."""
    wins = np.sum(residuals > threshold) if side > 0 else np.sum(residuals < threshold)
    losses = np.sum(residuals < threshold) if side > 0 else np.sum(residuals > threshold)
    return wins / (wins + losses) if wins + losses else None


def bootstrap(values, rounds=2000):
    values = np.asarray([v for v in values if v is not None and not np.isnan(v)])
    if not len(values):
        return {'n': 0, 'mean': None, 'low': None, 'high': None}
    rng = np.random.default_rng(SEED)
    means = rng.choice(values, size=(rounds, len(values)), replace=True).mean(1)
    return {'n': int(len(values)), 'mean': round(float(values.mean()), 4),
            'low': round(float(np.percentile(means, 5)), 4), 'high': round(float(np.percentile(means, 95)), 4)}


def score(merged: pd.DataFrame, schedule: pd.DataFrame) -> dict:
    report = {'spreads': {}, 'totals': {}}
    # Market move toward Coach.
    m = merged.dropna(subset=['openMargin', 'closeMargin', 'pred_margin'])
    gap, move = m.pred_margin - m.openMargin, m.closeMargin - m.openMargin
    report['spreads']['moveTowardCoach'] = {
        'games': int(len(m)),
        'slope': round(float(np.polyfit(gap, move, 1)[0]), 4),
        'correlation': round(float(np.corrcoef(gap, move)[0, 1]), 4),
    }
    t = merged.dropna(subset=['openTotal', 'closeTotal', 'pred_total'])
    tgap, tmove = t.pred_total - t.openTotal, t.closeTotal - t.openTotal
    report['totals']['moveTowardCoach'] = {
        'games': int(len(t)),
        'slope': round(float(np.polyfit(tgap, tmove, 1)[0]), 4),
        'correlation': round(float(np.corrcoef(tgap, tmove)[0, 1]), 4),
    }
    for k in THRESHOLDS:
        clv, profit, seasons = [], [], {}
        for row in m.itertuples():
            g = row.pred_margin - row.openMargin
            if abs(g) < k:
                continue
            side = 1 if g > 0 else -1  # +1: home at the opener
            res_m, _ = residual_table(schedule, row.season - 1)
            # Home covers the opener when result > openMargin, i.e. residual vs close > open - close.
            p = win_chance(res_m, row.openMargin - row.closeMargin, side)
            value = None if p is None else p * PAYOUT - 1
            clv.append(value)
            outcome = row.result - row.openMargin
            pr = None if outcome == 0 else (PAYOUT - 1 if outcome * side > 0 else -1.0)
            profit.append(pr)
            seasons.setdefault(int(row.season), []).append(value)
        report['spreads'][f'gap{k:g}'] = {
            'clv': bootstrap(clv), 'profitAtOpener': bootstrap(profit),
            'seasonsWithPositiveClv': sum(1 for v in seasons.values() if np.mean([x for x in v if x is not None]) > 0),
            'seasons': len(seasons),
        }
        clv, profit = [], []
        for row in t.itertuples():
            g = row.pred_total - row.openTotal
            if abs(g) < k:
                continue
            side = 1 if g > 0 else -1
            _, res_t = residual_table(schedule, row.season - 1)
            p = win_chance(res_t, row.openTotal - row.closeTotal, side)
            clv.append(None if p is None else p * PAYOUT - 1)
            outcome = row.total - row.openTotal
            profit.append(None if outcome == 0 else (PAYOUT - 1 if outcome * side > 0 else -1.0))
        report['totals'][f'gap{k:g}'] = {'clv': bootstrap(clv), 'profitAtOpener': bootstrap(profit)}
    # Baseline: betting every opener on a random side has CLV of about -4.5%.
    return report


def quarterback_news(merged, actual, raw, lagged, schedule) -> dict:
    """Games where a team started a different quarterback than its previous game.

    If Coach knew the change before the opener moved, it would bet the side the
    change favors at the opener. This is an upper bound on reacting to news:
    it assumes the news arrived before the line moved.
    """
    a = raw.set_index('game_id')[['home_qb_id', 'away_qb_id']]
    l = lagged.set_index('game_id')[['home_qb_id', 'away_qb_id']]
    changed = set()
    for gid in a.index.intersection(l.index):
        for col in ('home_qb_id', 'away_qb_id'):
            x, y = a.at[gid, col], l.at[gid, col]
            if isinstance(x, str) and isinstance(y, str) and x != y:
                changed.add(gid)
    m = merged.merge(actual.rename(columns={'pred_margin': 'pred_actual'}), on='game_id')
    m = m.dropna(subset=['openMargin', 'closeMargin'])
    m['changed'] = m.game_id.isin(changed)
    m['move'] = (m.closeMargin - m.openMargin).abs()
    out = {
        'gamesWithNewStarter': int(m.changed.sum()),
        'averageLineMovePoints': {
            'newStarter': round(float(m.loc[m.changed, 'move'].mean()), 2),
            'sameStarter': round(float(m.loc[~m.changed, 'move'].mean()), 2),
        },
    }
    for k in (1.0, 2.0, 3.0):
        clv, profit, toward = [], [], []
        for row in m[m.changed].itertuples():
            delta = row.pred_actual - row.pred_margin
            if abs(delta) < k:
                continue
            side = 1 if delta > 0 else -1
            res_m, _ = residual_table(schedule, row.season - 1)
            p = win_chance(res_m, row.openMargin - row.closeMargin, side)
            clv.append(None if p is None else p * PAYOUT - 1)
            outcome = row.result - row.openMargin
            profit.append(None if outcome == 0 else (PAYOUT - 1 if outcome * side > 0 else -1.0))
            toward.append((row.closeMargin - row.openMargin) * side)
        out[f'swing{k:g}'] = {
            'clv': bootstrap(clv), 'profitAtOpener': bootstrap(profit),
            'lineMoveTowardChangePoints': round(float(np.mean(toward)), 2) if toward else None,
        }
    return out


def qb_known_at_open(games: pd.DataFrame) -> pd.DataFrame:
    """Replace each game's starting quarterback with the team's previous starter.

    The schedule lists who actually started. An opener is posted days before
    injury news, so the prediction may only use the quarterback who started
    the team's previous game.
    """
    games = games.sort_values(['season', 'week']).copy()
    last = {}
    home_ids, away_ids = [], []
    for row in games.itertuples():
        home_ids.append(last.get(row.home_team))
        away_ids.append(last.get(row.away_team))
        if isinstance(row.home_qb_id, str):
            last[row.home_team] = row.home_qb_id
        if isinstance(row.away_qb_id, str):
            last[row.away_team] = row.away_qb_id
    games['home_qb_id'] = home_ids
    games['away_qb_id'] = away_ids
    return games


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cache', default='model/.cache/nflverse')
    ap.add_argument('--schedule', default='model/.cache/games.csv')
    ap.add_argument('--archive', default='model/.cache/sbr')
    ap.add_argument('--out', default='research/opening-line/backtest.json')
    ap.add_argument('--actual-qb', action='store_true', help='Use the actual starter (look-ahead; for comparison only).')
    args = ap.parse_args()

    from elo_backtest import walk_forward
    from elo_data import load_games, load_plays
    from elo_ratings import run_team_ratings, team_game_table

    schedule = pd.read_csv(args.schedule)
    odds = pd.concat([parse_season(path, season) for season, path in fetch_archive(Path(args.archive)).items()])
    odds = attach_game_ids(odds, schedule)
    games = load_games(Path(args.schedule))
    if not args.actual_qb:
        games = qb_known_at_open(games)
    plays, st = load_plays(Path(args.cache), range(2006, 2022))
    feat, _ = run_team_ratings(games[games.season <= 2021], team_game_table(plays, st))
    scored = walk_forward(feat, range(2008, 2022))
    merged = scored.merge(odds[['game_id', 'openMargin', 'closeMargin', 'openTotal', 'closeTotal']], on='game_id')
    report = {
        'source': {
            'odds': 'Sportsbook Reviews Online NFL odds archive (consensus opening and closing spread and total)',
            'oddsUrl': 'https://www.sportsbookreviewsonline.com/scoresoddsarchives/nfl/nfloddsarchives.htm',
            'model': 'walk-forward team ratings (model/elo_backtest.py), each week fit on earlier weeks only',
        },
        'seasons': [2008, 2021],
        'quarterback': 'actual starter (look-ahead)' if args.actual_qb else "the team's previous starter (known at the opener)",
        'games': int(len(merged)),
        'matchedOdds': int(len(odds)),
        'closeAgreesWithNflverse': round(float(np.mean(np.abs(merged.closeMargin - merged.spread_line) <= 1.0)), 3),
        **score(merged, schedule),
    }
    if not args.actual_qb:
        raw = load_games(Path(args.schedule))
        feat_actual, _ = run_team_ratings(raw[raw.season <= 2021], team_game_table(plays, st))
        actual = walk_forward(feat_actual, range(2008, 2022))[['game_id', 'pred_margin']]
        report['quarterbackNews'] = quarterback_news(merged, actual, raw, games, schedule)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(report, indent=1) + '\n')
    print(json.dumps(report, indent=1))


if __name__ == '__main__':
    main()
