"""How much do same-game player props move together?

A same-game parlay is priced as one bet. If a book multiplied the legs as if
they were independent, a pair that tends to hit together would pay too much.
This measures the "lift" of common pairs: the chance both legs hit divided by
the product of the two chances. Lift above 1 means the legs move together.

Two samples:
1. nflverse box scores 2023-2026 (assets/nfl-player-stats.json), with each
   player's line set to the average of his previous 8 games (at least 4), so
   about half of the overs hit. Large sample; the line is a stand-in.
2. The PropLine sample (real closing lines from Pinnacle or the consensus,
   32 games, Sep 2026). Small sample; real lines.

No free source has same-game parlay prices, so whether any book underprices a
pair cannot be checked here. The lift is the size of the edge a pair would
carry against a book that ignored the correlation.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

STATS = {'pass': 'passing_yards', 'rush': 'rushing_yards', 'rec': 'receiving_yards'}
SEED = 20261123


def load_stats(path: Path) -> pd.DataFrame:
    data = json.loads(path.read_text())
    keys = data['statKeys']
    rows = []
    for row in data['rows']:
        if row.get('seasonType') != 'REG':
            continue
        stats = dict(zip(keys, row['stats']))
        rows.append({
            'player': row['playerId'], 'name': row['name'], 'pos': row['position'], 'team': row['team'],
            'opp': row['opponent'], 'season': row['season'], 'week': row['week'],
            'pass': stats.get('passing_yards') or 0, 'rush': stats.get('rushing_yards') or 0,
            'rec': stats.get('receiving_yards') or 0, 'targets': stats.get('targets') or 0,
            'attempts': stats.get('attempts') or 0, 'carries': stats.get('carries') or 0,
        })
    df = pd.DataFrame(rows).sort_values(['player', 'season', 'week'])
    for stat in ('pass', 'rush', 'rec', 'targets', 'attempts', 'carries'):
        prior = df.groupby('player')[stat].transform(lambda s: s.shift(1).rolling(8, min_periods=4).mean())
        df[stat + '_line'] = prior
    return df


def roles(df: pd.DataFrame) -> pd.DataFrame:
    """Pick each team-game's QB, RB1, WR1, WR2 and TE1 from earlier games only."""
    df = df.copy()
    df['key'] = list(zip(df.season, df.week, df.team))
    picks = []
    for key, g in df.groupby('key'):
        qb = g[(g.pos == 'QB') & g.attempts_line.notna()].sort_values('attempts_line', ascending=False).head(1)
        rb = g[(g.pos == 'RB') & g.carries_line.notna()].sort_values('carries_line', ascending=False).head(1)
        wr = g[(g.pos == 'WR') & g.targets_line.notna()].sort_values('targets_line', ascending=False).head(2)
        te = g[(g.pos == 'TE') & g.targets_line.notna()].sort_values('targets_line', ascending=False).head(1)
        row = {'season': key[0], 'week': key[1], 'team': key[2], 'opp': g.opp.iloc[0]}
        for label, frame, stat in (('QB', qb, 'pass'), ('RB1', rb, 'rush'), ('TE1', te, 'rec')):
            if len(frame) and frame[stat + '_line'].iloc[0] > 0:
                row[label] = int(frame[stat].iloc[0] > frame[stat + '_line'].iloc[0])
        for i, label in enumerate(('WR1', 'WR2')):
            if len(wr) > i and wr['rec_line'].iloc[i] > 0:
                row[label] = int(wr['rec'].iloc[i] > wr['rec_line'].iloc[i])
        picks.append(row)
    return pd.DataFrame(picks)


PAIRS = [
    ('QB over + WR1 over', 'QB', 1, 'WR1', 1, False),
    ('QB over + WR2 over', 'QB', 1, 'WR2', 1, False),
    ('QB over + TE1 over', 'QB', 1, 'TE1', 1, False),
    ('WR1 over + WR2 over', 'WR1', 1, 'WR2', 1, False),
    ('QB under + RB1 over', 'QB', 0, 'RB1', 1, False),
    ('QB over + RB1 over', 'QB', 1, 'RB1', 1, False),
    ('QB over + other QB over', 'QB', 1, 'QB', 1, True),
    ('WR1 over + other QB over', 'WR1', 1, 'QB', 1, True),
    ('RB1 over + other QB under', 'RB1', 1, 'QB', 0, True),
]


def lift_table(picks: pd.DataFrame, rounds=1000) -> list[dict]:
    opp = picks.rename(columns={c: 'opp_' + c for c in ('QB', 'RB1', 'WR1', 'WR2', 'TE1')})
    opp = opp.rename(columns={'team': 'opp_team_', 'opp': 'team'}).rename(columns={'opp_team_': 'opp'})
    both = picks.merge(opp[['season', 'week', 'team', 'opp_QB', 'opp_RB1', 'opp_WR1']], on=['season', 'week', 'team'], how='left')
    rng = np.random.default_rng(SEED)
    out = []
    for label, a, va, b, vb, other in PAIRS:
        col_b = 'opp_' + b if other else b
        s = both[[a, col_b]].dropna()
        x = (s[a].values == va).astype(float)
        y = (s[col_b].values == vb).astype(float)
        if len(s) < 50:
            continue
        joint = (x * y).mean()
        lift = joint / (x.mean() * y.mean())
        idx = rng.integers(0, len(s), size=(rounds, len(s)))
        boots = (x[idx] * y[idx]).mean(1) / (x[idx].mean(1) * y[idx].mean(1))
        out.append({
            'pair': label, 'games': int(len(s)),
            'legA': round(float(x.mean()), 3), 'legB': round(float(y.mean()), 3),
            'both': round(float(joint), 3), 'lift': round(float(lift), 3),
            'liftRange90': [round(float(np.percentile(boots, 5)), 3), round(float(np.percentile(boots, 95)), 3)],
        })
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--stats', default='assets/nfl-player-stats.json')
    ap.add_argument('--out', default='research/sgp-correlation/lift.json')
    args = ap.parse_args()
    picks = roles(load_stats(Path(args.stats)))
    table = lift_table(picks)
    report = {
        'source': 'nflverse player stats 2023-2026 (CC BY 4.0); line = average of the previous 8 games',
        'teamGames': int(len(picks)),
        'pairs': table,
        'note': ('Lift = chance both legs hit / (chance A x chance B). A two-leg parlay priced as if '
                 'independent has expected value of about lift - 1 at fair leg prices. No free source '
                 'has same-game parlay prices, so no book is shown to misprice these pairs.'),
    }
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(report, indent=1) + '\n')
    for row in table:
        print(row)


if __name__ == '__main__':
    main()
