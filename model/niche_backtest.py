"""Niche game angles, scored by closing line value (CLV) at the opener.

Free data only: nflverse schedules (roof, surface, temperature, rest, starting
quarterbacks, head coaches) and the Sportsbook Reviews Online archive
(consensus opening and closing spreads and totals, and quarter scores,
2007-2021). Each angle is tested on 2007-2014 ("find") and checked on
2015-2021 ("check"), for both sides, the same way as wind_backtest.py.

Angles:
- venue: domes, artificial turf, Denver's altitude, freezing games, dome teams
  playing outdoors in the cold.
- revenge: a starting quarterback or head coach facing a team he used to
  start for or coach.
- short week: Thursday games, Thanksgiving, a short-rest team against a
  rested one.
- late season: teams out of the playoff race (approximate) in the last four
  weeks, and teams that may rest starters in the final week.
- first half / first quarter: a team's and a head coach's history of scoring
  early (scripted drives), against the usual share of the full-game total.
  There are no free historical first-half lines, so this one is graded against
  the closing total times the league's usual first-half share, not a real
  book line, and has no CLV.

Output: research/niche/game_angles.json. Nothing here is a pick.
"""

from __future__ import annotations

import argparse
import functools
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd

import opening_line_backtest as olb

FIND = (2007, 2014)
CHECK = (2015, 2021)
GRASS = {'grass', 'dessograss'}
INDOOR = {'dome', 'closed'}
REVENGE_QB_STARTS = 8
REVENGE_COACH_GAMES = 16
LATE_WEEKS = 4
OUT_OF_RACE_PCT = 0.55
REST_RISK_PCT = 0.75
EARLY_SHRINK_GAMES = 8
EARLY_HISTORY = 16
FIRST_HALF_GAP = 0.75
FIRST_QUARTER_GAP = 0.5


# ------------------------------------------------------------------ data

def parse_quarters(path: Path, season: int) -> pd.DataFrame:
    """Quarter scores in the same row order as olb.parse_season."""
    table = pd.read_html(path, flavor='lxml')[0]
    table.columns = [str(c) for c in table.iloc[0]]
    table = table.iloc[1:].reset_index(drop=True)
    rows = []
    for i in range(0, len(table) - 1, 2):
        away, home = table.iloc[i], table.iloc[i + 1]
        if away['VH'] != 'V' or home['VH'] != 'H':
            if not (away['VH'] == 'N' and home['VH'] == 'N'):
                continue
        record = {}
        for side, row in (('away', away), ('home', home)):
            for q in ('1st', '2nd'):
                record[f'{side}Q{q[0]}'] = olb._num(row.get(q))
        rows.append(record)
    return pd.DataFrame(rows)


def load_odds(schedule: pd.DataFrame, archive: Path) -> pd.DataFrame:
    parts = []
    for season, path in olb.fetch_archive(archive).items():
        lines = olb.parse_season(path, season)
        quarters = parse_quarters(path, season)
        parts.append(pd.concat([lines.reset_index(drop=True), quarters.reset_index(drop=True)], axis=1))
    odds = olb.attach_game_ids(pd.concat(parts, ignore_index=True), schedule)
    for q in ('1', '2'):
        a, h = odds[f'awayQ{q}'].copy(), odds[f'homeQ{q}'].copy()
        odds.loc[odds.swapped, f'awayQ{q}'] = h[odds.swapped]
        odds.loc[odds.swapped, f'homeQ{q}'] = a[odds.swapped]
    return odds


def team_home_roof(schedule: pd.DataFrame) -> dict:
    """(season, team) -> True when the team's home games are mostly indoors."""
    s = schedule[(schedule.game_type == 'REG') & (schedule.location == 'Home')]
    out = {}
    for (season, team), g in s.groupby(['season', 'home_team']):
        out[(season, team)] = bool(g.roof.isin(INDOOR).mean() >= 0.5)
    return out


def standings_before(schedule: pd.DataFrame) -> dict:
    """game_id -> {team: (wins, losses, ties, games left including this one, season length)}."""
    s = schedule[schedule.game_type == 'REG'].sort_values(['season', 'week'])
    out = {}
    for season, g in s.groupby('season'):
        length = int(g.groupby('home_team').size().add(g.groupby('away_team').size(), fill_value=0).max())
        record = defaultdict(lambda: [0, 0, 0])
        for week, wk in g.groupby('week'):
            for row in wk.itertuples():
                out[row.game_id] = {}
                for team in (row.home_team, row.away_team):
                    w, l, t = record[team]
                    out[row.game_id][team] = (w, l, t, length - (w + l + t), length)
            for row in wk.itertuples():
                if pd.isna(row.result):
                    continue
                if row.result > 0:
                    record[row.home_team][0] += 1
                    record[row.away_team][1] += 1
                elif row.result < 0:
                    record[row.away_team][0] += 1
                    record[row.home_team][1] += 1
                else:
                    record[row.home_team][2] += 1
                    record[row.away_team][2] += 1
    return out


