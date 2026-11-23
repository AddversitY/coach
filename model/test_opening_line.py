import unittest

import numpy as np
import pandas as pd

from opening_line_backtest import qb_known_at_open, win_chance, _num


class OpeningLineTests(unittest.TestCase):
    def test_quarterback_is_the_previous_starter(self):
        games = pd.DataFrame([
            {'season': 2020, 'week': 1, 'home_team': 'AAA', 'away_team': 'BBB', 'home_qb_id': 'a1', 'away_qb_id': 'b1'},
            {'season': 2020, 'week': 2, 'home_team': 'BBB', 'away_team': 'AAA', 'home_qb_id': 'b2', 'away_qb_id': 'a1'},
            {'season': 2020, 'week': 3, 'home_team': 'AAA', 'away_team': 'BBB', 'home_qb_id': 'a1', 'away_qb_id': 'b2'},
        ])
        lagged = qb_known_at_open(games)
        self.assertFalse(isinstance(lagged.iloc[0].home_qb_id, str))
        # Week 2: BBB's backup started, but the opener only knew b1.
        self.assertEqual(lagged.iloc[1].home_qb_id, 'b1')
        self.assertEqual(lagged.iloc[2].away_qb_id, 'b2')

    def test_win_chance_drops_pushes(self):
        residuals = np.array([-3, -3, 0, 3, 3, 3, 7])
        self.assertAlmostEqual(win_chance(residuals, 0, 1), 4 / 6)
        self.assertAlmostEqual(win_chance(residuals, 0, -1), 2 / 6)
        # Getting a better number than the close helps: home at -2.5 when it closed -3.
        self.assertGreater(win_chance(residuals, -0.5, 1), win_chance(residuals, 0, 1))

    def test_archive_numbers(self):
        self.assertEqual(_num('pk'), 0.0)
        self.assertEqual(_num('47.5'), 47.5)
        self.assertIsNone(_num('NL'))


if __name__ == '__main__':
    unittest.main()
