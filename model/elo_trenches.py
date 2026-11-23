"""Line play and kicking: ratings for offensive linemen, the defensive front,
kickers and punters, plus unit-vs-unit matchups.

Line play (all seasons with snap counts, 2013+):
each game, for each offense, three observations are made and every lineman
and front defender on the field is updated by his snap share (a weighted
Kalman update, the same way as elo_players):

- pass protection: (sacks + QB hits) per dropback. Offensive linemen and the
  quarterback (who also causes sacks) on one side, the defensive front on
  the other.
- run blocking: run stuff rate (designed runs for no gain or a loss).
- run push: run success rate.

Free data has no per-play pressure for 2026 and no yards before contact, so
these are the measures every season shares.

Kicking: each field goal is compared with the league make rate at that
distance (fit on earlier seasons); each punt's net yards with the league
average from that spot. Extra points the same way.
"""

from __future__ import annotations

from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd

from elo_data import pbp_path
from elo_ratings import RatingBook, week_index

OL = {"T", "G", "C", "OL", "OT", "OG"}
FRONT = {"DE", "DT", "NT", "DL", "OLB", "ILB", "MLB", "LB", "EDGE"}
LINE_COLUMNS = ["game_id", "season", "week", "season_type", "posteam", "defteam", "home_team", "play_type",
                "qb_dropback", "sack", "qb_hit", "yards_gained", "success", "qb_scramble", "epa"]
KICK_COLUMNS = ["game_id", "season", "week", "season_type", "posteam", "play_type", "field_goal_result",
                "kick_distance", "extra_point_result", "kicker_player_id", "punter_player_id", "yardline_100",
                "return_yards", "touchback", "punt_inside_twenty", "punt_blocked"]


def _read(cache: Path, season: int, columns, tag: str) -> pd.DataFrame:
    out = cache / f"{tag}_{season}.parquet"
    if out.exists():
        return pd.read_parquet(out)
    d = pd.read_parquet(pbp_path(cache, season), columns=columns)
    d = d[d.season_type.isin(["REG", "POST"])].drop(columns=["season_type"])
    d.to_parquet(out)
    return d


def line_observations(cache: Path, seasons) -> dict:
    """(game_id, side) -> dict of the offense's pass-protection and run numbers."""
    obs = {}
    for s in seasons:
        d = _read(cache, s, LINE_COLUMNS, "line")
        d = d[d.play_type.isin(["pass", "run"]) & d.epa.notna()]
        d["side"] = np.where(d.posteam == d.home_team, "home", "away")
        db = d[d.qb_dropback == 1]
        runs = d[(d.qb_dropback != 1) & (d.qb_scramble != 1)]
        a = db.groupby(["game_id", "side"]).agg(db=("epa", "size"), sacks=("sack", "sum"), hits=("qb_hit", "sum"))
        b = runs.groupby(["game_id", "side"]).agg(runs=("epa", "size"),
                                                  stuffs=("yards_gained", lambda y: float((y <= 0).sum())),
                                                  succ=("success", "sum"))
        for (gid, side), r in a.join(b, how="outer").fillna(0).iterrows():
            obs[(gid, side)] = r.to_dict()
    return obs


def _side(game_id: str, team: str) -> str:
    return "home" if team == game_id.split("_")[-1] else "away"


def trench_lineups(snaps: pd.DataFrame) -> dict:
    """(game_id, side) -> {'ol': [(player, share)], 'qb': [...], 'front': [...]} for that side's players."""
    s = snaps.dropna(subset=["gsis_id"])
    out: dict = defaultdict(lambda: {"ol": [], "qb": [], "front": []})
    for r in s.itertuples(index=False):
        side = _side(r.game_id, r.team)
        if r.position in OL and r.offense_pct > 0:
            out[(r.game_id, side)]["ol"].append((r.gsis_id, float(r.offense_pct)))
        elif r.position == "QB" and r.offense_pct > 0:
            out[(r.game_id, side)]["qb"].append((r.gsis_id, float(r.offense_pct)))
        elif r.position in FRONT and r.defense_pct > 0:
            out[(r.game_id, side)]["front"].append((r.gsis_id, float(r.defense_pct)))
    return out


