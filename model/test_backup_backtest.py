import unittest

import numpy as np
import pandas as pd

import backup_backtest as bb


class BackupBacktestTests(unittest.TestCase):
    def test_inherited_share_is_fit_from_the_change_in_share(self):
        rows = []
        for i in range(40):
            out = 0.2 + 0.005 * i
            prior = 0.05
            rows.append({'group': 'WR', 'out_targets': out, 'prior_targets_share': prior,
                         'targets_share': prior + 0.4 * out})
        fit = bb.fit_inherit(pd.DataFrame(rows).assign(
            out_carries=0, prior_carries_share=0, carries_share=0,
            out_attempts=0, prior_attempts_share=0, attempts_share=0))
        self.assertAlmostEqual(fit['WR:targets'], 0.4, places=3)
        self.assertEqual(fit['QB:attempts'], 0.5)  # Too few events: the default.

    def test_projection_uses_volume_share_and_shrunk_efficiency(self):
        row = {'group': 'WR', 'prior_targets_share': 0.1, 'out_targets': 0.3, 'team_targets': 30,
               'cum_receiving_yards_targets': 0, 'cum_targets_for_receiving_yards': 0,
               'cum_receptions_targets': 0, 'cum_targets_for_receptions': 0}
        means = {'WR': {'receiving_yards/targets': 8.0, 'receptions/targets': 0.6}}
        out = bb.project(row, {'WR:targets': 0.5}, means)
        self.assertAlmostEqual(out['targets'], 7.5)
        self.assertAlmostEqual(out['receiving_yards'], 60.0)
        self.assertAlmostEqual(out['receptions'], 4.5)

    def test_over_chance_follows_the_ratio_spread(self):
        q = list(np.quantile(np.linspace(0, 2, 1001), bb.QUANTILES))
        self.assertAlmostEqual(bb.over_chance(50, 50, q), 0.5, places=2)
        self.assertGreater(bb.over_chance(50, 25, q), 0.7)
        self.assertLess(bb.over_chance(50, 90, q), 0.1)


if __name__ == '__main__':
    unittest.main()
