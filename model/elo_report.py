"""Run the Coach ratings end to end and write the research files.

    python model/elo_report.py --cache model/.cache/nflverse \
        --schedule model/.cache/games.csv --out research/elo-ratings

Writes:
- game_backtest.json  walk-forward game results vs the closing line
- prop_backtest.json  prop chances vs book no-vig closes
- ratings_current.json  every team and player, with a 40-99 overall
"""

from __future__ import annotations

import argparse
import collections
import json
import sys
import urllib.request
from pathlib import Path

import numpy as np
import pandas as pd

import elo_angles
import elo_backtest as eb
import elo_skill
import elo_trenches
from elo_data import fetch, load_games, load_plays, load_snaps
from elo_players import build_lineups, run_player_ratings, unit_epa
from elo_props import METRICS, apply_scale, fit_scale, over_chance, player_positions, run_prop_ratings
from elo_ratings import run_team_ratings, team_game_table, week_index

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from prop_shares import no_vig_over, norm_name  # noqa: E402

BOOK_PRICES = "https://coach-research.dds-dge.workers.dev/v1/book-prices"
WORKER_MARKETS = {"player_pass_yds": "passing_yards", "player_rush_yds": "rushing_yards",
                  "player_reception_yds": "receiving_yards", "player_receptions": "receptions"}


def overall(values: pd.Series) -> pd.Series:
    """Video-game style 40-99: percentile within the group."""
    pct = values.rank(pct=True)
    return (40 + 59 * pct).round().astype(int)


def game_report(feat: pd.DataFrame, first: int, last: int) -> dict:
    scored = eb.walk_forward(feat, range(first, last + 1))
    groups = {f"{first}-2024": scored[scored.season < 2025]}
    for s in range(2025, last + 1):
        groups[str(s)] = scored[scored.season == s]
    out = {}
    for name, s in groups.items():
        c, o = s[s.cover.notna()], s[s.over.notna() & s.p_over.notna()]
        w = s[s.win.notna() & s.p_mkt_win.notna()]
        out[name] = {
            "games": int(len(s)),
            "marginRmse": {"ratings": round(float(np.sqrt(np.mean((s.pred_margin - s.result) ** 2))), 3),
                           "closingLine": round(float(np.sqrt(np.mean((s.spread_line - s.result) ** 2))), 3)},
            "totalRmse": {"ratings": round(float(np.sqrt(np.mean((o.pred_total - o.total) ** 2))), 3),
                          "closingLine": round(float(np.sqrt(np.mean((o.total_line - o.total) ** 2))), 3)},
            "coverBrier": {"ratingsOnTopOfLine": round(eb.brier(c.p_cover, c.cover), 4), "coinFlip": 0.25},
            "coverPickHitRate": round(float(np.mean((c.p_cover > 0.5) == (c.cover == 1))), 3),
            "overBrier": {"ratingsOnTopOfLine": round(eb.brier(o.p_over, o.over), 4), "coinFlip": 0.25},
            "winBrier": {"market": round(eb.brier(w.p_win_mkt, w.win), 4),
                         "ratingsAlone": round(eb.brier(w.p_win_ratings, w.win), 4),
                         "marketPlusRatings": round(eb.brier(w.p_win_blend, w.win), 4)},
            "winLogLoss": {"market": round(eb.logloss(w.p_win_mkt, w.win), 4),
                           "ratingsAlone": round(eb.logloss(w.p_win_ratings, w.win), 4),
                           "marketPlusRatings": round(eb.logloss(w.p_win_blend, w.win), 4)},
        }
    return out


def _with_features(feat, margin, total, first, last):
    saved = eb.MARGIN_FEATURES, eb.TOTAL_FEATURES
    eb.MARGIN_FEATURES, eb.TOTAL_FEATURES = margin, total
    try:
        return game_report(feat, first, last)
    finally:
        eb.MARGIN_FEATURES, eb.TOTAL_FEATURES = saved