def revenge_flags(schedule: pd.DataFrame) -> dict:
    """game_id -> {'qb': side or 0, 'coach': side or 0}; side +1 home has revenge, -1 away."""
    s = schedule[schedule.game_type == 'REG'].sort_values(['season', 'week'])
    qb_starts = defaultdict(lambda: defaultdict(int))  # qb -> team -> starts in earlier seasons
    coach_games = defaultdict(lambda: defaultdict(int))
    out = {}
    for season, g in s.groupby('season'):
        for row in g.itertuples():
            flags = {'qb': 0, 'coach': 0}
            h_qb = qb_starts[row.home_qb_id][row.away_team] >= REVENGE_QB_STARTS if isinstance(row.home_qb_id, str) else False
            a_qb = qb_starts[row.away_qb_id][row.home_team] >= REVENGE_QB_STARTS if isinstance(row.away_qb_id, str) else False
            flags['qb'] = 1 if h_qb and not a_qb else (-1 if a_qb and not h_qb else 0)
            h_c = coach_games[row.home_coach][row.away_team] >= REVENGE_COACH_GAMES if isinstance(row.home_coach, str) else False
            a_c = coach_games[row.away_coach][row.home_team] >= REVENGE_COACH_GAMES if isinstance(row.away_coach, str) else False
            flags['coach'] = 1 if h_c and not a_c else (-1 if a_c and not h_c else 0)
            out[row.game_id] = flags
        # Count this season only after it ends: a revenge game is against a former team.
        for row in g.itertuples():
            if isinstance(row.home_qb_id, str):
                qb_starts[row.home_qb_id][row.home_team] += 1
            if isinstance(row.away_qb_id, str):
                qb_starts[row.away_qb_id][row.away_team] += 1
            if isinstance(row.home_coach, str):
                coach_games[row.home_coach][row.home_team] += 1
            if isinstance(row.away_coach, str):
                coach_games[row.away_coach][row.away_team] += 1
    return out


# ------------------------------------------------------------------ angles

def is_thanksgiving(row) -> bool:
    month, day = int(row.gameday[5:7]), int(row.gameday[8:10])
    return row.weekday == 'Thursday' and month == 11 and 22 <= day <= 28


def game_angles(row, standing, revenge, home_indoor, away_indoor) -> list[tuple[str, str, int]]:
    """(angle, market, side) for one game. side: spreads +1 home / -1 away; totals +1 over / -1 under.

    Each angle is listed once, with the side named in the angle; the report
    scores both that side and the other one.
    """
    out = []
    surface = row.surface.strip().lower() if isinstance(row.surface, str) else ''
    if row.roof in INDOOR:
        out.append(('venue: dome or closed roof, over', 'totals', 1))
    if surface and surface not in GRASS:
        out.append(('venue: artificial turf, over', 'totals', 1))
    if row.home_team == 'DEN' and row.location == 'Home':
        out.append(('venue: Denver altitude, Denver side', 'spreads', 1))
    if row.roof not in INDOOR and pd.notna(row.temp) and row.temp <= 32:
        out.append(('venue: freezing (32F or colder), under', 'totals', -1))
        if away_indoor and not home_indoor:
            out.append(('venue: dome team outdoors in the cold, home side', 'spreads', 1))
    if row.weekday == 'Thursday' and row.week > 1:
        if is_thanksgiving(row):
            out.append(('short week: Thanksgiving, under', 'totals', -1))
            out.append(('short week: Thanksgiving, home side', 'spreads', 1))
        else:
            out.append(('short week: Thursday, under', 'totals', -1))
            out.append(('short week: Thursday, home side', 'spreads', 1))
    if pd.notna(row.home_rest) and pd.notna(row.away_rest):
        if row.home_rest - row.away_rest >= 3 and row.away_rest <= 6:
            out.append(('short week: rested team against a short-rest team, rested side', 'spreads', 1))
        elif row.away_rest - row.home_rest >= 3 and row.home_rest <= 6:
            out.append(('short week: rested team against a short-rest team, rested side', 'spreads', -1))
    if revenge.get('qb'):
        out.append(('revenge: quarterback against his former team, his side', 'spreads', revenge['qb']))
    if revenge.get('coach'):
        out.append(('revenge: head coach against his former team, his side', 'spreads', revenge['coach']))
    if standing:
        h, a = standing.get(row.home_team), standing.get(row.away_team)
        if h and a and h[3] <= LATE_WEEKS:
            best = lambda r: (r[0] + 0.5 * r[2] + r[3]) / r[4]
            pct = lambda r: (r[0] + 0.5 * r[2]) / max(1, r[0] + r[1] + r[2])
            h_out, a_out = best(h) < OUT_OF_RACE_PCT, best(a) < OUT_OF_RACE_PCT
            if h_out != a_out:
                out.append(('late season: team out of the race (approx.), its side', 'spreads', 1 if h_out else -1))
            if h[3] == 1:
                h_rest, a_rest = pct(h) >= REST_RISK_PCT, pct(a) >= REST_RISK_PCT
                if h_rest != a_rest:
                    out.append(('late season: final week, team that may rest starters, its side', 'spreads',
                                1 if h_rest else -1))
    return out