class TrenchRatings:
    """Pass protection, run stuffing and run push, for blockers and the front."""

    KINDS = ("pass_pro", "run_stuff", "run_push")

    def __init__(self, prior_sd: float = 0.012, qb_sd: float = 0.02, keep: float = 0.6):
        self.books = {(unit, k): RatingBook((qb_sd if unit == "qb" else prior_sd) ** 2, 0.0, keep)
                      for unit in ("ol", "qb", "front") for k in self.KINDS}
        self.mu = {"pass_pro": 0.13, "run_stuff": 0.18, "run_push": 0.40}
        self.recent = defaultdict(list)

    def strength(self, lineup, unit, kind, season, wi, expected=True):
        total = 0.0
        for player, share in lineup:
            hist = self.recent.get(player)
            w = float(np.mean(hist[-4:])) if (expected and hist) else (share if not expected else 0.5 * share)
            total += w * self.books[(unit, kind)].get(player, season, wi)[0]
        return total

    def update(self, off, front, kind, y, n, season, wi):
        """Higher y is worse for the offense in all three measures except run_push."""
        if n <= 0:
            return
        p = y / n
        noise = max(p * (1 - p), 0.02) / n
        sign_off = 1.0 if kind == "run_push" else -1.0  # a good blocker lowers sacks/stuffs
        entries, pred, total = [], self.mu[kind], noise
        for unit, lineup, sign in (("ol", off["ol"], sign_off), ("qb", off["qb"], sign_off), ("front", front, -sign_off)):
            for player, share in lineup:
                book = self.books[(unit, kind)]
                m, v = book.get(player, season, wi)
                w = sign * share
                entries.append((book, player, w, m, v))
                pred += w * m
                total += w * w * v
        err = p - pred
        for book, player, w, m, v in entries:
            gain = w * v / total
            book.set(player, season, wi, m + gain * err, v - gain * w * v)
        self.mu[kind] += 0.002 * (p - self.mu[kind])

    def remember(self, lineup):
        for player, share in lineup:
            self.recent[player].append(share)
            if len(self.recent[player]) > 8:
                self.recent[player] = self.recent[player][-8:]


def run_trenches(games: pd.DataFrame, lineups: dict, obs: dict):
    """Pregame unit matchups per game, then update after each week (no same-week leakage)."""
    tr = TrenchRatings()
    rows = []
    games = games.sort_values(["season", "week", "gameday", "game_id"])
    for (season, week), block in games.groupby(["season", "week"], sort=True):
        season, week = int(season), int(week)
        wi = week_index(season, week)
        done = []
        for g in block.itertuples(index=False):
            h, a = lineups.get((g.game_id, "home")), lineups.get((g.game_id, "away"))
            if not h or not a or not h["ol"] or not a["ol"]:
                continue
            feat = {"game_id": g.game_id}
            for kind in TrenchRatings.KINDS:
                block_h = tr.strength(h["ol"], "ol", kind, season, wi) + tr.strength(h["qb"], "qb", kind, season, wi)
                block_a = tr.strength(a["ol"], "ol", kind, season, wi) + tr.strength(a["qb"], "qb", kind, season, wi)
                front_h = tr.strength(h["front"], "front", kind, season, wi)
                front_a = tr.strength(a["front"], "front", kind, season, wi)
                # Home offense edge minus away offense edge, in "good for offense" units.
                feat[f"t_{kind}"] = (block_h - front_a) - (block_a - front_h)
                feat[f"t_{kind}_sum"] = (block_h - front_a) + (block_a - front_h)
            rows.append(feat)
            if pd.notna(g.result):
                done.append((g.game_id, h, a))
        for gid, h, a in done:
            for side, off, de in (("home", h, a), ("away", a, h)):
                o = obs.get((gid, side))
                if not o:
                    continue
                tr.update(off, de["front"], "pass_pro", o["sacks"] + o["hits"], o["db"], season, wi)
                tr.update(off, de["front"], "run_stuff", o["stuffs"], o["runs"], season, wi)
                tr.update(off, de["front"], "run_push", o["succ"], o["runs"], season, wi)
            for lu in (h, a):
                for unit in ("ol", "qb", "front"):
                    tr.remember(lu[unit])
    return pd.DataFrame(rows), tr


