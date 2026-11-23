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

import elo_backtest as eb
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


def current_ratings(tr, pr_players, pr_props, games, snaps, plays, names) -> dict:
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
    team_out = []
    for r in tdf.sort_values("net", ascending=False).itertuples(index=False):
        team_out.append({"team": r.team, "overall": int(r.overall), "offense": int(r.offense), "defense": int(r.defense),
                         "netPointsVsAverage": round(float(r.net), 1),
                         "passOffenseEpa": round(float(r.passOffense), 3), "passDefenseEpaAllowed": round(float(r.passDefense), 3),
                         "runOffenseEpa": round(float(r.runOffense), 3), "runDefenseEpaAllowed": round(float(r.runDefense), 3),
                         "specialTeamsPoints": round(float(r.specialTeams), 2), "quarterback": names.get(r.qb, r.qb)})
    # Players: everyone with snaps this season.
    sn = snaps[(snaps.season == season)].dropna(subset=["gsis_id"])
    agg = sn.groupby(["gsis_id"]).agg(team=("team", "last"), position=("position", "last"),
                                      off=("offense_snaps", "sum"), de=("defense_snaps", "sum")).reset_index()
    prows = []
    for r in agg.itertuples(index=False):
        if r.off >= 100:
            book_pass = pr_players.qb_book if r.position == "QB" else pr_players.books[("off", "pass")]
            v = book_pass.get(r.gsis_id, season, wi)[0] + pr_players.books[("off", "run")].get(r.gsis_id, season, wi)[0]
            prows.append({"player": r.gsis_id, "team": r.team, "position": r.position, "side": "offense", "value": v})
        if r.de >= 100:
            v = pr_players.books[("def", "pass")].get(r.gsis_id, season, wi)[0] + pr_players.books[("def", "run")].get(r.gsis_id, season, wi)[0]
            prows.append({"player": r.gsis_id, "team": r.team, "position": r.position, "side": "defense", "value": v})
    pdf = pd.DataFrame(prows)
    pdf["overall"] = pdf.groupby("position")["value"].transform(overall)
    # Skill detail from the prop ratings.
    g = lambda book, key: round(float(book.get(key, season, wi)[0]), 3)
    players_out = []
    for r in pdf.sort_values(["position", "overall"], ascending=[True, False]).itertuples(index=False):
        row = {"name": names.get(r.player, r.player), "id": r.player, "team": r.team, "position": r.position,
               "overall": int(r.overall), "onFieldEpaPerPlay": round(float(r.value), 4)}
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
    return {"season": season, "asOfWeek": week, "scale": "overall = 40 + 59 x percentile within position (teams: within league)",
            "teams": team_out, "players": players_out, "defenseVsPosition": defense_vs}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default="model/.cache/nflverse")
    ap.add_argument("--schedule", default="model/.cache/games.csv")
    ap.add_argument("--book-prices", default="")
    ap.add_argument("--out", default="research/elo-ratings")
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
    (out / "ratings_current.json").write_text(json.dumps(current_ratings(tr, pr_players, pr_props, games, snaps, plays, names), indent=1))
    print(json.dumps({k: v for k, v in report.items()}, indent=1)[:3000])
    print(json.dumps(json.loads((out / "prop_backtest.json").read_text())["props"].get("all", {}), indent=1))


if __name__ == "__main__":
    main()
