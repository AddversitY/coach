"""How much do lines move when a key starter is ruled out, and does practice news matter?

Free data only:
- nflverse injury reports 2012-2021 (final game status and the last practice
  status of the week) and snap counts (who is a starter).
- Sportsbook Reviews Online opening and closing spreads (opening_line_backtest).

For each position group it measures, over games where a starter of that group
was ruled out (Out or Doubtful) on the final report:
- how far the spread moved from open to close against his team (points);
- closing line value of betting the other team at the opener. This is an upper
  bound: it assumes the news was seen before the line moved.
Sizes are fit on 2012-2016 and checked on 2017-2021 (out of sample).

It also measures how often a Questionable starter actually played, by his last
practice status (Full, Limited, Did not practice).

Output: research/news/backtest.json. Nothing here is a pick.
"""

from __future__ import annotations

import argparse
import json
import re
import urllib.request
from pathlib import Path

import numpy as np
import pandas as pd

import functools

import opening_line_backtest as olb
from opening_line_backtest import PAYOUT, attach_game_ids, bootstrap, fetch_archive, parse_season, win_chance

BASE = 'https://github.com/nflverse/nflverse-data/releases/download'
SEASONS = range(2012, 2022)
TRAIN = range(2012, 2017)
GROUPS = {
    'QB': ('QB',), 'RB': ('RB', 'FB'), 'WR': ('WR',), 'TE': ('TE',), 'OL': ('T', 'G', 'C', 'OT', 'OG', 'OL'),
    'DL': ('DE', 'DT', 'NT', 'DL'), 'LB': ('LB', 'ILB', 'OLB', 'MLB'), 'CB': ('CB', 'DB'), 'S': ('S', 'SS', 'FS'),
}
OUT = {'Out', 'Doubtful'}
STARTER_SHARE = 0.70


def fetch(kind: str, season: int, cache: Path) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / f'{kind}_{season}.csv'
    if not path.exists():
        url = f'{BASE}/{kind}/{kind}_{season}.csv'
        path.write_bytes(urllib.request.urlopen(url, timeout=120).read())
    return path


def norm(name) -> str:
    text = re.sub(r'\b(jr|sr|ii|iii|iv|v)\b\.?', '', str(name).lower())
    return re.sub(r'[^a-z]', '', text)


def group_of(position) -> str | None:
    for group, codes in GROUPS.items():
        if str(position) in codes:
            return group
    return None


def starters(snaps: pd.DataFrame) -> pd.DataFrame:
    """Each player's share of snaps over his previous three games, and his rank in his group."""
    s = snaps[snaps.game_type == 'REG'].copy()
    s['share'] = np.maximum(s.offense_pct.fillna(0), s.defense_pct.fillna(0))
    s['group'] = s.position.map(group_of)
    s = s[s.group.notna()].sort_values(['season', 'week'])
    s['key'] = s.player.map(norm)
    s['prior'] = s.groupby(['season', 'team', 'key']).share.transform(lambda x: x.shift(1).rolling(3, min_periods=2).mean())
    return s


def build(cache: Path, schedule: pd.DataFrame, archive: Path):
    inj = pd.concat([pd.read_csv(fetch('injuries', y, cache)) for y in SEASONS])
    snaps = pd.concat([pd.read_csv(fetch('snap_counts', y, cache)) for y in SEASONS])
    st = starters(snaps)
    played = st[['season', 'week', 'team', 'key', 'share']]
    # Previous-weeks share for every player who appears on a report; a player who missed
    # the game has no snap row that week, so carry his last known prior forward.
    last_prior = st.dropna(subset=['prior']).groupby(['season', 'team', 'key']).apply(
        lambda g: g[['week', 'prior', 'group']].values.tolist(), include_groups=False).to_dict()

    inj = inj[(inj.game_type == 'REG') & inj.report_status.notna()].copy()
    inj['key'] = inj.full_name.map(norm)
    inj['group'] = inj.position.map(group_of)
    rows = []
    for r in inj.itertuples():
        history = last_prior.get((r.season, r.team, r.key))
        if not history:
            continue
        before = [h for h in history if h[0] <= r.week]
        if not before:
            continue
        prior = before[-1][1]
        if prior < STARTER_SHARE:
            continue
        rows.append({'season': r.season, 'week': r.week, 'team': r.team, 'key': r.key, 'group': before[-1][2],
                     'status': r.report_status, 'practice': str(r.practice_status or ''), 'prior': prior})
    reports = pd.DataFrame(rows)
    reports = reports.merge(played, on=['season', 'week', 'team', 'key'], how='left')
    reports['played'] = reports.share.fillna(0) > 0

    odds = pd.concat([parse_season(path, season) for season, path in fetch_archive(archive).items()])
    odds = attach_game_ids(odds, schedule)
    games = schedule[(schedule.game_type == 'REG') & schedule.season.between(2012, 2021)][
        ['game_id', 'season', 'week', 'home_team', 'away_team', 'result']].merge(
        odds[['game_id', 'openMargin', 'closeMargin']], on='game_id').dropna(subset=['openMargin', 'closeMargin'])
    return reports, games