# ---------------------------------------------------------------------------
# Kickers and punters


def kicking_ratings(cache: Path, seasons, through_season: int, through_week: int) -> pd.DataFrame:
    """Per kicker/punter: field goals over expected, long-range makes, extra points, net punting."""
    d = pd.concat([_read(cache, s, KICK_COLUMNS, "kick") for s in seasons], ignore_index=True)
    d = d[(d.season < through_season) | (d.week < through_week)]
    fg = d[d.play_type == "field_goal"].dropna(subset=["kick_distance", "kicker_player_id"]).copy()
    fg["made"] = (fg.field_goal_result == "made").astype(float)
    # League make rate by distance: logistic fit on every kick.
    x = fg.kick_distance.to_numpy(float)
    y = fg.made.to_numpy(float)
    w = np.zeros(2)
    X = np.column_stack([np.ones_like(x), x])
    for _ in range(30):
        p = 1 / (1 + np.exp(-X @ w))
        grad = X.T @ (p - y)
        hess = (X * (p * (1 - p))[:, None]).T @ X + 1e-6 * np.eye(2)
        w -= np.linalg.solve(hess, grad)
    fg["exp"] = 1 / (1 + np.exp(-(w[0] + w[1] * fg.kick_distance)))
    decay = np.where(fg.season == through_season, 1.0, 0.5 ** (through_season - fg.season))
    fg["oe"] = (fg.made - fg.exp) * decay
    fg["wt"] = decay
    fg["long_try"] = (fg.kick_distance >= 50) * decay
    fg["long_make"] = (fg.kick_distance >= 50) * fg.made * decay
    k = fg.groupby("kicker_player_id").agg(oe=("oe", "sum"), n=("wt", "sum"), lt=("long_try", "sum"), lm=("long_make", "sum"))
    k["fg_over_expected"] = k.oe / (k.n + 10)  # per attempt, shrunk
    k["long_range"] = (k["lm"] + 0.6 * 3) / (k["lt"] + 3)
    xp = d[d.play_type == "extra_point"].dropna(subset=["kicker_player_id"]).copy()
    xp["good"] = (xp.extra_point_result == "good").astype(float)
    xp["wt"] = np.where(xp.season == through_season, 1.0, 0.5 ** (through_season - xp.season))
    xk = xp.assign(g=xp.good * xp.wt).groupby("kicker_player_id").agg(g=("g", "sum"), n=("wt", "sum"))
    k = k.join(((xk.g + 0.94 * 20) / (xk.n + 20)).rename("xp_rate"), how="outer")
    pu = d[(d.play_type == "punt") & d.punter_player_id.notna() & (d.punt_blocked != 1)].dropna(subset=["kick_distance"]).copy()
    pu["net"] = pu.kick_distance - pu.return_yards.fillna(0) - 20 * pu.touchback.fillna(0)
    spot = pu.groupby((pu.yardline_100 // 5) * 5).net.mean()
    pu["net_oe"] = pu.net - ((pu.yardline_100 // 5) * 5).map(spot)
    pu["wt"] = np.where(pu.season == through_season, 1.0, 0.5 ** (through_season - pu.season))
    pk = pu.assign(o=pu.net_oe * pu.wt, i=pu.punt_inside_twenty.fillna(0) * pu.wt).groupby("punter_player_id").agg(
        o=("o", "sum"), i=("i", "sum"), n=("wt", "sum"))
    pk["net_over_expected"] = pk.o / (pk.n + 15)
    pk["inside_20"] = (pk.i + 0.35 * 15) / (pk.n + 15)
    return k[["fg_over_expected", "long_range", "xp_rate"]].join(pk[["net_over_expected", "inside_20"]], how="outer")
