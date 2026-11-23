import unittest

import numpy as np
import pandas as pd

from elo_backtest import logistic_fit, logistic_predict, ridge_fit, ridge_predict
from elo_props import over_chance
from elo_ratings import Params, RatingBook, kalman_update, run_team_ratings


def tiny_schedule():
    rows = []
    teams = ["AAA", "BBB", "CCC", "DDD"]
    for season in (2020, 2021):
        for week in range(1, 5):
            for i in range(0, 4, 2):
                h, a = teams[(i + week) % 4], teams[(i + week + 1) % 4]
                rows.append({"game_id": f"{season}_{week:02d}_{a}_{h}", "season": season, "week": week,
                             "gameday": f"{season}-09-{week + 10}", "home_team": h, "away_team": a,
                             "home_score": 24, "away_score": 17, "result": 7, "total": 41, "location": "Home",
                             "home_qb_id": f"qb{h}", "away_qb_id": f"qb{a}", "home_rest": 7, "away_rest": 7,
                             "div_game": 0, "roof": "outdoors", "temp": 60, "wind": 5, "spread_line": 3.0,
                             "total_line": 44.0, "home_moneyline": -150, "away_moneyline": 130})
    return pd.DataFrame(rows)


def tiny_team_games(games, strong="AAA"):
    rows = []
    for g in games.itertuples():
        for t in (g.home_team, g.away_team):
            good = t == strong
            rows.append({"game_id": g.game_id, "team": t, "pass_epa": 30.0 * (0.3 if good else 0.0), "pass_n": 30,
                         "run_epa": 0.0, "run_n": 25, "passer": f"qb{t}", "st_epa": 0.0})
    return pd.DataFrame(rows)


class KalmanTest(unittest.TestCase):
    def test_update_moves_toward_observation_and_shrinks_variance(self):
        a, b = RatingBook(0.01, 0.0, 1.0), RatingBook(0.04, 0.0, 1.0)
        kalman_update([(a, "x", 1), (b, "y", 1)], 1.0, 0.0, 0.05, 2020, 1)
        ma, va = a.mean["x"], a.var["x"]
        mb, vb = b.mean["y"], b.var["y"]
        self.assertGreater(ma, 0)
        self.assertGreater(mb, ma)  # the less certain rating moves more
        self.assertLess(va, 0.01)
        self.assertAlmostEqual(ma / mb, 0.25, places=6)

    def test_opponent_sign(self):
        off, de = RatingBook(0.01, 0.0, 1.0), RatingBook(0.01, 0.0, 1.0)
        kalman_update([(off, "o", 1), (de, "d", -1)], 1.0, 0.0, 0.1, 2020, 1)
        self.assertGreater(off.mean["o"], 0)
        self.assertLess(de.mean["d"], 0)

    def test_season_regression(self):
        book = RatingBook(0.01, 0.0, 0.5)
        book.set("x", 2020, 1, 0.2, 0.001)
        m, v = book.get("x", 2021, 30)
        self.assertAlmostEqual(m, 0.1)
        self.assertGreater(v, 0.001)
        self.assertLessEqual(v, 0.01)


class NoLookaheadTest(unittest.TestCase):
    def test_week_features_ignore_that_week(self):
        games = tiny_schedule()
        tg = tiny_team_games(games)
        base, _ = run_team_ratings(games, tg, Params())
        changed = games.copy()
        target = changed.index[(changed.season == 2021) & (changed.week == 3)][0]
        changed.loc[target, ["home_score", "result"]] = [60, 43]
        after, _ = run_team_ratings(changed, tg, Params())
        cols = ["f_pass", "f_run", "f_pts", "f_qb"]
        same = base[(base.season < 2021) | (base.week <= 3)]
        np.testing.assert_allclose(same[cols].values, after.loc[same.index, cols].values)
        later = base.index[(base.season == 2021) & (base.week == 4)]
        self.assertFalse(np.allclose(base.loc[later, "f_pts"], after.loc[later, "f_pts"]))

    def test_strong_team_rates_higher(self):
        games = tiny_schedule()
        _, tr = run_team_ratings(games, tiny_team_games(games), Params())
        cast = {t: tr.cast.get(t, 2021, 0)[0] + tr.qb.get(f"qb{t}", 2021, 0)[0] for t in ("AAA", "BBB", "CCC", "DDD")}
        self.assertEqual(max(cast, key=cast.get), "AAA")


class FitTest(unittest.TestCase):
    def test_ridge_recovers_line(self):
        rng = np.random.default_rng(1)
        x = rng.normal(size=(500, 2))
        y = 3 + 2 * x[:, 0] - x[:, 1] + rng.normal(scale=0.1, size=500)
        beta = ridge_fit(x, y, lam=0.0)
        np.testing.assert_allclose(beta, [3, 2, -1], atol=0.05)
        self.assertAlmostEqual(float(ridge_predict(beta, np.array([[0.0, 0.0]]))[0]), 3, delta=0.05)

    def test_logistic_is_calibrated_on_coin(self):
        rng = np.random.default_rng(2)
        x = rng.normal(size=(2000, 1))
        y = (rng.random(2000) < 0.5).astype(float)
        p = logistic_predict(logistic_fit(x, y), x)
        self.assertLess(abs(p.mean() - 0.5), 0.03)

    def test_over_chance_falls_as_line_rises(self):
        rng = np.random.default_rng(3)
        hp = rng.uniform(20, 80, 3000)
        ha = hp * rng.gamma(4, 0.25, 3000)
        lo, hi = over_chance(50, 30.5, hp, ha), over_chance(50, 70.5, hp, ha)
        self.assertGreater(lo, 0.5)
        self.assertLess(hi, 0.5)
        self.assertTrue(0 < hi < lo < 1)


if __name__ == "__main__":
    unittest.main()
