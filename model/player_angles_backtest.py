"""Niche player angles: venue splits, milestones, revenge, short weeks, kickers, sticky prop lines.

Free data only: nflverse weekly player stats 2012-2026 and schedules (CC BY
4.0), and the 2026 two-sided prop closes already in assets/prop-closes.json
(PropLine sample, weeks 2-3).

There are no free historical prop lines before 2026, so the long test
(2012-2018 find, 2019-2025 check) uses a proxy line: the player's median over
his previous 10 games. Because that proxy is biased (medians sit below means),
each angle is compared with the same-direction bet on every player-game in the
period ("lift" = angle hit rate minus base hit rate). Where an angle fires on a
2026 game with a real closing line, it is also graded against that close:
value = hit / no-vig close chance - 1 (zero means the close was right).

Angles:
- venue split: the player's own shrunk average on this surface (turf or grass)
  or roof (indoor or outdoor) against his overall average; and visiting
  players at Denver's altitude.
- milestone: in the last two weeks, a player within reach of 1,000 rushing or
  receiving yards or 4,000 passing yards. Contract incentives have no free
  source and are skipped.
- revenge: a player facing a team he played at least 8 games for.
- short week: Thursday games and Thanksgiving.
- kicker: kicking points (3 x field goals + extra points) in wind of 15+ mph or
  32F or colder, by the kicker's prior 40+ yard accuracy.
- sticky line (2026 weeks 2 to 3 only): the prop line barely moved while the
  opponent's defense against that stat changed sharply.

Output: research/niche/player_angles.json. Nothing here is a pick.
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict, deque
from pathlib import Path

import numpy as np
import pandas as pd

import opening_line_backtest as olb

METRICS = {
    'passing_yards': {'QB'},
    'rushing_yards': {'RB'},
    'receiving_yards': {'WR', 'TE'},
    'receptions': {'WR', 'TE', 'RB'},
}
MILESTONES = {'passing_yards': 4000, 'rushing_yards': 1000, 'receiving_yards': 1000}
FIND = (2012, 2018)
CHECK = (2019, 2025)
WINDOW = 10
MIN_GAMES = 6
SPLIT_SHRINK = 6
SPLIT_FLAG = 0.10
REVENGE_GAMES = 8
STICKY_LINE = 0.03
STICKY_MATCHUP = 0.10
GRASS = {'grass', 'dessograss'}
INDOOR = {'dome', 'closed'}
COLUMNS = ['player_id', 'player_display_name', 'position', 'season', 'week', 'season_type', 'game_id', 'team',
           'opponent_team', 'passing_yards', 'rushing_yards', 'receiving_yards', 'receptions', 'fg_made', 'fg_att',
           'pat_made', 'fg_made_40_49', 'fg_made_50_59', 'fg_missed_40_49', 'fg_missed_50_59']


def load_stats(folder: Path, seasons) -> pd.DataFrame:
    parts = []
    for season in seasons:
        path = folder / f'stats_player_week_{season}.csv'
        if path.exists():
            frame = pd.read_csv(path, low_memory=False)
            parts.append(frame[[c for c in COLUMNS if c in frame.columns]])
    stats = pd.concat(parts, ignore_index=True)
    return stats[stats.season_type == 'REG']


def attach_games(stats: pd.DataFrame, schedule: pd.DataFrame) -> pd.DataFrame:
    s = schedule[['game_id', 'gameday', 'weekday', 'roof', 'surface', 'temp', 'wind', 'home_team', 'location']]
    out = stats.merge(s, on='game_id', how='left')
    surface = out.surface.fillna('').str.strip().str.lower()
    out['turf'] = np.where(surface == '', np.nan, (~surface.isin(GRASS)).astype(float))
    out['indoor'] = out.roof.isin(INDOOR).astype(float)
    out['atDenver'] = ((out.home_team == 'DEN') & (out.team != 'DEN') & (out.location == 'Home')).astype(float)
    # Control: the same Denver defense, but in the player's own stadium (no altitude).
    out['denverVisits'] = ((out.opponent_team == 'DEN') & (out.home_team == out.team)).astype(float)
    month = pd.to_numeric(out.gameday.str[5:7], errors='coerce')
    day = pd.to_numeric(out.gameday.str[8:10], errors='coerce')
    out['thursday'] = ((out.weekday == 'Thursday') & (out.week > 1)).astype(float)
    out['thanksgiving'] = ((out.weekday == 'Thursday') & (month == 11) & day.between(22, 28)).astype(float)
    out['badWeather'] = ((~out.roof.isin(INDOOR)) & ((out.wind >= 15) | (out.temp <= 32))).astype(float)
    return out


def season_lengths(schedule: pd.DataFrame) -> dict:
    s = schedule[schedule.game_type == 'REG']
    return s.groupby('season').week.max().to_dict()


def _shrunk_ratio(same: list, overall_mean: float) -> float | None:
    if not overall_mean or overall_mean <= 0:
        return None
    n = len(same)
    shrunk = (sum(same) + SPLIT_SHRINK * overall_mean) / (n + SPLIT_SHRINK)
    return shrunk / overall_mean


def player_signals(stats: pd.DataFrame, lengths: dict) -> pd.DataFrame:
    """One row per (player-game, metric) with the proxy line and every angle that fired."""
    stats = stats.sort_values(['season', 'week'])
    history = defaultdict(lambda: deque(maxlen=40))  # (player, metric) -> deque of (value, turf, indoor)
    teams = defaultdict(lambda: defaultdict(int))  # player -> team -> games, earlier seasons only
    this_season = defaultdict(lambda: defaultdict(int))
    season_total = defaultdict(float)  # (player, metric, season) -> total so far
    rows = []
    current_season = None
    for row in stats.itertuples():
        if row.season != current_season:
            for player, by_team in this_season.items():
                for team, n in by_team.items():
                    teams[player][team] += n
            this_season = defaultdict(lambda: defaultdict(int))
            current_season = row.season
        for metric, positions in METRICS.items():
            if row.position not in positions:
                continue
            value = getattr(row, metric)
            if pd.isna(value):
                continue
            past = history[(row.player_id, metric)]
            if len(past) >= MIN_GAMES:
                recent = [p[0] for p in list(past)[-WINDOW:]]
                line = float(np.median(recent)) + 0.5 if float(np.median(recent)).is_integer() else float(np.median(recent))
                overall = float(np.mean([p[0] for p in past]))
                angles = {}
                if not np.isnan(row.turf):
                    r = _shrunk_ratio([p[0] for p in past if p[1] == row.turf], overall)
                    if r and abs(r - 1) >= SPLIT_FLAG:
                        angles['venue: own split on ' + ('turf' if row.turf else 'grass')] = 1 if r > 1 else -1
                r = _shrunk_ratio([p[0] for p in past if p[2] == row.indoor], overall)
                if r and abs(r - 1) >= SPLIT_FLAG:
                    angles['venue: own split ' + ('indoors' if row.indoor else 'outdoors')] = 1 if r > 1 else -1
                if row.atDenver:
                    angles['venue: visiting player at Denver altitude'] = -1
                if row.denverVisits:
                    angles['control: player hosting Denver (same defense, no altitude)'] = -1
                goal = MILESTONES.get(metric)
                if goal and row.week >= lengths.get(row.season, 17) - 1:
                    so_far = season_total[(row.player_id, metric, row.season)]
                    if so_far < goal <= so_far + 1.5 * overall:
                        angles['milestone: within reach in the last two weeks'] = 1
                if teams[row.player_id].get(row.opponent_team, 0) >= REVENGE_GAMES and row.opponent_team != row.team:
                    angles['revenge: player against a former team'] = 1
                if row.thanksgiving:
                    angles['short week: Thanksgiving'] = -1
                elif row.thursday:
                    angles['short week: Thursday'] = -1
                rows.append({'season': row.season, 'week': row.week, 'player_id': row.player_id, 'metric': metric,
                             'line': line, 'actual': float(value), 'angles': angles})
            past.append((float(value), row.turf, row.indoor))
            season_total[(row.player_id, metric, row.season)] += float(value)
        this_season[row.player_id][row.team] += 1
    return pd.DataFrame(rows)


def kicker_rows(stats: pd.DataFrame) -> pd.DataFrame:
    k = stats[stats.position == 'K'].sort_values(['season', 'week'])
    k = k.assign(points=3 * k.fg_made.fillna(0) + k.pat_made.fillna(0))
    history = defaultdict(lambda: deque(maxlen=WINDOW))
    long_kicks = defaultdict(lambda: [0, 0])
    rows = []
    for row in k.itertuples():
        past = history[row.player_id]
        made, att = long_kicks[row.player_id]
        if len(past) >= MIN_GAMES:
            med = float(np.median(past))
            line = med + 0.5 if med.is_integer() else med
            rating = made / att if att >= 10 else None
            rows.append({'season': row.season, 'line': line, 'actual': row.points, 'bad': bool(row.badWeather),
                         'rating': rating})
        past.append(row.points)
        m = (row.fg_made_40_49 or 0) + (row.fg_made_50_59 or 0)
        x = (row.fg_missed_40_49 or 0) + (row.fg_missed_50_59 or 0)
        long_kicks[row.player_id][0] += 0 if pd.isna(m) else m
        long_kicks[row.player_id][1] += 0 if pd.isna(m + x) else m + x
    return pd.DataFrame(rows)


def _hit(actual, line, side):
    if actual == line:
        return None
    return 1.0 if (actual - line) * side > 0 else 0.0


def score_player_angles(signals: pd.DataFrame) -> dict:
    out = {}
    names = sorted({a for angles in signals.angles for a in angles})
    for period, (lo, hi) in (('find', FIND), ('check', CHECK)):
        part = signals[signals.season.between(lo, hi)]
        base = {1: np.nanmean([_hit(a, l, 1) for a, l in zip(part.actual, part.line)]),
                -1: np.nanmean([_hit(a, l, -1) for a, l in zip(part.actual, part.line)])}
        for name in names:
            hits, sides = [], []
            for r in part.itertuples():
                side = r.angles.get(name)
                if side:
                    h = _hit(r.actual, r.line, side)
                    if h is not None:
                        hits.append(h)
                        sides.append(side)
            if not hits:
                continue
            expected = float(np.mean([base[s] for s in sides]))
            boot = olb.bootstrap(np.array(hits) - np.array([base[s] for s in sides]))
            out.setdefault(name, {})[period] = {'bets': len(hits), 'hitRate': round(float(np.mean(hits)), 4),
                                                'baseHitRate': round(expected, 4), 'lift': boot}
    for name, v in out.items():
        f, c = v.get('find', {}).get('lift', {}), v.get('check', {}).get('lift', {})
        if f.get('low') is not None and c.get('low') is not None and f['low'] > 0 and c['low'] > 0:
            v['verdict'] = 'lift clearly above zero in both periods (proxy line)'
        elif f.get('mean') and c.get('mean') and f['mean'] > 0 and c['mean'] > 0:
            v['verdict'] = 'lead: lift above zero in both periods, not yet clear (proxy line)'
        else:
            v['verdict'] = 'no lift'
    return out


def score_kickers(rows: pd.DataFrame) -> dict:
    out = {}
    for period, (lo, hi) in (('find', FIND), ('check', CHECK)):
        part = rows[rows.season.between(lo, hi)]
        under = lambda df: [_hit(a, l, -1) for a, l in zip(df.actual, df.line)]
        base = float(np.nanmean(under(part)))
        groups = {
            'all kickers, bad weather': part[part.bad],
            'weaker kickers (under 75% from 40+), bad weather': part[part.bad & (part.rating < 0.75)],
            'stronger kickers (75%+ from 40+), bad weather': part[part.bad & (part.rating >= 0.75)],
        }
        for name, df in groups.items():
            hits = [h for h in under(df) if h is not None]
            out.setdefault(name, {})[period] = {
                'bets': len(hits), 'underHitRate': round(float(np.mean(hits)), 4) if hits else None,
                'baseUnderHitRate': round(base, 4),
                'lift': olb.bootstrap(np.array(hits) - base) if hits else None,
                'pointsVsLine': round(float((df.actual - df.line).mean()), 2) if len(df) else None,
            }
    return out


def against_2026_closes(signals: pd.DataFrame, closes: list[dict]) -> dict:
    """Angles that fired on a 2026 player-game with a real two-sided close: value at the fair close."""
    sig = {(r.player_id, r.metric, r.season, r.week): r.angles for r in signals.itertuples() if r.season == 2026}
    out = defaultdict(list)
    for c in closes:
        angles = sig.get((c['playerId'], c['metric'], c['season'], c['week']))
        if not angles or c.get('actual') is None or c.get('consensus') is None or c['actual'] == c['line']:
            continue
        for name, side in angles.items():
            p = c['consensus'] if side > 0 else 1 - c['consensus']
            hit = (c['actual'] - c['line']) * side > 0
            out[name].append((1.0 / p if hit else 0.0) - 1)
    return {name: olb.bootstrap(values) for name, values in sorted(out.items())}


def sticky_lines(stats: pd.DataFrame, closes: list[dict]) -> dict:
    """2026 weeks 2 -> 3: line moved under 3% while the opponent's allowance changed 10%+."""
    allowed = stats.groupby(['season', 'week', 'opponent_team'])[list(METRICS)].sum().reset_index()

    def allowance(season, week, defense, metric):
        prior = allowed[(allowed.season == season - 1) & (allowed.opponent_team == defense)][metric]
        now = allowed[(allowed.season == season) & (allowed.week < week) & (allowed.opponent_team == defense)][metric]
        if prior.empty and now.empty:
            return None
        base = prior.mean() if not prior.empty else now.mean()
        return (base * 4 + now.sum()) / (4 + len(now))

    by = {(c['playerId'], c['metric'], c['week']): c for c in closes}
    values, n_pairs, flagged = [], 0, []
    for (player, metric, week), now in by.items():
        before = by.get((player, metric, week - 1))
        if not before or now.get('actual') is None or now.get('consensus') is None or now['actual'] == now['line']:
            continue
        n_pairs += 1
        a_now = allowance(now['season'], week, now['opponent'], metric)
        a_before = allowance(before['season'], week - 1, before['opponent'], metric)
        if not a_now or not a_before:
            continue
        matchup = a_now / a_before - 1
        line_move = now['line'] / before['line'] - 1 if before['line'] else None
        if line_move is None or abs(line_move) > STICKY_LINE or abs(matchup) < STICKY_MATCHUP:
            continue
        side = 1 if matchup > 0 else -1
        p = now['consensus'] if side > 0 else 1 - now['consensus']
        hit = (now['actual'] - now['line']) * side > 0
        values.append((1.0 / p if hit else 0.0) - 1)
        flagged.append({'player': player, 'metric': metric, 'week': week, 'lineBefore': before['line'],
                        'lineNow': now['line'], 'matchupChange': round(matchup, 3), 'side': 'over' if side > 0 else 'under',
                        'hit': hit})
    return {'pairs': n_pairs, 'flags': len(values), 'valueAtFairClose': olb.bootstrap(values),
            'rule': f'line moved under {STICKY_LINE:.0%} week to week while the opponent allowance changed {STICKY_MATCHUP:.0%}+',
            'examples': flagged[:15]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--stats', default='model/.cache/stats')
    ap.add_argument('--schedule', default='model/.cache/games.csv')
    ap.add_argument('--closes', default='assets/prop-closes.json')
    ap.add_argument('--out', default='research/niche/player_angles.json')
    args = ap.parse_args()
    schedule = pd.read_csv(args.schedule, low_memory=False)
    stats = attach_games(load_stats(Path(args.stats), range(2012, 2027)), schedule)
    signals = player_signals(stats, season_lengths(schedule))
    closes = json.loads(Path(args.closes).read_text())['rows'] if Path(args.closes).exists() else []
    report = {
        'source': 'nflverse weekly player stats and schedules (CC BY 4.0); 2026 prop closes from the PropLine sample (CC BY 4.0)',
        'periods': {'find': list(FIND), 'check': list(CHECK)},
        'proxyLine': f'median of the player\'s previous {WINDOW} games (no free historical prop lines)',
        'playerGames': int(len(signals)),
        'angles': score_player_angles(signals),
        'kickers': score_kickers(kicker_rows(stats)),
        'against2026Closes': against_2026_closes(signals, closes),
        'stickyLines': sticky_lines(stats, closes),
    }
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(report, indent=1) + '\n')
    print(json.dumps({k: v.get('verdict') for k, v in report['angles'].items()}, indent=1))


if __name__ == '__main__':
    main()
