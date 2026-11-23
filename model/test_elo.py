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


class SkillTest(unittest.TestCase):
    def test_features_use_only_earlier_games(self):
        import elo_skill as sk
        cols = sorted({c for n, d, _ in sk.RATES.values() for c in (n, d) if c} - {"routes"})
        rows = []
        for week, yards in ((1, 10.0), (2, 200.0), (3, 0.0)):
            row = {c: 0.0 for c in cols}
            row.update({"player": "p", "game_id": f"g{week}", "season": 2024, "week": week, "posteam": "AAA",
                        "defteam": "BBB", "rec_yds": yards, "targets": 5.0, "team_db": 30.0, "snap_pct": 1.0})
            for c in sk.NGS:
                row[c] = np.nan
            rows.append(row)
        f = sk.decayed_features(pd.DataFrame(rows))
        self.assertEqual(f.loc[0, "ypt_raw"], 0.0)          # nothing known before week 1
        self.assertAlmostEqual(f.loc[1, "ypt_raw"], 10.0)    # week 2 sees only week 1
        self.assertGreater(f.loc[2, "ypt_raw"], 200.0)       # week 3 sees weeks 1-2, not week 3

    def test_percentile_scale(self):
        import elo_skill as sk
        v = pd.Series([1.0, 2.0, 3.0, 4.0])
        grp = pd.Series(["WR"] * 4)
        self.assertEqual(list(sk.percentile_40_99(v, grp)), [55.0, 70.0, 84.0, 99.0])
        self.assertEqual(list(sk.percentile_40_99(v, grp, higher=False)), [99.0, 84.0, 70.0, 55.0])


class TrenchTest(unittest.TestCase):
    def test_good_blockers_and_rushers_rate_positive(self):
        from elo_trenches import TrenchRatings
        tr = TrenchRatings()
        good_ol = {"ol": [("ol_good", 1.0)], "qb": [("qb_a", 1.0)]}
        bad_ol = {"ol": [("ol_bad", 1.0)], "qb": [("qb_b", 1.0)]}
        for week in range(1, 9):
            # Few sacks+hits on the good line, many against the bad line, same rusher.
            tr.update(good_ol, [("rusher", 1.0)], "pass_pro", 1, 40, 2024, week)
            tr.update(bad_ol, [("rusher", 1.0)], "pass_pro", 12, 40, 2024, week)
        book = tr.books[("ol", "pass_pro")]
        self.assertGreater(book.get("ol_good", 2024, 9)[0], 0)
        self.assertLess(book.get("ol_bad", 2024, 9)[0], 0)


class AngleTest(unittest.TestCase):
    def test_pregame_walk_uses_only_earlier_weeks(self):
        import elo_angles as ea
        obs = pd.DataFrame({"season": [2024, 2024, 2024], "week": [1, 2, 3], "key": [("AAA", "o", "red")] * 3,
                            "s": [10.0, 10.0, -50.0], "n": [10.0, 10.0, 10.0]})
        obs = pd.concat([obs, pd.DataFrame({"season": [2024] * 3, "week": [1, 2, 3], "key": [("BBB", "o", "red")] * 3,
                                            "s": [0.0, 0.0, 0.0], "n": [10.0, 10.0, 10.0]})], ignore_index=True)
        q = pd.DataFrame({"season": [2024, 2024, 2024], "week": [1, 3, 4], "key": [("AAA", "o", "red")] * 3})
        v = ea.pregame_walk(obs, q, k=5)
        self.assertEqual(v[0], 0.0)          # nothing known before week 1
        self.assertGreater(v[1], 0.0)        # weeks 1-2 were good, week 3 not yet seen
        self.assertLess(v[2], v[1])          # week 3's bad game counts by week 4

    def test_priors_are_per_kind(self):
        import elo_angles as ea
        self.assertEqual(ea._group(("AAA", "o", "deep")), ("o", "deep"))
        self.assertEqual(ea._group(("qb", "x")), "qb")
        self.assertEqual(ea._group(("pair", "q", "r")), "all")

    def test_travel_and_body_clock(self):
        import elo_angles as ea
        self.assertAlmostEqual(ea.miles(ea.TEAM_SITE["NYG"], ea.TEAM_SITE["NYJ"]), 0.0)
        self.assertGreater(ea.miles(ea.TEAM_SITE["SEA"], ea.TEAM_SITE["MIA"]), 2500)
        g = pd.DataFrame([{"game_id": "2024_05_SEA_NYG", "home_team": "NYG", "away_team": "SEA", "stadium_id": "NYC01",
                           "location": "Home", "gametime": "13:00", "home_rest": 7, "away_rest": 4}])
        t = ea.travel_rows(g).iloc[0]
        self.assertEqual(t.away_early, 1.0)   # 10 AM on a West Coast body clock
        self.assertEqual(t.home_early, 0.0)
        self.assertEqual(t.away_tz, 3)
        london = pd.DataFrame([{"game_id": "x", "home_team": "JAX", "away_team": "BUF", "stadium_id": "LON02",
                                "location": "Neutral", "gametime": "09:30", "home_rest": 7, "away_rest": 7}])
        self.assertGreater(ea.travel_rows(london).iloc[0].home_miles, 3000)