def angle_tests(feat: pd.DataFrame, first: int, last: int) -> dict:
    """Each new angle added on its own to the current ratings, then all, then the ones that pass.

    An angle's spread/moneyline side is kept only if cover Brier and win Brier both improve in
    each of the last two seasons; its totals side only if over Brier improves in both.
    """
    base_m, base_t = list(eb.MARGIN_FEATURES), list(eb.TOTAL_FEATURES)
    recent = [str(last - 1), str(last)]
    base = _with_features(feat, base_m, base_t, first, last)
    out = {"base": base, "groups": {}, "rule": ("keep an angle's spread side only if cover and win Brier improve in both "
                                                 f"{recent[0]} and {recent[1]}; its totals side only if over Brier does")}
    keep_m, keep_t = [], []
    for name, (m, t) in elo_angles.ANGLE_GROUPS.items():
        r = _with_features(feat, base_m + m, base_t + t, first, last)
        spread_ok = all(r[y]["coverBrier"]["ratingsOnTopOfLine"] < base[y]["coverBrier"]["ratingsOnTopOfLine"]
                        and r[y]["winBrier"]["marketPlusRatings"] < base[y]["winBrier"]["marketPlusRatings"] for y in recent)
        total_ok = bool(t) and all(r[y]["overBrier"]["ratingsOnTopOfLine"] < base[y]["overBrier"]["ratingsOnTopOfLine"] for y in recent)
        out["groups"][name] = {"features": {"spread": m, "total": t}, "keptSpread": bool(spread_ok and m),
                               "keptTotal": total_ok, "results": r}
        if spread_ok:
            keep_m += m
        if total_ok:
            keep_t += t
    all_m = [c for m, _ in elo_angles.ANGLE_GROUPS.values() for c in m]
    all_t = [c for _, t in elo_angles.ANGLE_GROUPS.values() for c in t]
    out["allAngles"] = _with_features(feat, base_m + all_m, base_t + all_t, first, last)
    out["kept"] = {"spread": keep_m, "total": keep_t}
    out["withKeptAngles"] = _with_features(feat, base_m + keep_m, base_t + keep_t, first, last)
    # How much each angle counts: ridge weight on all completed games, in points per one standard deviation.
    done = feat[feat.result.notna() & (feat.season >= eb.FIRST_FIT_SEASON)]
    weights = {}
    for target, cols in (("margin", base_m + all_m), ("total", base_t + all_t)):
        d = done[done.total_line.notna()] if target == "total" else done
        beta = eb.ridge_fit(d[cols].values, d["result" if target == "margin" else "total"].values)
        sd = d[cols].std().values
        weights[target] = {c: round(float(b * s), 3) for c, b, s in zip(cols, beta[1:], sd)}
    out["pointsPerSd"] = weights
    return out


def worker_props(path: Path | None, players: pd.DataFrame) -> list[dict]:
    """Latest pre-kickoff two-sided price per book, no-vig, averaged across books."""
    if path is not None and path.exists():
        obs = json.loads(path.read_text())["observations"]
    else:
        try:
            with urllib.request.urlopen(BOOK_PRICES, timeout=60) as r:
                obs = json.loads(r.read())["observations"]
        except Exception:
            return []
    byname = collections.defaultdict(list)
    for r in players.itertuples(index=False):
        byname[norm_name(str(r.display_name))].append(r.gsis_id)
    latest = {}
    for o in obs:
        if o.get("market") not in WORKER_MARKETS or o["at"] > o["kickoff"]:
            continue
        k = (o["book"], o["eventId"], o["market"], o["player"], o["line"], o["outcome"])
        if k not in latest or o["at"] > latest[k]["at"]:
            latest[k] = o
    pairs = collections.defaultdict(dict)
    for (book, event, market, player, line, outcome), o in latest.items():
        pairs[(event, market, player, line)].setdefault(book, {})[outcome] = o
    rows = []
    for (event, market, player, line), books in pairs.items():
        chances = [no_vig_over(v["Over"]["decimal"], v["Under"]["decimal"])
                   for v in books.values() if "Over" in v and "Under" in v]
        chances = [c for c in chances if c]
        if not chances:
            continue
        any_obs = next(iter(next(iter(books.values())).values()))
        ids = byname.get(norm_name(player)) or []
        pid = any_obs.get("playerId") or (ids[0] if len(ids) == 1 else None)
        game = event.split(":")[-1]
        season, week = int(game[:4]), int(game[5:7])
        rows.append({"src": "worker", "season": season, "week": week, "player": pid, "metric": WORKER_MARKETS[market],
                     "line": line, "actual": None, "book": float(np.mean(chances)), "books": len(chances)})
    return rows


