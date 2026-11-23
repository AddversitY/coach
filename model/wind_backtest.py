"""Do windy open-air games go under, and does the opener price the wind?

nflverse records game-day wind (mph) for open-air games. The Sportsbook
Reviews archive has opening and closing totals for 2007-2021. Game-day wind
was not known when the opener was posted, so betting the under at the opener
is an upper bound: it assumes a good forecast early in the week. Split:
2007-2014 to find the threshold, 2015-2021 to check it.

Output: research/weather/backtest.json. Nothing here is a pick.
"""

from __future__ import annotations

import argparse
import functools
import json
from pathlib import Path

import numpy as np
import pandas as pd

import opening_line_backtest as olb

THRESHOLDS = (10, 15, 20)


def run(schedule: pd.DataFrame, archive: Path) -> dict:
    odds = pd.concat([olb.parse_season(p, s) for s, p in olb.fetch_archive(archive).items()])
    odds = olb.attach_game_ids(odds, schedule)
    g = schedule.merge(odds[['game_id', 'openTotal', 'closeTotal']], on='game_id')
    g = g[(g.game_type == 'REG') & g.roof.isin(['outdoors', 'open']) & g.openTotal.notna()
          & g.closeTotal.notna() & g.wind.notna() & g.total.notna()]
    residuals = functools.lru_cache(maxsize=None)(lambda season: olb.residual_table(schedule, season)[1])
    out = {}
    for label, part in (('find 2007-2014', g[g.season <= 2014]), ('check 2015-2021', g[g.season >= 2015])):
        rows = {}
        for lo in THRESHOLDS:
            s = part[part.wind >= lo]
            clv = [olb.win_chance(residuals(r.season - 1), r.openTotal - r.closeTotal, -1) * olb.PAYOUT - 1 for r in s.itertuples()]
            atopen = [(olb.PAYOUT - 1 if r.total < r.openTotal else -1.0) for r in s.itertuples() if r.total != r.openTotal]
            atclose = [(olb.PAYOUT - 1 if r.total < r.closeTotal else -1.0) for r in s.itertuples() if r.total != r.closeTotal]
            rows[f'wind{lo}+'] = {
                'games': int(len(s)),
                'totalMovePoints': round(float((s.closeTotal - s.openTotal).mean()), 2),
                'underAtOpenerClv': olb.bootstrap(clv),
                'underAtOpenerProfit': olb.bootstrap(atopen),
                'underAtCloseProfit': olb.bootstrap(atclose),
            }
        out[label] = rows
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--schedule', default='model/.cache/games.csv')
    ap.add_argument('--archive', default='model/.cache/sbr')
    ap.add_argument('--out', default='research/weather/backtest.json')
    args = ap.parse_args()
    schedule = pd.read_csv(args.schedule, low_memory=False)
    report = {'source': 'nflverse game-day wind (CC BY 4.0); Sportsbook Reviews Online opening and closing totals',
              **run(schedule, Path(args.archive))}
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(report, indent=1) + '\n')
    print(json.dumps(report, indent=1))


if __name__ == '__main__':
    main()