def practice_label(text: str) -> str:
    t = text.lower()
    if 'did not' in t or t.startswith('out'):
        return 'did not practice'
    if 'limited' in t:
        return 'limited'
    if 'full' in t:
        return 'full'
    return 'unknown'


def team_out(reports: pd.DataFrame) -> dict:
    """{(season, week, team): set of groups with a starter ruled out}."""
    out = {}
    for r in reports[reports.status.isin(OUT)].itertuples():
        out.setdefault((r.season, r.week, r.team), set()).add(r.group)
    return out


def score(reports, games, schedule):
    residual_table = functools.lru_cache(maxsize=None)(lambda season: olb.residual_table(schedule, season))
    outs = team_out(reports)
    result = {'groups': {}}
    for group in GROUPS:
        records = []
        for g in games.itertuples():
            for team, sign in ((g.home_team, 1), (g.away_team, -1)):
                groups = outs.get((g.season, g.week, team), set())
                if group not in groups:
                    continue
                if group != 'QB' and 'QB' in groups:
                    continue  # Keep quarterback moves out of other groups.
                # Move against the injured team, in points (+ = toward the opponent).
                move = (g.openMargin - g.closeMargin) * sign
                side = -sign  # bet the opponent: +1 home, -1 away
                res, _ = residual_table(g.season - 1)
                p = win_chance(res, g.openMargin - g.closeMargin, side)
                records.append({'season': g.season, 'move': move, 'clv': None if p is None else p * PAYOUT - 1})
        if not records:
            continue
        df = pd.DataFrame(records)
        train, test = df[df.season.isin(TRAIN)], df[~df.season.isin(TRAIN)]
        result['groups'][group] = {
            'games': int(len(df)),
            'movePointsTrain': round(float(train.move.mean()), 2) if len(train) else None,
            'movePointsTest': round(float(test.move.mean()), 2) if len(test) else None,
            'clvAtOpenerTrain': bootstrap(train.clv.values),
            'clvAtOpenerTest': bootstrap(test.clv.values),
        }
    # Baseline: every team-game, same sign convention, no injury.
    base = []
    for g in games.itertuples():
        base.append(abs(g.openMargin - g.closeMargin))
    result['averageAbsoluteMovePoints'] = round(float(np.mean(base)), 2)
    # Questionable starters: did they play, by last practice status?
    q = reports[reports.status == 'Questionable'].copy()
    q['practiceLabel'] = q.practice.map(practice_label)
    table = {}
    rate = lambda frame: round(float(frame.played.mean()), 3) if len(frame) else None
    for label, s in q.groupby('practiceLabel'):
        if label == 'unknown':
            continue
        table[label] = {'starters': int(len(s)), 'played': rate(s),
                        'playedTrain': rate(s[s.season.isin(TRAIN)]),
                        'playedTest': rate(s[~s.season.isin(TRAIN)])}
    result['questionableByPractice'] = table
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cache', default='model/.cache/news')
    ap.add_argument('--schedule', default='model/.cache/games.csv')
    ap.add_argument('--archive', default='model/.cache/sbr')
    ap.add_argument('--out', default='research/news/backtest.json')
    args = ap.parse_args()
    schedule = pd.read_csv(args.schedule, low_memory=False)
    reports, games = build(Path(args.cache), schedule, Path(args.archive))
    report = {
        'source': 'nflverse injuries and snap counts 2012-2021 (CC BY 4.0); Sportsbook Reviews Online opening and closing spreads',
        'starter': f'at least {int(STARTER_SHARE * 100)}% of snaps over his previous games',
        'train': [2012, 2016], 'test': [2017, 2021],
        'gamesWithOdds': int(len(games)),
        **score(reports, games, schedule),
    }
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(report, indent=1) + '\n')
    print(json.dumps(report, indent=1))


if __name__ == '__main__':
    main()