def prop_report(proj: pd.DataFrame, prop_rows: list[dict]) -> dict:
    proj = proj[proj.played]
    quality = {}
    for m in METRICS:
        parts = []
        for s in range(2017, int(proj.season.max()) + 1):
            tr = proj[(proj.season < s) & (proj.season >= s - 4)]
            te = proj[proj.season == s].copy()
            te["p"] = apply_scale(fit_scale(tr, m), te, m)
            parts.append(te)
        o = pd.concat(parts)
        o = o[o.p > 0]
        quality[m] = {"playerGames": int(len(o)), "mae": round(float(np.mean(np.abs(o.p - o[m]))), 2),
                      "correlation": round(float(np.corrcoef(o.p, o[m])[0, 1]), 3)}
    scored = []
    for season in sorted({r["season"] for r in prop_rows}):
        tr = proj[(proj.season >= season - 4) & (proj.season < season)]
        scales = {m: fit_scale(tr, m) for m in METRICS}
        hist = {}
        for m in METRICS:
            p = apply_scale(scales[m], tr, m)
            keep = p > 0
            hist[m] = (p[keep], tr[m].values[keep])
        cur = proj[proj.season == season].drop_duplicates(["week", "player"]).set_index(["week", "player"])
        for r in (x for x in prop_rows if x["season"] == season):
            if (r["week"], r["player"]) not in cur.index:
                continue
            x = cur.loc[(r["week"], r["player"])]
            b = scales[r["metric"]]
            p_proj = max(0.0, float(x[f"proj_{r['metric']}"]) * (b[0] + b[1] * float(x.spread_t) + b[2] * (float(x.itt) - 22)))
            actual = r["actual"] if r["actual"] is not None else float(x[r["metric"]])
            if actual == r["line"]:
                continue
            chance = over_chance(p_proj, r["line"], *hist[r["metric"]])
            if np.isnan(chance):
                continue
            scored.append({**r, "proj": p_proj, "model": chance, "y": float(actual > r["line"])})
    s = pd.DataFrame(scored)
    out = {"projectionQuality": quality, "props": {}}
    if s.empty:
        return out
    lg = lambda p: np.log(np.clip(p, 1e-4, 1 - 1e-4) / (1 - np.clip(p, 1e-4, 1 - 1e-4)))
    for name, t in list(s.groupby("src")) + [("all", s)]:
        res = {"props": int(len(t)),
               "brier": {"booksNoVig": round(eb.brier(t.book, t.y), 4), "ratingsAlone": round(eb.brier(t.model, t.y), 4),
                         "coinFlip": 0.25},
               "logLoss": {"booksNoVig": round(eb.logloss(t.book.values, t.y.values), 4),
                           "ratingsAlone": round(eb.logloss(t.model.values, t.y.values), 4)},
               "blendBrier": {f"{w:.2f}": round(float(np.mean((1 / (1 + np.exp(-((1 - w) * lg(t.book) + w * lg(t.model)))) - t.y) ** 2)), 4)
                              for w in (0.05, 0.1, 0.2)},
               "projectionVsLineCorrelation": round(float(np.corrcoef(t.proj, t.line)[0, 1]), 3),
               "byMetric": {m: {"props": int(len(u)), "booksBrier": round(eb.brier(u.book, u.y), 4),
                                "ratingsBrier": round(eb.brier(u.model, u.y), 4)} for m, u in t.groupby("metric")}}
        out["props"][name] = res
    return out


def skill_prop_check(rp: pd.DataFrame, prop_rows: list[dict]) -> dict:
    """Receiving-yard props for WRs and TEs: the new skill projection vs the books."""
    played = rp[rp.a_snap_pct > 0]
    out = {}
    for season in sorted({r["season"] for r in prop_rows}):
        hist = played[(played.season < season) & (played.season >= season - 4) & (played.proj > 0)]
        cur = played[played.season == season].drop_duplicates(["week", "player"]).set_index(["week", "player"])
        rows = []
        for r in prop_rows:
            if r["season"] != season or r["metric"] != "receiving_yards" or (r["week"], r["player"]) not in cur.index:
                continue
            x = cur.loc[(r["week"], r["player"])]
            actual = r["actual"] if r["actual"] is not None else float(x.a_rec_yds)
            if actual == r["line"]:
                continue
            chance = over_chance(float(x.proj), r["line"], hist.proj.values, hist.a_rec_yds.values)
            if np.isnan(chance):
                continue
            rows.append((r["book"], chance, float(actual > r["line"]), float(x.proj), r["line"]))
        if not rows:
            continue
        a = np.array(rows)
        lg = lambda p: np.log(np.clip(p, 1e-4, 1 - 1e-4) / (1 - np.clip(p, 1e-4, 1 - 1e-4)))
        out[str(season)] = {
            "props": int(len(a)),
            "booksBrier": round(eb.brier(a[:, 0], a[:, 2]), 4),
            "skillRatingBrier": round(eb.brier(a[:, 1], a[:, 2]), 4),
            "pooled5pctBrier": round(float(np.mean((1 / (1 + np.exp(-(0.95 * lg(a[:, 0]) + 0.05 * lg(a[:, 1])))) - a[:, 2]) ** 2)), 4),
            "projectionVsLineCorrelation": round(float(np.corrcoef(a[:, 3], a[:, 4])[0, 1]), 3),
        }
    return out


