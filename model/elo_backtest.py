"""Out-of-sample test of the Coach ratings against the closing line.

Week-based walk-forward: to score week W, every fit uses only games from
before week W. Ratings themselves only ever see earlier weeks.

Questions asked, per season:
1. Ratings alone: is the predicted margin/total closer to the final score
   than the closing line is?
2. Ratings + market: does adding the ratings to the closing line improve
   the chance of a cover, an over, or a win (Brier and log loss)?
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
import pandas as pd

from elo_data import load_games, load_plays
from elo_ratings import Params, no_vig_home, run_team_ratings, team_game_table

MARGIN_FEATURES = ["f_pass", "f_run", "f_st", "f_pts", "f_qb", "home", "f_rest"]
TOTAL_FEATURES = ["f_pass_sum", "f_run_sum", "dome", "wind", "temp"]
FIRST_FIT_SEASON = 2007
RIDGE = 5.0


def ridge_fit(x: np.ndarray, y: np.ndarray, lam: float = RIDGE) -> np.ndarray:
    x1 = np.column_stack([np.ones(len(x)), x])
    mu, sd = x1.mean(0), x1.std(0)
    mu[0], sd[0] = 0.0, 1.0
    sd[sd == 0] = 1.0
    z = (x1 - mu) / sd
    reg = lam * np.eye(z.shape[1])
    reg[0, 0] = 0.0
    beta = np.linalg.solve(z.T @ z + reg, z.T @ y)
    return beta / sd - np.r_[(beta[1:] * mu[1:] / sd[1:]).sum(), np.zeros(len(beta) - 1)]


def ridge_predict(beta: np.ndarray, x: np.ndarray) -> np.ndarray:
    return beta[0] + x @ beta[1:]


def logistic_fit(x: np.ndarray, y: np.ndarray, lam: float = 1.0, iters: int = 50) -> np.ndarray:
    x1 = np.column_stack([np.ones(len(x)), x])
    w = np.zeros(x1.shape[1])
    reg = lam * np.eye(len(w))
    reg[0, 0] = 0.0
    for _ in range(iters):
        p = 1 / (1 + np.exp(-x1 @ w))
        g = x1.T @ (p - y) + reg @ w
        h = (x1 * (p * (1 - p))[:, None]).T @ x1 + reg
        step = np.linalg.solve(h, g)
        w -= step
        if np.abs(step).max() < 1e-8:
            break
    return w


def logistic_predict(w, x):
    return 1 / (1 + np.exp(-(w[0] + x @ w[1:])))


def brier(p, y):
    return float(np.mean((p - y) ** 2))


def logloss(p, y):
    p = np.clip(p, 1e-6, 1 - 1e-6)
    return float(-np.mean(y * np.log(p) + (1 - y) * np.log(1 - p)))


def logit(p):
    p = np.clip(p, 1e-6, 1 - 1e-6)
    return np.log(p / (1 - p))


def walk_forward(feat: pd.DataFrame, test_seasons, margin_features=None, total_features=None) -> pd.DataFrame:
    """Score every game in the test seasons, refitting before each week."""
    MARGIN_FEATURES = margin_features or globals()["MARGIN_FEATURES"]
    TOTAL_FEATURES = total_features or globals()["TOTAL_FEATURES"]
    df = feat[feat["result"].notna() & feat["spread_line"].notna() & (feat["season"] >= FIRST_FIT_SEASON)].copy()
    df["p_mkt_win"] = [no_vig_home(h, a) for h, a in zip(df["home_ml"], df["away_ml"])]
    df["cover"] = np.where(df["result"] > df["spread_line"], 1.0, np.where(df["result"] < df["spread_line"], 0.0, np.nan))
    df["over"] = np.where(df["total"] > df["total_line"], 1.0, np.where(df["total"] < df["total_line"], 0.0, np.nan))
    df["win"] = np.where(df["result"] > 0, 1.0, np.where(df["result"] < 0, 0.0, np.nan))
    out = []
    for season in test_seasons:
        for week in sorted(df.loc[df["season"] == season, "week"].unique()):
            train = df[(df["season"] < season) | ((df["season"] == season) & (df["week"] < week))]
            test = df[(df["season"] == season) & (df["week"] == week)].copy()
            # 1. Ratings-only margin and total.
            bm = ridge_fit(train[MARGIN_FEATURES].values, train["result"].values)
            test["pred_margin"] = ridge_predict(bm, test[MARGIN_FEATURES].values)
            tt = train[train["total_line"].notna()]
            bt = ridge_fit(tt[TOTAL_FEATURES].values, tt["total"].values)
            test["pred_total"] = ridge_predict(bt, test[TOTAL_FEATURES].values)
            train_m = ridge_predict(bm, train[MARGIN_FEATURES].values)
            train_t = ridge_predict(bt, train[TOTAL_FEATURES].values)
            # 2. Ratings on top of the market: cover chance from the gap.
            gap_tr = (train_m - train["spread_line"].values)[:, None]
            ok = ~np.isnan(train["cover"].values)
            wc = logistic_fit(gap_tr[ok], train["cover"].values[ok])
            test["p_cover"] = logistic_predict(wc, (test["pred_margin"] - test["spread_line"]).values[:, None])
            gap_t = (train_t - train["total_line"].values)[:, None]
            ok = ~np.isnan(train["over"].values) & ~np.isnan(gap_t[:, 0])
            wo = logistic_fit(gap_t[ok], train["over"].values[ok])
            test["p_over"] = logistic_predict(wo, (test["pred_total"] - test["total_line"]).values[:, None])
            # 3. Win chance: market logit + ratings gap.
            ok = train["p_mkt_win"].notna().values & ~np.isnan(train["win"].values)
            xw = np.column_stack([logit(train["p_mkt_win"].values[ok]), gap_tr[ok, 0]])
            ww = logistic_fit(xw, train["win"].values[ok], lam=0.1)
            xt = np.column_stack([logit(test["p_mkt_win"].fillna(0.5).values), (test["pred_margin"] - test["spread_line"]).values])
            test["p_win_blend"] = logistic_predict(ww, xt)
            # Ratings-alone win chance (margin -> chance with a fitted slope).
            okr = ~np.isnan(train["win"].values)
            wr = logistic_fit(train_m[okr][:, None], train["win"].values[okr])
            test["p_win_ratings"] = logistic_predict(wr, test["pred_margin"].values[:, None])
            # Market-only win chance, recalibrated the same way, so the comparison is fair.
            wm = logistic_fit(logit(train["p_mkt_win"].values[ok])[:, None], train["win"].values[ok], lam=0.1)
            test["p_win_mkt"] = logistic_predict(wm, logit(test["p_mkt_win"].fillna(0.5).values)[:, None])
            out.append(test)
    return pd.concat(out, ignore_index=True)


def summarize(scored: pd.DataFrame) -> dict:
    report = {}
    for season, s in scored.groupby("season"):
        r = {"games": int(len(s))}
        r["marginRmse"] = {"ratings": float(np.sqrt(np.mean((s.pred_margin - s.result) ** 2))),
                           "closingLine": float(np.sqrt(np.mean((s.spread_line - s.result) ** 2)))}
        t = s[s.total_line.notna()]
        r["totalRmse"] = {"ratings": float(np.sqrt(np.mean((t.pred_total - t.total) ** 2))),
                          "closingLine": float(np.sqrt(np.mean((t.total_line - t.total) ** 2)))}
        c = s[s.cover.notna()]
        r["cover"] = {"n": int(len(c)), "brier": brier(c.p_cover, c.cover), "coinBrier": 0.25,
                      "logLoss": logloss(c.p_cover, c.cover), "coinLogLoss": math.log(2),
                      "hitRateWhenPicking": float(np.mean((c.p_cover > 0.5) == (c.cover == 1)))}
        o = s[s.over.notna() & s.p_over.notna()]
        r["over"] = {"n": int(len(o)), "brier": brier(o.p_over, o.over), "coinBrier": 0.25,
                     "logLoss": logloss(o.p_over, o.over),
                     "hitRateWhenPicking": float(np.mean((o.p_over > 0.5) == (o.over == 1)))}
        w = s[s.win.notna() & s.p_mkt_win.notna()]
        r["win"] = {"n": int(len(w)),
                    "marketBrier": brier(w.p_win_mkt, w.win), "marketLogLoss": logloss(w.p_win_mkt, w.win),
                    "ratingsBrier": brier(w.p_win_ratings, w.win), "ratingsLogLoss": logloss(w.p_win_ratings, w.win),
                    "blendBrier": brier(w.p_win_blend, w.win), "blendLogLoss": logloss(w.p_win_blend, w.win)}
        report[int(season)] = r
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default="model/.cache/nflverse")
    ap.add_argument("--schedule", default="model/.cache/games.csv")
    ap.add_argument("--first-test", type=int, default=2012)
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    cache = Path(args.cache)
    games = load_games(Path(args.schedule))
    last = int(games.loc[games.result.notna(), "season"].max())
    plays, st = load_plays(cache, range(2006, last + 1))
    feat, _ = run_team_ratings(games, team_game_table(plays, st))
    scored = walk_forward(feat, range(args.first_test, last + 1))
    report = summarize(scored)
    for season, r in report.items():
        print(season, r["games"],
              "rmse %.2f vs %.2f" % (r["marginRmse"]["ratings"], r["marginRmse"]["closingLine"]),
              "cover %.4f" % r["cover"]["brier"], "hit %.3f" % r["cover"]["hitRateWhenPicking"],
              "over %.4f" % r["over"]["brier"],
              "win mkt %.4f rat %.4f blend %.4f" % (r["win"]["marketBrier"], r["win"]["ratingsBrier"], r["win"]["blendBrier"]))
    if args.out:
        Path(args.out).write_text(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
