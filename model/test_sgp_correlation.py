import unittest

import pandas as pd

from sgp_correlation import lift_table


class SgpCorrelationTests(unittest.TestCase):
    def test_lift_is_one_for_independent_and_above_one_for_stacked(self):
        rows = []
        for i in range(400):
            qb = i % 2
            rows.append({'season': 2025, 'week': i, 'team': 'AAA', 'opp': 'BBB', 'QB': qb, 'WR1': qb,
                         'WR2': (i // 2) % 2, 'TE1': qb, 'RB1': (i // 4) % 2})
            rows.append({'season': 2025, 'week': i, 'team': 'BBB', 'opp': 'AAA', 'QB': (i // 2) % 2, 'WR1': 0,
                         'WR2': 1, 'TE1': 0, 'RB1': 1})
        table = {row['pair']: row for row in lift_table(pd.DataFrame(rows), rounds=50)}
        self.assertAlmostEqual(table['QB over + WR1 over']['lift'], 2.0)
        self.assertAlmostEqual(table['QB over + WR2 over']['lift'], 1.0)


if __name__ == '__main__':
    unittest.main()