def current_ratings(tr, pr_players, pr_props, games, snaps, plays, names, skill=None) -> dict:
    last = games[games.result.notna()].sort_values(["season", "week"]).iloc[-1]
    season, week = int(last.season), int(last.week) + 1
    wi = week_index(season, week)
    teams = sorted(set(games.loc[games.season == season, "home_team"]))
    # Team: points per game vs an average team on a neutral field, from the same
    # pieces the game model uses (pass, run, special teams, points rating).
    rows = []
    starters = {}
    last_games = games[(games.season == season) & games.result.notna()].sort_values("week")
    for g in last_games.itertuples(index=False):
        starters[g.home_team], starters[g.away_team] = g.home_qb_id, g.away_qb_id
    for t in teams:
        s = tr.snapshot(t, starters.get(t) if isinstance(starters.get(t), str) else None, season, wi)
        rows.append({"team": t, "passOffense": s["pass_off"], "passDefense": s["pass_def"], "runOffense": s["run_off"],
                     "runDefense": s["run_def"], "specialTeams": s["st"], "pointsRating": s["pts"], "qb": starters.get(t)})
    tdf = pd.DataFrame(rows)
    # One number: offense minus defense EPA, scaled like the points rating.
    tdf["net"] = (tdf.passOffense - tdf.passDefense) * 34 + (tdf.runOffense - tdf.runDefense) * 26 + tdf.specialTeams + tdf.pointsRating
    tdf["overall"] = overall(tdf["net"])
    for c in ("offense", "defense"):
        tdf[c] = overall((tdf.passOffense * 34 + tdf.runOffense * 26) if c == "offense" else -(tdf.passDefense * 34 + tdf.runDefense * 26))
    unit = {}
    if skill is not None and skill.get("trench") is not None:
        trench, lus = skill["trench"], skill["trench_lineups"]
        played = games[(games.season == season) & games.result.notna()].sort_values("week")
        last_lu = {}
        for g in played.itertuples(index=False):
            for team, side in ((g.home_team, "home"), (g.away_team, "away")):
                if (g.game_id, side) in lus:
                    last_lu[team] = lus[(g.game_id, side)]
        for t, lu in last_lu.items():
            u = {}
            for k in elo_trenches.TrenchRatings.KINDS:
                u[f"block_{k}"] = trench.strength(lu["ol"], "ol", k, season, wi) + trench.strength(lu["qb"], "qb", k, season, wi)
                u[f"front_{k}"] = trench.strength(lu["front"], "front", k, season, wi)
            unit[t] = u
        udf = pd.DataFrame(unit).T
        if not udf.empty:
            udf["passBlock"] = overall(udf.block_pass_pro)
            udf["runBlock"] = overall(udf.block_run_stuff + udf.block_run_push)
            udf["passRush"] = overall(udf.front_pass_pro)
            udf["runDefense"] = overall(udf.front_run_stuff + udf.front_run_push)
            unit = udf[["passBlock", "runBlock", "passRush", "runDefense"]].astype(int).to_dict("index")
    team_out = []
    for r in tdf.sort_values("net", ascending=False).itertuples(index=False):
        team_out.append({"team": r.team, "overall": int(r.overall), "offense": int(r.offense), "defense": int(r.defense),
                         "netPointsVsAverage": round(float(r.net), 1),
                         "passOffenseEpa": round(float(r.passOffense), 3), "passDefenseEpaAllowed": round(float(r.passDefense), 3),
                         "runOffenseEpa": round(float(r.runOffense), 3), "runDefenseEpaAllowed": round(float(r.runDefense), 3),
                         "specialTeamsPoints": round(float(r.specialTeams), 2), "quarterback": names.get(r.qb, r.qb),
                         **({"lines": unit[r.team]} if r.team in unit else {})})
    # Players: everyone with snaps this season.
    sn = snaps[(snaps.season == season)].dropna(subset=["gsis_id"])
    agg = sn.groupby(["gsis_id"]).agg(team=("team", "last"), position=("position", "last"),
                                      off=("offense_snaps", "sum"), de=("defense_snaps", "sum")).reset_index()
    prows = []
    for r in agg.itertuples(index=False):
        if r.off >= 100:
            book_pass = pr_players.qb_book if r.position == "QB" else pr_players.books[("off", "pass")]
            v = book_pass.get(r.gsis_id, season, wi)[0] + pr_players.books[("off", "run")].get(r.gsis_id, season, wi)[0]
            prows.append({"player": r.gsis_id, "team": r.team, "position": r.position, "side": "offense", "value": v, "snaps": int(r.off)})
        if r.de >= 100:
            v = pr_players.books[("def", "pass")].get(r.gsis_id, season, wi)[0] + pr_players.books[("def", "run")].get(r.gsis_id, season, wi)[0]
            prows.append({"player": r.gsis_id, "team": r.team, "position": r.position, "side": "defense", "value": v, "snaps": int(r.de)})
    pdf = pd.DataFrame(prows)
    g = lambda book, key: round(float(book.get(key, season, wi)[0]), 3)
    # Offense skill players: the learned skill rating (elo_skill), which predicts
    # next-game production per opportunity from every free variable. Everyone
    # else: the on-field rating, plus measured production for defenders.
    z = lambda col: (col - col.mean()) / (col.std() or 1.0)
    pdf["score"] = pdf["value"]
    attrs = {}
    if skill is not None:
        rated_skill = skill["rated"].drop_duplicates("player").set_index("player")["skill"]
        attrs = skill["attributes"]
        prod = skill["production"]
        off = pdf.side == "offense"
        has = off & pdf.player.isin(rated_skill.index) & pdf.position.isin(["QB", "RB", "FB", "WR", "TE"])
        pdf.loc[has, "score"] = pdf.loc[has, "player"].map(rated_skill)
        de = pdf.side == "defense"
        pdf["prod"] = [prod.get((p, "defense"), np.nan) for p in pdf.player]
        for pos in pdf.loc[de, "position"].unique():
            m = de & (pdf.position == pos)
            if m.sum() > 1:
                pr_ = pdf.loc[m, "prod"].fillna(pdf.loc[m, "prod"].median())
                pdf.loc[m, "score"] = z(pdf.loc[m, "value"]) + z(pr_)
        trench = skill.get("trench")
        if trench is not None:
            tb = trench.books
            def tval(unit, kind, pid):
                return tb[(unit, kind)].get(pid, season, wi)[0]
            line_attrs = {}
            for i, r in pdf.iterrows():
                if r.side == "offense" and r.position in elo_trenches.OL:
                    vals = {k: tval("ol", k, r.player) for k in elo_trenches.TrenchRatings.KINDS}
                elif r.side == "defense" and r.position in elo_trenches.FRONT:
                    vals = {k: tval("front", k, r.player) for k in elo_trenches.TrenchRatings.KINDS}
                else:
                    continue
                for k, v in vals.items():
                    pdf.loc[i, f"line_{k}"] = v
            for side, units, label in (("offense", elo_trenches.OL, ("Pass block", "Run block (no stuffs)", "Run push")),
                                       ("defense", elo_trenches.FRONT, ("Pocket pressure", "Run stuffing", "Run fits"))):
                m = (pdf.side == side) & pdf.position.isin(units)
                if m.sum() < 2:
                    continue
                for k, name in zip(elo_trenches.TrenchRatings.KINDS, label):
                    pct = (40 + 59 * pdf.loc[m, f"line_{k}"].rank(pct=True)).round()
                    for i, v in pct.items():
                        line_attrs.setdefault(i, {})[name] = int(v)
                line_sum = sum(z(pdf.loc[m, f"line_{k}"]) for k in elo_trenches.TrenchRatings.KINDS)
                if side == "offense":
                    pdf.loc[m, "score"] = z(pdf.loc[m, "value"]) + 2 * line_sum / 3
                else:
                    pdf.loc[m, "score"] = pdf.loc[m, "score"] + line_sum / 3
            for i, extra in line_attrs.items():
                key = (pdf.at[i, "player"], pdf.at[i, "side"])
                attrs[key] = {**extra, **attrs.get(key, {})}
    # Kickers and punters.
    kick = skill.get("kick") if skill is not None else None
    if kick is not None:
        st = snaps[(snaps.season == season)].dropna(subset=["gsis_id"])
        st = st[st.position.isin(["K", "P"])].groupby("gsis_id").agg(team=("team", "last"), position=("position", "last"),
                                                                       st=("st_snaps", "sum"))
        krows = []
        for pid, r in st[st.st >= 30].iterrows():
            if pid not in kick.index:
                continue
            k = kick.loc[pid]
            krows.append({"player": pid, "team": r.team, "position": r.position, "side": "special", "value": 0.0,
                          "snaps": int(r.st), **{c: k[c] for c in kick.columns}})
        kdf = pd.DataFrame(krows)
        if not kdf.empty:
            for pos, parts in (("K", {"fg_over_expected": ("Accuracy (over expected)", 1.0), "long_range": ("Range (50+)", 0.5),
                                      "xp_rate": ("Extra points", 0.3)}),
                               ("P", {"net_over_expected": ("Net punting", 1.0), "inside_20": ("Inside the 20", 0.5)})):
                m = kdf.position == pos
                if m.sum() < 2:
                    continue
                kdf.loc[m, "score"] = sum(w * z(kdf.loc[m, c].fillna(kdf.loc[m, c].median())) for c, (_, w) in parts.items())
                for c, (name, _) in parts.items():
                    pct = (40 + 59 * kdf.loc[m, c].rank(pct=True)).round()
                    for i, v in pct.items():
                        if pd.notna(v):
                            attrs.setdefault((kdf.at[i, "player"], "special"), {})[name] = int(v)
            pdf = pd.concat([pdf, kdf[[c for c in kdf.columns if c in pdf.columns or c == "score"]]], ignore_index=True)
    pdf["overall"] = pdf.groupby(["position", "side"])["score"].transform(overall)
    players_out = []
    for r in pdf.sort_values(["position", "overall"], ascending=[True, False]).itertuples(index=False):
        row = {"name": names.get(r.player, r.player), "id": r.player, "team": r.team, "position": r.position,
               "overall": int(r.overall), "side": r.side, "snaps": int(r.snaps),
               "onFieldEpaPerPlay": round(float(r.value), 4)}
        if attrs.get((r.player, r.side)):
            row["attributes"] = attrs[(r.player, r.side)]
        if r.position in ("WR", "TE", "RB"):
            row.update({"yardsPerTargetVsAverage": g(pr_props.rec_ypt, r.player), "catchRateVsAverage": g(pr_props.rec_catch, r.player),
                        "targetShareVsAverage": g(pr_props.tshare, r.player)})
        if r.position in ("RB", "QB"):
            row["yardsPerCarryVsAverage"] = g(pr_props.ypc, r.player)
        if r.position == "QB":
            row["yardsPerAttemptVsAverage"] = g(pr_props.qb_ypa, r.player)
        players_out.append(row)
    defense_vs = []
    for t in teams:
        defense_vs.append({"team": t, **{f"yardsPerTargetAllowedVs{p}": g(pr_props.def_ypt, (t, p)) for p in ("WR", "TE", "RB")},
                           "yardsPerCarryAllowed": g(pr_props.def_ypc, t)})
    return {"season": season, "asOfWeek": week, "scale": "overall = 40 + 59 x percentile within position (teams: within league). QB/RB/WR/TE: learned skill rating from every free variable (docs/ELO_RATINGS.md). Defenders: on-field rating plus measured production. Attributes: percentile within position of measured data.",
            "teams": team_out, "players": players_out, "defenseVsPosition": defense_vs}