def _score_bet(row, market, side, residuals):
    res_m, res_t = residuals(row.season - 1)
    if market == 'spreads':
        open_line, close_line, outcome = row.openMargin, row.closeMargin, row.result
        p = olb.win_chance(res_m, row.openMargin - row.closeMargin, side)
    else:
        open_line, close_line, outcome = row.openTotal, row.closeTotal, row.total
        p = olb.win_chance(res_t, row.openTotal - row.closeTotal, side)
    clv = None if p is None else p * olb.PAYOUT - 1
    at_open = None if outcome == open_line else (olb.PAYOUT - 1 if (outcome - open_line) * side > 0 else -1.0)
    at_close = None if outcome == close_line else (olb.PAYOUT - 1 if (outcome - close_line) * side > 0 else -1.0)
    return clv, at_open, at_close, (close_line - open_line) * side


def verdict(find: dict, check: dict) -> str:
    f, c = find['clv'], check['clv']
    if not f['n'] or not c['n'] or f['mean'] is None or c['mean'] is None:
        return 'too few games'
    if f['low'] > 0 and c['low'] > 0:
        return 'edge: CLV clearly above zero in both periods'
    if f['mean'] > 0 and c['mean'] > 0:
        return 'lead: CLV above zero in both periods, not yet clear'
    return 'no edge'


def score_angles(games: pd.DataFrame, schedule: pd.DataFrame) -> dict:
    residuals = functools.lru_cache(maxsize=None)(lambda season: olb.residual_table(schedule, season))
    standing = standings_before(schedule)
    revenge = revenge_flags(schedule)
    roofs = team_home_roof(schedule)
    buckets = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    for row in games.itertuples():
        period = 'find' if row.season <= FIND[1] else 'check'
        for name, market, side in game_angles(row, standing.get(row.game_id), revenge.get(row.game_id, {}),
                                              roofs.get((row.season, row.home_team), False),
                                              roofs.get((row.season, row.away_team), False)):
            for label, s in (('named side', side), ('other side', -side)):
                clv, at_open, at_close, move = _score_bet(row, market, s, residuals)
                b = buckets[name][label][period]
                b.append((clv, at_open, at_close, move))
    report = {}
    for name in sorted(buckets):
        report[name] = {}
        for label in ('named side', 'other side'):
            periods = {}
            for period in ('find', 'check'):
                rows = buckets[name][label][period]
                periods[period] = {
                    'games': len(rows),
                    'clv': olb.bootstrap([r[0] for r in rows]),
                    'profitAtOpener': olb.bootstrap([r[1] for r in rows]),
                    'profitAtClose': olb.bootstrap([r[2] for r in rows]),
                    'lineMoveTowardSide': round(float(np.mean([r[3] for r in rows])), 2) if rows else None,
                }
            periods['verdict'] = verdict(periods['find'], periods['check'])
            report[name][label] = periods
    return report


# ------------------------------------------------------------------ first half

