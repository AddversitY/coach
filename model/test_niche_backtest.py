import unittest
from types import SimpleNamespace

import niche_backtest as nb


def game(**extra):
    base = dict(surface='grass', roof='outdoors', home_team='DEN', away_team='KC', location='Home', temp=20.0,
                weekday='Thursday', week=12, gameday='2015-11-26', home_rest=4, away_rest=4)
    base.update(extra)
    return SimpleNamespace(**base)


class NicheBacktestTests(unittest.TestCase):
    def test_game_angles(self):
        names = {a[0]: a[2] for a in nb.game_angles(game(), None, {'qb': -1, 'coach': 0}, False, True)}
        self.assertEqual(names['venue: Denver altitude, Denver side'], 1)
        self.assertEqual(names['venue: freezing (32F or colder), under'], -1)
        self.assertEqual(names['venue: dome team outdoors in the cold, home side'], 1)
        self.assertEqual(names['short week: Thanksgiving, under'], -1)
        self.assertEqual(names['revenge: quarterback against his former team, his side'], -1)
        self.assertNotIn('venue: artificial turf, over', names)

    def test_missing_surface_is_not_turf(self):
        names = {a[0] for a in nb.game_angles(game(surface=float('nan'), temp=float('nan')), None, {}, False, False)}
        self.assertNotIn('venue: artificial turf, over', names)
        self.assertNotIn('venue: freezing (32F or colder), under', names)

    def test_late_season(self):
        standing = {'DEN': (12, 3, 0, 1, 16), 'KC': (4, 11, 0, 1, 16)}
        names = {a[0]: a[2] for a in nb.game_angles(game(weekday='Sunday'), standing, {}, False, False)}
        self.assertEqual(names['late season: team out of the race (approx.), its side'], -1)
        self.assertEqual(names['late season: final week, team that may rest starters, its side'], 1)

    def test_verdict(self):
        clv = lambda mean, low: {'clv': {'n': 50, 'mean': mean, 'low': low}}
        self.assertTrue(nb.verdict(clv(0.02, 0.01), clv(0.01, 0.001)).startswith('edge'))
        self.assertTrue(nb.verdict(clv(0.02, -0.01), clv(0.01, -0.02)).startswith('lead'))
        self.assertEqual(nb.verdict(clv(0.02, 0.01), clv(-0.01, -0.02)), 'no edge')


if __name__ == '__main__':
    unittest.main()