def app_ratings(current: dict) -> dict:
    """Compact copy for the app (assets/elo-ratings.json). Extra context only."""
    players = []
    for r in current["players"]:
        row = {"n": r["name"], "id": r["id"], "t": r["team"], "p": r["position"], "o": r["overall"],
               "d": 1 if r["side"] == "defense" else 0, "s": r["snaps"]}
        for key, short_key in (("yardsPerTargetVsAverage", "ypt"), ("catchRateVsAverage", "cr"),
                               ("targetShareVsAverage", "ts"), ("yardsPerCarryVsAverage", "ypc"),
                               ("yardsPerAttemptVsAverage", "ypa")):
            if r.get(key) is not None:
                row[short_key] = r[key]
        if r.get("attributes"):
            row["a"] = r["attributes"]
        if r.get("situations"):
            row["sit"] = r["situations"]
        players.append(row)
    return {
        "schema": 1,
        "season": current["season"],
        "asOfWeek": current["asOfWeek"],
        "source": "nflverse play-by-play and snap counts (CC BY 4.0)",
        "note": ("Coach ratings are an extra number to weigh. They are not part of Coach's chance, "
                 "and in testing they did not beat the closing line (docs/ELO_RATINGS.md)."),
        "teams": [{"t": r["team"], "o": r["overall"], "off": r["offense"], "def": r["defense"],
                   "net": r["netPointsVsAverage"], "qb": r["quarterback"],
                   **({"lines": r["lines"]} if r.get("lines") else {}),
                   **({"ang": r["angles"]} if r.get("angles") else {})} for r in current["teams"]],
        "upcoming": current.get("upcoming", {}),
        "players": players,
        "defVs": {r["team"]: {"WR": r["yardsPerTargetAllowedVsWR"], "TE": r["yardsPerTargetAllowedVsTE"],
                              "RB": r["yardsPerTargetAllowedVsRB"], "ypc": r["yardsPerCarryAllowed"]}
                  for r in current["defenseVsPosition"]},
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default="model/.cache/nflverse")
    ap.add_argument("--schedule", default="model/.cache/games.csv")
    ap.add_argument("--book-prices", default="")
    ap.add_argument("--out", default="research/elo-ratings")
    ap.add_argument("--app-out", default="assets/elo-ratings.json")
    args = ap.parse_args()
    cache, out = Path(args.cache), Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    schedule = Path(args.schedule)
    if not schedule.exists():
        fetch("https://github.com/nflverse/nflverse-data/releases/download/schedules/games.csv", schedule)
    games = load_games(schedule)
    last = int(games.loc[games.result.notna(), "season"].max())
    plays, st = load_plays(cache, range(2006, last + 1))
    feat, tr = run_team_ratings(games, team_game_table(plays, st))
    snaps = load_snaps(cache, range(2013, last + 1))
    lineups = build_lineups(snaps)
    pf, pr_players = run_player_ratings(games[games.season >= 2013], lineups, unit_epa(plays[plays.season >= 2013]))
    feat = feat.merge(pf, on="game_id", how="left").fillna({c: 0.0 for c in ("p_pass", "p_run", "p_pass_sum", "p_run_sum")})
    report = {"teamOnly": game_report(feat, 2015, last)}
    eb.MARGIN_FEATURES = eb.MARGIN_FEATURES + ["p_pass", "p_run"]
    eb.TOTAL_FEATURES = eb.TOTAL_FEATURES + ["p_pass_sum", "p_run_sum"]
    report["teamPlusPlayers"] = game_report(feat, 2015, last)
    trench_obs = elo_trenches.line_observations(cache, range(2013, last + 1))
    trench_lu = elo_trenches.trench_lineups(snaps)
    tfeat, trench = elo_trenches.run_trenches(games[games.season >= 2013], trench_lu, trench_obs)
    feat = feat.merge(tfeat, on="game_id", how="left")
    tcols = [c for c in tfeat.columns if c != "game_id"]
    feat[tcols] = feat[tcols].fillna(0.0)
    eb.MARGIN_FEATURES = eb.MARGIN_FEATURES + ["t_pass_pro", "t_run_stuff", "t_run_push"]
    eb.TOTAL_FEATURES = eb.TOTAL_FEATURES + ["t_pass_pro_sum", "t_run_stuff_sum", "t_run_push_sum"]
    report["teamPlusPlayersPlusLines"] = game_report(feat, 2015, last)
    angle_data = elo_angles.AngleData(cache, range(2006, last + 1))
    afeat, angle_state = elo_angles.build_angles(games, angle_data, snaps, lineups, unit_epa(plays[plays.season >= 2013]))
    feat = feat.merge(afeat, on="game_id", how="left")
    acols = [c for c in afeat.columns if c != "game_id"]
    feat[acols] = feat[acols].fillna(0.0)
    tests = angle_tests(feat, 2015, last)
    (out / "angle_backtest.json").write_text(json.dumps(tests, indent=1))
    report["teamPlusPlayersPlusLinesPlusAngles"] = tests["withKeptAngles"]
    report["anglesKept"] = tests["kept"]
    (out / "game_backtest.json").write_text(json.dumps(report, indent=1))
    pos = player_positions(cache / "players.parquet")
    g13 = games[games.season >= 2013]
    proj, pr_props = run_prop_ratings(g13, plays[plays.season >= 2013], snaps, pos)
    closes = json.loads((Path(__file__).resolve().parents[1] / "assets" / "prop-closes.json").read_text())["rows"]
    prop_rows = [{"src": "propline", "season": r["season"], "week": r["week"], "player": r["playerId"], "metric": r["metric"],
                  "line": r["line"], "actual": r["actual"], "book": r["prior"]} for r in closes]
    people = pd.read_parquet(cache / "players.parquet", columns=["gsis_id", "display_name"])
    prop_rows += worker_props(Path(args.book_prices) if args.book_prices else None, people)
    (out / "prop_backtest.json").write_text(json.dumps(prop_report(proj, prop_rows), indent=1))
    names = dict(zip(people.gsis_id, people.display_name))
    people_full = pd.read_parquet(cache / "players.parquet")
    hist, cur, skill_games = elo_skill.build(cache, range(2013, last + 1), snaps, games, people_full)
    (out / "skill_backtest.json").write_text(json.dumps(elo_skill.evaluate(hist, cache, people_full), indent=1))
    rated, weights = elo_skill.fit_and_rate(hist, cur)
    (out / "skill_weights.json").write_text(json.dumps(weights, indent=1))
    cb = elo_skill.combine_table(cache, people_full)
    def_prod = elo_skill.defender_production(cache, range(last - 1, last + 1), snaps)
    season_now = int(cur.season.max())
    week_now = int(cur.week.max())
    avail = elo_skill.availability(snaps, season_now, week_now)
    sn_now = snaps[snaps.season == season_now].dropna(subset=["gsis_id"])
    tot = sn_now.groupby("gsis_id").agg(position=("position", "last"), off=("offense_snaps", "sum"), de=("defense_snaps", "sum"))
    rated_rows = pd.concat([
        pd.DataFrame({"player": tot.index[tot.off >= 100], "position": tot.position[tot.off >= 100].values, "side": "offense"}),
        pd.DataFrame({"player": tot.index[tot.de >= 100], "position": tot.position[tot.de >= 100].values, "side": "defense"}),
    ])
    attrs, prod = elo_skill.player_attributes(rated_rows, cur, cb, def_prod, avail, season_now)
    kick = elo_trenches.kicking_ratings(cache, range(2013, last + 1), season_now, week_now)
    skill = {"rated": rated, "attributes": attrs, "production": prod, "trench": trench,
             "trench_lineups": trench_lu, "kick": kick}
    rp = elo_skill.receiving_projection(hist, skill_games, range(last - 4, last + 1))
    check = skill_prop_check(rp, prop_rows)
    sb = json.loads((out / "skill_backtest.json").read_text())
    sb["receivingYardPropsVsBooks"] = check
    (out / "skill_backtest.json").write_text(json.dumps(sb, indent=1))
    print("skill prop check", check)
    current = current_ratings(tr, pr_players, pr_props, games, snaps, plays, names, skill)
    g_now = games[games.season == season_now]
    pending = g_now.loc[g_now.result.isna(), "week"]
    next_week = int(pending.min()) if len(pending) else week_now + 1
    positions = {r["id"]: r["position"] for r in current["players"] if r["side"] == "offense"}
    sits = elo_angles.situation_ratings(angle_data.s, season_now, next_week, positions)
    for r in current["players"]:
        if r["side"] == "offense" and r["id"] in sits:
            r["situations"] = sits[r["id"]]
    ang = elo_angles.current_angles(games, angle_data, snaps, angle_state, names, season_now, next_week)
    for r in current["teams"]:
        if ang["teams"].get(r["team"]):
            r["angles"] = ang["teams"][r["team"]]
    current["upcoming"] = {"week": next_week, "games": ang["upcoming"]}
    (out / "ratings_current.json").write_text(json.dumps(current, indent=1))
    if args.app_out:
        Path(args.app_out).write_text(json.dumps(app_ratings(current), separators=(",", ":")))
    print(json.dumps({k: v for k, v in report.items()}, indent=1)[:3000])
    print(json.dumps(json.loads((out / "prop_backtest.json").read_text())["props"].get("all", {}), indent=1))


if __name__ == "__main__":
    main()