def early_scoring(games: pd.DataFrame) -> dict:
    """A team's and a head coach's early-scoring share, from earlier games only, against a proxy line.

    share = first-half (or first-quarter) points in the team's games / full-game
    points, from the team's last 16 games before this one, shrunk toward the
    league share of earlier seasons. Prediction = closing total x average of
    the two teams' shares. Proxy line = closing total x league share, rounded
    to the half point. Graded by the actual early points against the proxy.
    """
    g = games.dropna(subset=['homeQ1', 'homeQ2', 'awayQ1', 'awayQ2', 'closeTotal', 'total']).sort_values(['season', 'week'])
    g = g.assign(h1=g.homeQ1 + g.homeQ2 + g.awayQ1 + g.awayQ2, q1=g.homeQ1 + g.awayQ1)
    out = {}
    for period_key, gap in (('h1', FIRST_HALF_GAP), ('q1', FIRST_QUARTER_GAP)):
        for owner in ('team', 'coach'):
            history = defaultdict(list)  # key -> [(early, full)]
            season_totals = defaultdict(lambda: [0.0, 0.0])
            bets = defaultdict(list)
            for row in g.itertuples():
                prior = [season_totals[s] for s in season_totals if s < row.season]
                if prior:
                    league = sum(p[0] for p in prior) / max(1.0, sum(p[1] for p in prior))
                    keys = ((row.home_team, row.away_team) if owner == 'team' else (row.home_coach, row.away_coach))
                    shares = []
                    for key in keys:
                        h = history[key][-EARLY_HISTORY:]
                        early, full = sum(x[0] for x in h), sum(x[1] for x in h)
                        n = len(h)
                        avg_full = full / n if n else 0.0
                        shares.append((early + EARLY_SHRINK_GAMES * avg_full * league) / (full + EARLY_SHRINK_GAMES * avg_full)
                                      if n and full else league)
                    pred = row.closeTotal * float(np.mean(shares))
                    line = round(row.closeTotal * league * 2) / 2
                    actual = getattr(row, period_key)
                    if abs(pred - line) >= gap and actual != line:
                        side = 1 if pred > line else -1
                        period = 'find' if row.season <= FIND[1] else 'check'
                        bets[period].append(olb.PAYOUT - 1 if (actual - line) * side > 0 else -1.0)
                        bets[period + 'Hits'].append(1.0 if (actual - line) * side > 0 else 0.0)
                for key in ((row.home_team, row.away_team) if owner == 'team' else (row.home_coach, row.away_coach)):
                    history[key].append((getattr(row, period_key), row.total))
                season_totals[row.season][0] += getattr(row, period_key)
                season_totals[row.season][1] += row.total
            name = f"{'first half' if period_key == 'h1' else 'first quarter'} by {owner} early-scoring history"
            out[name] = {
                'gapPoints': gap,
                'find': {'profitAgainstProxy': olb.bootstrap(bets['find']), 'hitRate': olb.bootstrap(bets['findHits'])},
                'check': {'profitAgainstProxy': olb.bootstrap(bets['check']), 'hitRate': olb.bootstrap(bets['checkHits'])},
            }
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--schedule', default='model/.cache/games.csv')
    ap.add_argument('--archive', default='model/.cache/sbr')
    ap.add_argument('--out', default='research/niche/game_angles.json')
    args = ap.parse_args()
    schedule = pd.read_csv(args.schedule, low_memory=False)
    odds = load_odds(schedule, Path(args.archive))
    games = schedule.merge(odds.drop(columns=['season']), on='game_id')
    games = games[(games.game_type == 'REG') & games.openMargin.notna() & games.closeMargin.notna()
                  & games.openTotal.notna() & games.closeTotal.notna() & games.result.notna()]
    report = {
        'source': 'nflverse schedules (CC BY 4.0); Sportsbook Reviews Online consensus opening and closing lines and quarter scores',
        'periods': {'find': list(FIND), 'check': list(CHECK)},
        'games': int(len(games)),
        'howToRead': ('clv = closing line value of the bet at the opener (about -4.5% for a random side). '
                      'An angle is a lead only when CLV is above zero in both periods, and an edge only when '
                      'the 90% range is above zero in both.'),
        'angles': score_angles(games, schedule),
        'earlyScoring': {
            'note': ('No free historical first-half or first-quarter lines exist, so these are graded against the '
                     'closing total times the league share of earlier seasons (a proxy line), with no CLV.'),
            **early_scoring(games),
        },
    }
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(report, indent=1) + '\n')
    print(json.dumps({k: {s: v[s]['verdict'] for s in v} for k, v in report['angles'].items()}, indent=1))
    print(json.dumps({k: v for k, v in report['earlyScoring'].items() if k != 'note'}, indent=1))


if __name__ == '__main__':
    main()
