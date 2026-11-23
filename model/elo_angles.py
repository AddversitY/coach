"""New angles for the Coach ratings, all from free nflverse data.

Each angle is a pregame number per game, built only from earlier weeks:

1. Situations: each offense and defense in third downs, the red zone, the
   two-minute drill, leading or trailing by 8+, and deep throws. Each
   quarterback, rusher and receiver gets the same splits plus blitz vs no
   blitz, play-action vs not, and shotgun vs under center.
2. Coaching and scheme: each head coach's pass rate over expected, fourth-down
   aggressiveness, neutral pace and net EPA (carried with the coach to a new
   team). Free data names head coaches only, not play-callers or
   coordinators. Scheme matchups: how a quarterback does against the blitz
   times how often the opponent blitzes, and the same for play-action.
3. Chemistry and continuity: each quarterback-receiver pair's EPA per target
   beyond what each does with others, and how many games the five offensive
   linemen starting today have started together.
4. Workload and travel: short weeks, byes, miles travelled, time zones
   crossed, body clock (a West Coast team at 1 PM Eastern), and the snaps a
   team played in recent weeks.
5. Referee crews: penalties per game, and how totals and home margins land
   against the closing line in their games.
6. Injuries: the rating value of players listed Out, from the player ratings.

How much each angle counts is learned by the walk-forward backtest (ridge
weights fit on earlier weeks only), never set by hand.
"""

from __future__ import annotations

import math
from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd

from elo_data import BASE, fetch, participation_path, pbp_path
from elo_ratings import week_index

ANGLE_COLUMNS = [
    "game_id", "play_id", "season", "week", "season_type", "posteam", "defteam", "home_team", "away_team",
    "play_type", "epa", "success", "down", "ydstogo", "yardline_100", "half_seconds_remaining",
    "game_seconds_remaining", "score_differential", "shotgun", "no_huddle", "air_yards", "qb_dropback",
    "qb_scramble", "passer_player_id", "receiver_player_id", "rusher_player_id", "pass_oe", "wp", "home_coach",
    "away_coach", "penalty", "drive", "two_point_attempt", "qb_kneel", "qb_spike",
]

# Team-level situations used in game features (offense and defense).
TEAM_SITUATIONS = ("third", "red", "two_min", "lead", "trail", "deep")
# Player-level splits shown in the app.
PLAYER_SITUATIONS = ("third", "red", "two_min", "lead", "trail", "blitz", "no_blitz", "pa", "no_pa",
                     "shotgun", "under_center", "deep", "short")
SITUATION_LABELS = {
    "third": "3rd down", "red": "Red zone", "two_min": "Two-minute", "lead": "Leading by 8+",
    "trail": "Trailing by 8+", "blitz": "Vs blitz", "no_blitz": "No blitz", "pa": "Play-action",
    "no_pa": "No play-action", "shotgun": "Shotgun", "under_center": "Under center", "deep": "Deep (20+ air yds)",
    "short": "Short (<10 air yds)",
}

# Home stadium location (lat, lon) and hours from Eastern time during the season.
TEAM_SITE = {
    "ARI": (33.53, -112.26, -3), "ATL": (33.76, -84.40, 0), "BAL": (39.28, -76.62, 0), "BUF": (42.77, -78.79, 0),
    "CAR": (35.23, -80.85, 0), "CHI": (41.86, -87.62, -1), "CIN": (39.10, -84.52, 0), "CLE": (41.51, -81.70, 0),
    "DAL": (32.75, -97.09, -1), "DEN": (39.74, -105.02, -2), "DET": (42.34, -83.05, 0), "GB": (44.50, -88.06, -1),
    "HOU": (29.68, -95.41, -1), "IND": (39.76, -86.16, 0), "JAX": (30.32, -81.64, 0), "KC": (39.05, -94.48, -1),
    "LA": (34.01, -118.34, -3), "LAC": (34.01, -118.34, -3), "LV": (36.09, -115.18, -3), "MIA": (25.96, -80.24, 0),
    "MIN": (44.97, -93.26, -1), "NE": (42.09, -71.26, 0), "NO": (29.95, -90.08, -1), "NYG": (40.81, -74.07, 0),
    "NYJ": (40.81, -74.07, 0), "PHI": (39.90, -75.17, 0), "PIT": (40.45, -80.02, 0), "SEA": (47.60, -122.33, -3),
    "SF": (37.40, -121.97, -3), "TB": (27.98, -82.50, 0), "TEN": (36.17, -86.77, -1), "WAS": (38.91, -76.86, 0),
    "OAK": (37.75, -122.20, -3), "SD": (32.78, -117.12, -3), "STL": (38.63, -90.19, -1),
}
# Neutral and international sites by stadium id prefix.
FOREIGN_SITE = {
    "LON": (51.55, -0.28, 5), "MEX": (19.30, -99.15, -1), "GER": (48.22, 11.62, 6), "MUN": (48.22, 11.62, 6),
    "FRA": (50.07, 8.65, 6), "SAO": (-23.55, -46.47, 2), "RIO": (-22.91, -43.23, 2), "MEL": (-37.82, 144.98, 16),
    "PAR": (48.92, 2.36, 6), "MAD": (40.45, -3.69, 6), "BUF01": (43.64, -79.39, 0), "DUB": (53.34, -6.23, 5),
}
STADIUM_TEAM = {"ATL": "ATL", "TAM": "TB", "NOR": "NO", "SDG": "SD", "PHO": "ARI", "HOU": "HOU", "JAX": "JAX",
                "DET": "DET", "MIA": "MIA", "DAL": "DAL", "IND": "IND", "NYC": "NYG", "SFO": "SF", "MIN": "MIN",
                "LAX": "LA", "VEG": "LV", "PIT": "PIT", "CLE": "CLE"}


# ---------------------------------------------------------------------------
# Data


def injuries(cache: Path, seasons) -> pd.DataFrame:
    frames = []
    for s in seasons:
        p = fetch(f"{BASE}/injuries/injuries_{s}.parquet", cache / f"inj_{s}.parquet")
        if p is not None:
            frames.append(pd.read_parquet(p, columns=["season", "week", "game_type", "team", "gsis_id", "position",
                                                      "report_status"]))
    if not frames:
        return pd.DataFrame(columns=["season", "week", "team", "gsis_id", "position", "report_status"])
    return pd.concat(frames, ignore_index=True)


def ftn_path(cache: Path, season: int) -> Path | None:
    if season < 2022:
        return None
    return fetch(f"{BASE}/ftn_charting/ftn_charting_{season}.parquet", cache / f"ftn_{season}.parquet")


def angle_plays(cache: Path, season: int) -> pd.DataFrame:
    """Scrimmage plays with situation flags, blitz (5+ rushers) and play-action where charted."""
    out = cache / f"angles_{season}.parquet"
    if out.exists():
        return pd.read_parquet(out)
    d = pd.read_parquet(pbp_path(cache, season), columns=ANGLE_COLUMNS)
    d = d[d.season_type.isin(["REG", "POST"])].drop(columns=["season_type"])
    d["rushers"] = np.nan
    part = participation_path(cache, season)
    if part is not None:
        p = pd.read_parquet(part, columns=["nflverse_game_id", "play_id", "number_of_pass_rushers"])
        p = p.rename(columns={"nflverse_game_id": "game_id"})
        d = d.merge(p, on=["game_id", "play_id"], how="left")
        d["rushers"] = d.pop("number_of_pass_rushers")
    d["pa"] = np.nan
    f = ftn_path(cache, season)
    if f is not None:
        x = pd.read_parquet(f, columns=["nflverse_game_id", "nflverse_play_id", "is_play_action", "n_pass_rushers"])
        x = x.rename(columns={"nflverse_game_id": "game_id", "nflverse_play_id": "play_id"})
        x["play_id"] = pd.to_numeric(x["play_id"], errors="coerce")
        d = d.merge(x, on=["game_id", "play_id"], how="left")
        d["pa"] = d.pop("is_play_action").astype(float)
        d["rushers"] = d["rushers"].fillna(d.pop("n_pass_rushers").astype(float))
    d.to_parquet(out)
    return d


def scrimmage(d: pd.DataFrame) -> pd.DataFrame:
    s = d[d.play_type.isin(["pass", "run"]) & d.epa.notna() & d.posteam.notna()
          & (d.two_point_attempt != 1) & (d.qb_kneel != 1) & (d.qb_spike != 1)].copy()
    s["is_pass"] = (s.qb_dropback == 1)
    s["third"] = s.down == 3
    s["red"] = s.yardline_100 <= 20
    s["two_min"] = s.half_seconds_remaining <= 120
    s["lead"] = s.score_differential >= 8
    s["trail"] = s.score_differential <= -8
    s["deep"] = s.is_pass & (s.air_yards >= 20)
    s["short"] = s.is_pass & (s.air_yards < 10)
    s["shotgun"] = s.shotgun == 1
    s["under_center"] = s.shotgun == 0
    s["blitz"] = s.is_pass & (s.rushers >= 5)
    s["no_blitz"] = s.is_pass & (s.rushers <= 4)
    s["pa"] = s.is_pass & (s["pa"] == 1)
    has_pa = s.groupby("game_id")["pa"].transform("any")
    s["no_pa"] = s.is_pass & has_pa & ~s["pa"]
    s["neutral"] = (s.down <= 2) & s.wp.between(0.2, 0.8) & (s.half_seconds_remaining > 120)
    return s


# ---------------------------------------------------------------------------
# Walk-forward decayed means


class Decayed:
    """Per-key decayed sums. Older weeks count less; a new season counts less again."""

    def __init__(self, half_life: float = 12.0, season_keep: float = 0.6):
        self.d = 0.5 ** (1.0 / half_life)
        self.keep = season_keep
        self.s: dict = {}

    def _decay(self, key, season, wi):
        s, n, last_s, last_wi = self.s[key]
        f = self.d ** max(0, wi - last_wi) * (self.keep ** max(0, season - last_s))
        return s * f, n * f

    def get(self, key, season, wi):
        if key not in self.s:
            return 0.0, 0.0
        return self._decay(key, season, wi)

    def add(self, key, season, wi, s, n):
        if key in self.s:
            s0, n0 = self._decay(key, season, wi)
            s, n = s + s0, n + n0
        self.s[key] = (s, n, season, wi)

    def mean(self, key, season, wi, prior, k):
        s, n = self.get(key, season, wi)
        return (s + k * prior) / (n + k)


def _group(key):
    """Which keys share a league prior: everything in a key but the team, coach, referee or player."""
    if isinstance(key, tuple) and key and key[0] in ("qb", "rec"):
        return key[0]
    if isinstance(key, tuple) and len(key) > 1 and key[0] != "pair":
        return key[1:]
    return "all"


def pregame_walk(obs: pd.DataFrame, queries: pd.DataFrame, k: float, half_life: float = 12.0,
                 season_keep: float = 0.6) -> np.ndarray:
    """Shrunk decayed mean of obs (season, week, key, s, n) for each query (season, week, key), minus the prior.

    Only observations from weeks before the query's week are used. The prior is
    the running league mean, so far, of keys of the same kind (same situation,
    same metric).
    """
    obs = obs.assign(wi=obs.season * 25 + obs.week)
    q = queries.assign(wi=queries.season * 25 + queries.week, i=np.arange(len(queries)))
    out = np.zeros(len(q))
    dec = Decayed(half_life, season_keep)
    tot = defaultdict(lambda: [0.0, 0.0])
    obs_by = {wi: g for wi, g in obs.groupby("wi")}
    q_by = {wi: g for wi, g in q.groupby("wi")}
    for wi in sorted(set(obs_by) | set(q_by)):
        if wi in q_by:
            g = q_by[wi]
            for i, key, season in zip(g.i, g.key, g.season):
                ts, tn = tot.get(_group(key), (0.0, 0.0))
                prior = ts / tn if tn else 0.0
                out[i] = dec.mean(key, int(season), wi, prior, k) - prior
        if wi in obs_by:
            g = obs_by[wi]
            for key, season, s, n in zip(g.key, g.season, g.s, g.n):
                dec.add(key, int(season), wi, float(s), float(n))
                t = tot[_group(key)]
                t[0] += float(s)
                t[1] += float(n)
    return out


def current_walk(obs: pd.DataFrame, keys, season: int, week: int, k: float, half_life: float = 12.0,
                 season_keep: float = 0.6) -> dict:
    """Same shrunk means as of (season, week) for the given keys, plus their decayed sample size."""
    q = pd.DataFrame({"key": list(keys)})
    q["season"], q["week"] = season, week
    vals = pregame_walk(obs, q, k, half_life, season_keep)
    dec = Decayed(half_life, season_keep)
    wi_now = week_index(season, week)
    o = obs[(obs.season * 25 + obs.week) < wi_now].sort_values(["season", "week"])
    for key, s_, w_, s, n in zip(o.key, o.season, o.week, o.s, o.n):
        dec.add(key, int(s_), int(s_) * 25 + int(w_), float(s), float(n))
    return {key: (float(v), dec.get(key, season, wi_now)[1]) for key, v in zip(q.key, vals)}


def _team_side_queries(games: pd.DataFrame) -> pd.DataFrame:
    g = games[["game_id", "season", "week", "home_team", "away_team"]]
    return g


# ---------------------------------------------------------------------------
# 1. Situations


def team_situation_obs(s: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for sit in TEAM_SITUATIONS:
        x = s[s[sit]]
        o = x.groupby(["season", "week", "posteam"]).epa.agg(["sum", "size"]).reset_index()
        o["key"] = list(zip(o.posteam, ["o"] * len(o), [sit] * len(o)))
        d = x.groupby(["season", "week", "defteam"]).epa.agg(["sum", "size"]).reset_index()
        d["key"] = list(zip(d.defteam, ["d"] * len(d), [sit] * len(d)))
        rows += [o[["season", "week", "key", "sum", "size"]], d[["season", "week", "key", "sum", "size"]]]
    return pd.concat(rows, ignore_index=True).rename(columns={"sum": "s", "size": "n"})


def situation_features(games: pd.DataFrame, obs: pd.DataFrame) -> pd.DataFrame:
    feat = pd.DataFrame({"game_id": games.game_id.values})
    for sit in TEAM_SITUATIONS:
        val = {}
        for team_col in ("home_team", "away_team"):
            for unit in ("o", "d"):
                q = pd.DataFrame({"season": games.season.values, "week": games.week.values,
                                  "key": list(zip(games[team_col], [unit] * len(games), [sit] * len(games)))})
                val[(team_col, unit)] = pregame_walk(obs, q, k=60)
        # Positive = good for that offense: its EPA plus what the other defense allows.
        h_edge = val[("home_team", "o")] + val[("away_team", "d")]
        a_edge = val[("away_team", "o")] + val[("home_team", "d")]
        feat[f"s_{sit}"] = h_edge - a_edge
        feat[f"s_{sit}_sum"] = h_edge + a_edge
    return feat


def player_situations(s: pd.DataFrame, season: int, week: int) -> dict:
    """player -> {role, n, splits: {situation: shrunk EPA/play minus his overall}} as of (season, week)."""
    s = s[(s.season * 25 + s.week) < week_index(season, week)]
    s = s[s.season >= season - 2]
    w = np.where(s.season == season, 1.0, np.where(s.season == season - 1, 0.6, 0.35))
    s = s.assign(w=w, we=s.epa * w)
    out = {}
    for role, col, base in (("passer", "passer_player_id", s.is_pass), ("rusher", "rusher_player_id", ~s.is_pass),
                            ("receiver", "receiver_player_id", s.is_pass)):
        x = s[base & s[col].notna()]
        tot = x.groupby(col).agg(e=("we", "sum"), n=("w", "sum"))
        overall = (tot.e / (tot.n + 30)).rename("overall")
        for sit in PLAYER_SITUATIONS:
            y = x[x[sit]]
            if y.empty:
                continue
            g = y.groupby(col).agg(e=("we", "sum"), n=("w", "sum"))
            g = g.join(overall, how="left")
            k = 25.0
            g["split"] = (g.e + k * g.overall) / (g.n + k)
            for pid, r in g.iterrows():
                d = out.setdefault((pid, role), {"n": float(tot.n.get(pid, 0.0)), "splits": {}, "counts": {}})
                d["splits"][sit] = float(r.split)
                d["counts"][sit] = float(r.n)
    return out


# ---------------------------------------------------------------------------
# 2. Coaching and scheme


def coach_obs(s: pd.DataFrame, raw: pd.DataFrame) -> pd.DataFrame:
    s = s.assign(coach=np.where(s.posteam == s.home_team, s.home_coach, s.away_coach))
    neutral = s[s.neutral]
    rows = []
    a = neutral.groupby(["season", "week", "coach"]).pass_oe.agg(["sum", "count"]).reset_index()
    a["metric"] = "proe"
    rows.append(a.rename(columns={"sum": "s", "count": "n"}))
    # Pace: seconds between snaps inside a drive, neutral situations only.
    n2 = neutral.sort_values(["game_id", "play_id"]).copy()
    n2["gap"] = n2.groupby(["game_id", "drive"]).game_seconds_remaining.diff(-1)
    n2 = n2[n2.gap.between(5, 60)]
    b = n2.groupby(["season", "week", "coach"]).gap.agg(["sum", "count"]).reset_index()
    b["metric"] = "pace"
    rows.append(b.rename(columns={"sum": "s", "count": "n"}))
    # Fourth-down aggressiveness: go rate on 4th and 3 or less from the opponent's 60 in.
    r = raw[(raw.down == 4) & (raw.ydstogo <= 3) & (raw.yardline_100 <= 60) & (raw.half_seconds_remaining > 120)
            & raw.wp.between(0.1, 0.9) & raw.play_type.isin(["pass", "run", "punt", "field_goal"])].copy()
    r["coach"] = np.where(r.posteam == r.home_team, r.home_coach, r.away_coach)
    r["go"] = r.play_type.isin(["pass", "run"]).astype(float)
    c = r.groupby(["season", "week", "coach"]).go.agg(["sum", "size"]).reset_index()
    c["metric"] = "go4"
    rows.append(c.rename(columns={"sum": "s", "size": "n"}))
    # Net EPA per play of the coach's team (offense minus defense), carried with the coach.
    s2 = s.assign(dcoach=np.where(s.defteam == s.home_team, s.home_coach, s.away_coach))
    o = s2.groupby(["season", "week", "coach"]).epa.agg(["sum", "size"]).reset_index()
    d = s2.groupby(["season", "week", "dcoach"]).epa.agg(["sum", "size"]).reset_index().rename(columns={"dcoach": "coach"})
    d["sum"] = -d["sum"]
    net = pd.concat([o, d]).groupby(["season", "week", "coach"]).sum().reset_index()
    net["metric"] = "net"
    rows.append(net.rename(columns={"sum": "s", "size": "n"}))
    out = pd.concat(rows, ignore_index=True)
    out["key"] = list(zip(out.coach, out.metric))
    return out[["season", "week", "key", "s", "n"]]


COACH_K = {"proe": 150, "pace": 150, "go4": 15, "net": 400}


def scheme_obs(s: pd.DataFrame) -> pd.DataFrame:
    """Offense EPA vs blitz / no blitz and with / without play-action; defense blitz and play-action rates."""
    rows = []
    for col, unit in (("posteam", "o"), ("defteam", "d")):
        for sit in ("blitz", "no_blitz", "pa", "no_pa"):
            x = s[s[sit]]
            g = x.groupby(["season", "week", col]).epa.agg(["sum", "size"]).reset_index()
            g["key"] = list(zip(g[col], [unit] * len(g), [sit] * len(g)))
            rows.append(g.rename(columns={"sum": "s", "size": "n"})[["season", "week", "key", "s", "n"]])
    db = s[s.is_pass & s.rushers.notna()]
    g = db.groupby(["season", "week", "defteam"]).blitz.agg(["sum", "size"]).reset_index()
    g["key"] = list(zip(g.defteam, ["d"] * len(g), ["blitz_rate"] * len(g)))
    rows.append(g.rename(columns={"sum": "s", "size": "n"})[["season", "week", "key", "s", "n"]])
    pa = s[s.is_pass & s.game_id.isin(s.loc[s["pa"], "game_id"].unique())]
    g = pa.groupby(["season", "week", "posteam"])["pa"].agg(["sum", "size"]).reset_index()
    g["key"] = list(zip(g.posteam, ["o"] * len(g), ["pa_rate"] * len(g)))
    rows.append(g.rename(columns={"sum": "s", "size": "n"})[["season", "week", "key", "s", "n"]])
    return pd.concat(rows, ignore_index=True)


def coach_scheme_features(games: pd.DataFrame, cobs: pd.DataFrame, sobs: pd.DataFrame) -> pd.DataFrame:
    feat = pd.DataFrame({"game_id": games.game_id.values})
    n = len(games)
    base = {"season": games.season.values, "week": games.week.values}
    val = {}
    for side in ("home", "away"):
        coach = games[f"{side}_coach"].fillna("").values
        for m, k in COACH_K.items():
            val[(side, m)] = pregame_walk(cobs, pd.DataFrame({**base, "key": list(zip(coach, [m] * n))}), k=k)
        team = games[f"{side}_team"].values
        for unit, sit in (("o", "blitz"), ("o", "no_blitz"), ("o", "pa"), ("o", "no_pa"), ("d", "pa"), ("d", "no_pa")):
            val[(side, unit, sit)] = pregame_walk(sobs, pd.DataFrame({**base, "key": list(zip(team, [unit] * n, [sit] * n))}), k=80)
        val[(side, "blitz_rate")] = pregame_walk(sobs, pd.DataFrame({**base, "key": list(zip(team, ["d"] * n, ["blitz_rate"] * n))}), k=100)
        val[(side, "pa_rate")] = pregame_walk(sobs, pd.DataFrame({**base, "key": list(zip(team, ["o"] * n, ["pa_rate"] * n))}), k=100)
    feat["c_net"] = val[("home", "net")] - val[("away", "net")]
    feat["c_go4"] = val[("home", "go4")] - val[("away", "go4")]
    feat["c_proe"] = val[("home", "proe")] - val[("away", "proe")]
    feat["c_proe_sum"] = val[("home", "proe")] + val[("away", "proe")]
    feat["c_pace_sum"] = val[("home", "pace")] + val[("away", "pace")]
    # Scheme matchups: an offense's blitz gap times how much more than average the defense blitzes,
    # and play-action gap (offense's gain plus what the defense gives up) times the offense's PA usage.
    for side, other in (("home", "away"), ("away", "home")):
        blitz_gap = val[(side, "o", "blitz")] - val[(side, "o", "no_blitz")]
        val[(side, "blitz_edge")] = blitz_gap * val[(other, "blitz_rate")]
        pa_gap = (val[(side, "o", "pa")] - val[(side, "o", "no_pa")]) + (val[(other, "d", "pa")] - val[(other, "d", "no_pa")])
        val[(side, "pa_edge")] = pa_gap * (0.25 + val[(side, "pa_rate")])
    feat["x_blitz"] = val[("home", "blitz_edge")] - val[("away", "blitz_edge")]
    feat["x_pa"] = val[("home", "pa_edge")] - val[("away", "pa_edge")]
    feat["x_blitz_sum"] = val[("home", "blitz_edge")] + val[("away", "blitz_edge")]
    feat["x_pa_sum"] = val[("home", "pa_edge")] + val[("away", "pa_edge")]
    return feat


# ---------------------------------------------------------------------------
# 3. Chemistry and offensive-line continuity


def pair_obs(s: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    t = s[s.is_pass & s.passer_player_id.notna() & s.receiver_player_id.notna()]
    pair = t.groupby(["season", "week", "passer_player_id", "receiver_player_id"]).epa.agg(["sum", "size"]).reset_index()
    pair["key"] = list(zip(["pair"] * len(pair), pair.passer_player_id, pair.receiver_player_id))
    qb = t.groupby(["season", "week", "passer_player_id"]).epa.agg(["sum", "size"]).reset_index()
    qb["key"] = list(zip(["qb"] * len(qb), qb.passer_player_id))
    wr = t.groupby(["season", "week", "receiver_player_id"]).epa.agg(["sum", "size"]).reset_index()
    wr["key"] = list(zip(["rec"] * len(wr), wr.receiver_player_id))
    share = t.groupby(["season", "week", "posteam", "receiver_player_id"]).size().rename("n").reset_index()
    ren = {"sum": "s", "size": "n"}
    return (pair.rename(columns=ren)[["season", "week", "key", "s", "n"]],
            pd.concat([qb.rename(columns=ren), wr.rename(columns=ren)])[["season", "week", "key", "s", "n"]],
            share)


def chemistry_features(games: pd.DataFrame, pobs: pd.DataFrame, iobs: pd.DataFrame, share: pd.DataFrame) -> pd.DataFrame:
    """Share-weighted chemistry of today's QB with the team's recent receivers."""
    # Each team's receivers by decayed targets before the week (top 5).
    targets = defaultdict(lambda: defaultdict(float))
    by_week = {wi: g for wi, g in share.assign(wi=share.season * 25 + share.week).groupby("wi")}
    wis = games.season.values * 25 + games.week.values
    order = np.argsort(wis, kind="stable")
    queries = []  # (row, side, qb, receiver, weight)
    seen = sorted(by_week)
    j = 0
    for i in order:
        wi = wis[i]
        while j < len(seen) and seen[j] < wi:
            for team in list(targets):
                for r in targets[team]:
                    targets[team][r] *= 0.8
            for team, rec, n in zip(by_week[seen[j]].posteam, by_week[seen[j]].receiver_player_id, by_week[seen[j]].n):
                targets[team][rec] += n
            j += 1
        g = games.iloc[i]
        for side in ("home", "away"):
            team, qb = g[f"{side}_team"], g[f"{side}_qb_id"]
            if not isinstance(qb, str) or team not in targets:
                continue
            top = sorted(targets[team].items(), key=lambda kv: -kv[1])[:5]
            tot = sum(v for _, v in top)
            for rec, v in top:
                if tot > 0:
                    queries.append((i, side, qb, rec, v / tot, g.season, g.week))
    feat = pd.DataFrame({"game_id": games.game_id.values, "ch_pair": 0.0})
    if not queries:
        return feat
    q = pd.DataFrame(queries, columns=["row", "side", "qb", "rec", "w", "season", "week"])
    pair_val = pregame_walk(pobs, pd.DataFrame({"season": q.season, "week": q.week, "key": list(zip(["pair"] * len(q), q.qb, q.rec))}),
                            k=40, half_life=25, season_keep=0.8)
    qb_val = pregame_walk(iobs, pd.DataFrame({"season": q.season, "week": q.week, "key": list(zip(["qb"] * len(q), q.qb))}),
                          k=40, half_life=25, season_keep=0.8)
    rec_val = pregame_walk(iobs, pd.DataFrame({"season": q.season, "week": q.week, "key": list(zip(["rec"] * len(q), q.rec))}),
                           k=40, half_life=25, season_keep=0.8)
    # Chemistry = the pair beyond what the QB and the receiver each do (both already vs league average).
    q["chem"] = pair_val - 0.5 * (qb_val + rec_val)
    q["v"] = q.chem * q.w * np.where(q.side == "home", 1.0, -1.0)
    agg = q.groupby("row").v.sum()
    feat.loc[agg.index, "ch_pair"] = agg.values
    return feat


def ol_continuity(snaps: pd.DataFrame, games: pd.DataFrame) -> pd.DataFrame:
    """Games the five offensive linemen starting today had previously started together (last 17),
    and how many of them did not start the team's previous game."""
    ol = snaps[snaps.position.isin(["T", "G", "C", "OL", "OT", "OG"]) & snaps.gsis_id.notna()]
    ol = ol.sort_values("offense_pct", ascending=False).groupby(["game_id", "team"]).head(5)
    five = ol.groupby(["game_id", "team"]).gsis_id.apply(frozenset)
    meta = games.set_index("game_id")[["season", "week", "gameday"]]
    hist: dict = defaultdict(list)  # team -> list of (order, five)
    rows = {}
    keys = sorted(five.index, key=lambda k: (meta.loc[k[0], "season"], meta.loc[k[0], "week"], meta.loc[k[0], "gameday"])
                  if k[0] in meta.index else (0, 0, ""))
    for gid, team in keys:
        if gid not in meta.index:
            continue
        cur = five[(gid, team)]
        past = hist[team][-17:]
        together = sum(1 for p in past if len(cur & p) >= 5)
        new = len(cur - past[-1]) if past else 0
        rows[(gid, team)] = (together, new)
        hist[team].append(cur)
    feat = pd.DataFrame({"game_id": games.game_id.values})
    for side in ("home", "away"):
        vals = [rows.get((g, t), (np.nan, np.nan)) for g, t in zip(games.game_id, games[f"{side}_team"])]
        feat[f"{side}_ol_together"] = [v[0] for v in vals]
        feat[f"{side}_ol_new"] = [v[1] for v in vals]
    # Team codes in snap counts can differ for old relocations; missing -> league-typical values.
    for c in ("home_ol_together", "away_ol_together"):
        feat[c] = feat[c].fillna(6.0).clip(upper=17)
    for c in ("home_ol_new", "away_ol_new"):
        feat[c] = feat[c].fillna(0.5)
    feat["ol_cont"] = np.log1p(feat.home_ol_together) - np.log1p(feat.away_ol_together)
    feat["ol_new"] = feat.home_ol_new - feat.away_ol_new
    return feat[["game_id", "ol_cont", "ol_new"]]


# ---------------------------------------------------------------------------
# 4. Workload, rest and travel


def _site(stadium_id, home_team, location):
    sid = str(stadium_id) if isinstance(stadium_id, str) else ""
    if sid in FOREIGN_SITE:
        return FOREIGN_SITE[sid]
    if sid[:3] in FOREIGN_SITE:
        return FOREIGN_SITE[sid[:3]]
    if location == "Neutral" and sid[:3] in STADIUM_TEAM:
        return TEAM_SITE[STADIUM_TEAM[sid[:3]]]
    return TEAM_SITE.get(home_team, (39.0, -95.0, -1))


def miles(a, b) -> float:
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 3959 * 2 * math.asin(math.sqrt(h))


def travel_rows(games: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for g in games.itertuples(index=False):
        site = _site(g.stadium_id, g.home_team, g.location)
        try:
            kick = int(str(g.gametime).split(":")[0])
        except ValueError:
            kick = 13
        r = {"game_id": g.game_id}
        for side in ("home", "away"):
            team = getattr(g, f"{side}_team")
            home = TEAM_SITE.get(team, site)
            r[f"{side}_miles"] = miles(home, site)
            r[f"{side}_tz"] = site[2] - home[2]  # + = travelled east
            local_kick = kick + home[2]  # kickoff on the team's own body clock
            r[f"{side}_early"] = 1.0 if local_kick <= 10 else 0.0
            r[f"{side}_late"] = 1.0 if local_kick >= 20 else 0.0
            rest = getattr(g, f"{side}_rest")
            r[f"{side}_rest"] = float(rest) if pd.notna(rest) else 7.0
        rows.append(r)
    return pd.DataFrame(rows)


def workload_features(games: pd.DataFrame, s: pd.DataFrame) -> pd.DataFrame:
    t = travel_rows(games)
    feat = pd.DataFrame({"game_id": t.game_id})
    feat["w_short"] = (t.home_rest <= 5).astype(float) - (t.away_rest <= 5).astype(float)
    feat["w_bye"] = (t.home_rest >= 12).astype(float) - (t.away_rest >= 12).astype(float)
    feat["w_miles"] = (t.home_miles - t.away_miles) / 1000.0
    feat["w_tz"] = t.home_tz.abs() - t.away_tz.abs()
    feat["w_body"] = (t.home_early + 0.5 * t.home_late) - (t.away_early + 0.5 * t.away_late)
    # Snaps played: offense + defense plays in the previous game and the previous three.
    plays = pd.concat([s.groupby(["game_id", "posteam"]).size().rename("n").reset_index().rename(columns={"posteam": "team"}),
                       s.groupby(["game_id", "defteam"]).size().rename("n").reset_index().rename(columns={"defteam": "team"})])
    plays = plays.groupby(["game_id", "team"]).n.sum().reset_index()
    meta = games[["game_id", "season", "week", "gameday"]]
    plays = plays.merge(meta, on="game_id").sort_values(["season", "week", "gameday"])
    plays["last1"] = plays.groupby(["team", "season"]).n.shift(1)
    plays["last3"] = plays.groupby(["team", "season"]).n.transform(lambda x: x.shift(1).rolling(3, min_periods=1).sum())
    lk = plays.set_index(["game_id", "team"])
    for side in ("home", "away"):
        idx = list(zip(games.game_id, games[f"{side}_team"]))
        l1 = lk.last1.reindex(idx).to_numpy(float)
        l3 = lk.last3.reindex(idx).to_numpy(float)
        feat[f"{side}_l1"] = np.nan_to_num(l1 - 128.0)
        feat[f"{side}_l3"] = np.nan_to_num(l3 / 3.0 - 128.0) * (~np.isnan(l3))
    feat["w_snaps1"] = (feat.home_l1 - feat.away_l1) / 10.0
    feat["w_snaps3"] = (feat.home_l3 - feat.away_l3) / 10.0
    return feat.drop(columns=["home_l1", "away_l1", "home_l3", "away_l3"])


# ---------------------------------------------------------------------------
# 5. Referee crews


def penalty_counts(raw: pd.DataFrame) -> pd.Series:
    return raw[raw.penalty == 1].groupby("game_id").size()


def referee_obs(games: pd.DataFrame, pens: pd.Series) -> pd.DataFrame:
    g = games[games.result.notna() & games.referee.notna()].copy()
    g["pens"] = g.game_id.map(pens)
    rows = []
    for metric, val in (("pens", g.pens), ("total", g.total - g.total_line), ("home", g.result - g.spread_line)):
        x = pd.DataFrame({"season": g.season, "week": g.week, "key": list(zip(g.referee, [metric] * len(g))),
                          "s": val.values, "n": 1.0})
        rows.append(x[x.s.notna()])
    return pd.concat(rows, ignore_index=True)


REF_K = {"pens": 8, "total": 40, "home": 40}


def referee_features(games: pd.DataFrame, robs: pd.DataFrame) -> pd.DataFrame:
    feat = pd.DataFrame({"game_id": games.game_id.values})
    ref = games.referee.fillna("").values
    for metric, k in REF_K.items():
        q = pd.DataFrame({"season": games.season.values, "week": games.week.values, "key": list(zip(ref, [metric] * len(games)))})
        v = pregame_walk(robs, q, k=k, half_life=60, season_keep=0.85)
        feat[f"r_{metric}"] = np.where(ref == "", 0.0, v)
    return feat


# ---------------------------------------------------------------------------
# 6. Injuries


def outs_by_team_week(inj: pd.DataFrame) -> dict:
    x = inj[inj.report_status.isin(["Out", "Doubtful"]) & inj.gsis_id.notna()]
    out = defaultdict(set)
    for season, week, team, pid in zip(x.season, x.week, x.team, x.gsis_id):
        out[(int(season), int(week), team)].add(pid)
    return out


def injury_features(games: pd.DataFrame, lineups: dict, epa: dict, outs: dict):
    """Player ratings walked forward (same as elo_players), plus the value of players listed Out.

    Value lost for a side = sum over its Out players (QBs excluded: the starting QB is already
    in the team model) of recent snap share x rating, offense pass+run and defense pass+run.
    """
    from elo_players import PlayerRatings

    pr = PlayerRatings()
    team_players = defaultdict(set)
    rows = []
    games = games.sort_values(["season", "week", "gameday", "game_id"])
    for (season, week), block in games.groupby(["season", "week"], sort=True):
        season, week = int(season), int(week)
        wi = week_index(season, week)
        done = []
        for g in block.itertuples(index=False):
            lu = {(side, unit): lineups.get((g.game_id, side, unit), []) for side in ("home", "away") for unit in ("off", "def")}
            r = {"game_id": g.game_id}
            lost = {}
            for side in ("home", "away"):
                team = getattr(g, f"{side}_team")
                o = outs.get((season, week, team), set())
                lp = lr = 0.0
                n_out = 0
                for pid in o:
                    hist = pr.recent.get(pid)
                    pos = pr.position.get(pid)
                    if not hist or pos == "QB":
                        continue
                    share = float(np.mean(hist))
                    if share < 0.25:
                        continue
                    n_out += 1
                    # Offense and defense ratings are both "higher = better for his team".
                    for unit in ("off", "def"):
                        lp += share * pr.books[(unit, "pass")].get(pid, season, wi)[0]
                        lr += share * pr.books[(unit, "run")].get(pid, season, wi)[0]
                lost[side] = (lp, lr, n_out)
            # Positive = the home side lost less (good for home).
            r["i_pass"] = lost["away"][0] - lost["home"][0]
            r["i_run"] = lost["away"][1] - lost["home"][1]
            r["i_n"] = lost["away"][2] - lost["home"][2]
            r["i_n_sum"] = lost["away"][2] + lost["home"][2]
            rows.append(r)
            if pd.notna(g.result) and lu[("home", "off")] and lu[("away", "off")]:
                done.append((g.game_id, lu))
        for gid, lu in done:
            for side, other in (("home", "away"), ("away", "home")):
                e = epa.get((gid, side))
                if not e:
                    continue
                pr.update(lu[(side, "off")], lu[(other, "def")], "pass", e[0], e[1], season, wi)
                pr.update(lu[(side, "off")], lu[(other, "def")], "run", e[2], e[3], season, wi)
            for lineup in lu.values():
                pr.remember(lineup)
    return pd.DataFrame(rows), pr


# ---------------------------------------------------------------------------
# Everything together


ANGLE_GROUPS = {
    "situations": (["s_third", "s_red", "s_two_min", "s_lead", "s_trail", "s_deep"],
                   ["s_third_sum", "s_red_sum", "s_two_min_sum", "s_lead_sum", "s_trail_sum", "s_deep_sum"]),
    "coachingScheme": (["c_net", "c_go4", "c_proe", "x_blitz", "x_pa"], ["c_proe_sum", "c_pace_sum", "x_blitz_sum", "x_pa_sum"]),
    "chemistryContinuity": (["ch_pair", "ol_cont", "ol_new"], []),
    "workloadTravel": (["w_short", "w_bye", "w_miles", "w_tz", "w_body", "w_snaps1", "w_snaps3"], []),
    "referee": (["r_home"], ["r_pens", "r_total"]),
    "injuries": (["i_pass", "i_run", "i_n"], ["i_n_sum"]),
}


class AngleData:
    """Everything the angles need, loaded once."""

    def __init__(self, cache: Path, seasons):
        raw = pd.concat([angle_plays(cache, s) for s in seasons], ignore_index=True)
        self.raw = raw
        self.s = scrimmage(raw)
        self.pens = penalty_counts(raw)
        self.inj = injuries(cache, [s for s in seasons if s >= 2009])


def build_angles(games: pd.DataFrame, data: AngleData, snaps: pd.DataFrame, lineups: dict, epa: dict):
    """Pregame angle features for every game (game_id + columns in ANGLE_GROUPS), and state for the app."""
    g = games.sort_values(["season", "week", "gameday", "game_id"]).reset_index(drop=True)
    s = data.s
    sit_obs = team_situation_obs(s)
    cobs = coach_obs(s, data.raw)
    sobs = scheme_obs(s)
    pobs, iobs, share = pair_obs(s)
    robs = referee_obs(g, data.pens)
    outs = outs_by_team_week(data.inj)
    parts = [situation_features(g, sit_obs), coach_scheme_features(g, cobs, sobs),
             chemistry_features(g, pobs, iobs, share), ol_continuity(snaps, g), workload_features(g, s),
             referee_features(g, robs)]
    inj, pr = injury_features(g[g.season >= 2013], lineups, epa, outs)
    feat = parts[0]
    for p in parts[1:] + [inj]:
        feat = feat.merge(p, on="game_id", how="left")
    cols = [c for grp in ANGLE_GROUPS.values() for side in grp for c in side]
    feat[cols] = feat[cols].fillna(0.0)
    state = {"sit_obs": sit_obs, "cobs": cobs, "sobs": sobs, "pobs": pobs, "iobs": iobs, "share": share,
             "robs": robs, "outs": outs, "pr": pr}
    return feat, state


# ---------------------------------------------------------------------------
# Current values for the app


def _pct(values: dict, higher: bool = True) -> dict:
    if not values:
        return {}
    s = pd.Series(values, dtype=float)
    r = s.rank(pct=True) if higher else (-s).rank(pct=True)
    return {k: int(round(40 + 59 * v)) for k, v in r.items()}


SIT_MIN = {"passer": 120.0, "rusher": 50.0, "receiver": 30.0}
SIT_MIN_SPLIT = {"passer": 25.0, "rusher": 10.0, "receiver": 8.0}
ROLE_OF = {"QB": "passer", "RB": "rusher", "FB": "rusher", "WR": "receiver", "TE": "receiver"}


def situation_ratings(s: pd.DataFrame, season: int, week: int, positions: dict) -> dict:
    """player -> {situation label: 40-99 among his role}, only with enough plays in that situation."""
    raw = player_situations(s, season, week)
    out: dict = defaultdict(dict)
    for role in ("passer", "rusher", "receiver"):
        for sit in PLAYER_SITUATIONS:
            vals = {pid: d["splits"][sit] for (pid, r), d in raw.items()
                    if r == role and ROLE_OF.get(positions.get(pid)) == role and d["n"] >= SIT_MIN[role]
                    and d["counts"].get(sit, 0) >= SIT_MIN_SPLIT[role] and sit in d["splits"]}
            if len(vals) < 10:
                continue
            for pid, v in _pct(vals).items():
                out[pid][SITUATION_LABELS[sit]] = v
    return dict(out)


def current_angles(games: pd.DataFrame, data: AngleData, snaps: pd.DataFrame, state: dict, names: dict,
                   season: int, week: int) -> dict:
    """Team angles and the upcoming week's game angles, as of before (season, week)."""
    s = data.s
    g = games[games.season == season]
    teams = sorted(set(g.home_team) | set(g.away_team))
    # Latest head coach per team.
    played = g.sort_values(["week", "gameday"])
    coach = {}
    for r in played.itertuples(index=False):
        if isinstance(r.home_coach, str):
            coach[r.home_team] = r.home_coach
        if isinstance(r.away_coach, str):
            coach[r.away_team] = r.away_coach
    cvals = {}
    for m, k in COACH_K.items():
        cur = current_walk(state["cobs"], [(c, m) for c in coach.values()], season, week, k)
        cvals[m] = {c: v for (c, _), (v, _) in cur.items()}
    # Raw tendencies this season for display (not shrunk).
    this = s[(s.season == season) & (s.week < week)]
    this = this.assign(coach_=np.where(this.posteam == this.home_team, this.home_coach, this.away_coach))
    proe_raw = this[this.neutral].groupby("posteam").pass_oe.mean()
    rw = data.raw[(data.raw.season == season) & (data.raw.week < week) & (data.raw.down == 4) & (data.raw.ydstogo <= 3)
                  & (data.raw.yardline_100 <= 60) & (data.raw.half_seconds_remaining > 120) & data.raw.wp.between(0.1, 0.9)
                  & data.raw.play_type.isin(["pass", "run", "punt", "field_goal"])]
    go_raw = rw.assign(go=rw.play_type.isin(["pass", "run"])).groupby("posteam").go.agg(["mean", "size"])
    blitz_raw = this[this.is_pass & this.rushers.notna()].groupby("defteam").blitz.mean()
    pa_games = this.loc[this["pa"], "game_id"].unique()
    pa_raw = this[this.is_pass & this.game_id.isin(pa_games)].groupby("posteam")["pa"].mean()
    # Chemistry: best pair per team this season and last (pair beyond what each does alone).
    pc = current_walk(state["pobs"], state["pobs"].key.unique(), season, week, 40, 25, 0.8)
    t = s[s.is_pass & s.passer_player_id.notna() & s.receiver_player_id.notna() & (s.season == season) & (s.week < week)]
    pairs = t.groupby(["posteam", "passer_player_id", "receiver_player_id"]).size().rename("n").reset_index()
    ind = current_walk(state["iobs"], [("qb", q) for q in pairs.passer_player_id.unique()]
                       + [("rec", r) for r in pairs.receiver_player_id.unique()], season, week, 40, 25, 0.8)
    chem = {}
    for r in pairs[pairs.n >= 25].itertuples(index=False):
        v = pc.get(("pair", r.passer_player_id, r.receiver_player_id), (0.0, 0.0))[0] \
            - 0.5 * (ind.get(("qb", r.passer_player_id), (0.0, 0))[0] + ind.get(("rec", r.receiver_player_id), (0.0, 0))[0])
        best = chem.get(r.posteam)
        if best is None or v > best["v"]:
            chem[r.posteam] = {"qb": names.get(r.passer_player_id, r.passer_player_id),
                               "rec": names.get(r.receiver_player_id, r.receiver_player_id),
                               "v": round(float(v), 3), "targets": int(r.n)}
    # Offensive line: games the latest five have started together this season.
    ol = snaps[(snaps.season == season) & snaps.position.isin(["T", "G", "C", "OL", "OT", "OG"]) & snaps.gsis_id.notna()]
    ol = ol.sort_values("offense_pct", ascending=False).groupby(["game_id", "team", "week"]).head(5)
    five = ol.groupby(["team", "week"]).gsis_id.apply(frozenset).reset_index().sort_values("week")
    together = {}
    for team, grp in five.groupby("team"):
        last = grp.gsis_id.iloc[-1]
        together[team] = int(sum(1 for f in grp.gsis_id if len(last & f) >= 5))
    # Injuries: players listed Out or Doubtful for the coming week, with their rating value.
    pr = state["pr"]
    wi = week_index(season, week)
    outs = state["outs"]
    teams_out = {}
    for team in teams:
        lst = []
        for pid in outs.get((season, week, team), set()):
            hist = pr.recent.get(pid)
            if not hist:
                continue
            share = float(np.mean(hist))
            if share < 0.25:
                continue
            # Points a game: rating (EPA per play) x his share x about 35 passes and 27 runs a side.
            val = 0.0
            for unit in ("off", "def"):
                for kind, plays_ in (("pass", 35), ("run", 27)):
                    val += share * plays_ * pr.books[(unit, kind)].get(pid, season, wi)[0]
            lst.append({"n": names.get(pid, pid), "p": pr.position.get(pid, ""), "pts": round(float(val), 1)})
        lst.sort(key=lambda x: -abs(x["pts"]))
        if lst:
            teams_out[team] = lst[:6]
    cpct = {m: _pct(cvals[m], higher=(m != "pace")) for m in cvals}
    out_teams = {}
    for team in teams:
        c = coach.get(team)
        row = {}
        if c:
            row["coach"] = c
            for m in ("net", "proe", "go4", "pace"):
                if c in cpct[m]:
                    row[{"net": "coachNet", "proe": "passHeavy", "go4": "fourthDown", "pace": "tempo"}[m]] = cpct[m][c]
        if team in proe_raw:
            row["proe"] = round(float(proe_raw[team]), 1)
        if team in go_raw.index and go_raw.loc[team, "size"] >= 3:
            row["go4"] = round(float(go_raw.loc[team, "mean"]), 2)
            row["go4n"] = int(go_raw.loc[team, "size"])
        if team in blitz_raw:
            row["blitz"] = round(float(blitz_raw[team]), 3)
        if team in pa_raw:
            row["pa"] = round(float(pa_raw[team]), 3)
        if team in together:
            row["olTogether"] = together[team]
        if team in chem:
            row["chem"] = chem[team]
        if team in teams_out:
            row["out"] = teams_out[team]
            row["outPts"] = round(float(sum(x["pts"] for x in teams_out[team])), 1)
        out_teams[team] = row
    # Upcoming games: rest, travel, body clock and referee crew.
    up = g[(g.week == week)]
    trav = travel_rows(up).set_index("game_id") if len(up) else pd.DataFrame()
    ref_shrunk = {}
    for r in up.referee.dropna().unique():
        ref_shrunk[r] = {m: current_walk(state["robs"], [(r, m)], season, week, REF_K[m], 60, 0.85)[(r, m)] for m in REF_K}
    upcoming = []
    for r in up.itertuples(index=False):
        tv = trav.loc[r.game_id]
        row = {"h": r.home_team, "a": r.away_team, "restH": int(tv.home_rest), "restA": int(tv.away_rest),
               "milesA": int(round(tv.away_miles)), "milesH": int(round(tv.home_miles)),
               "tzA": int(tv.away_tz), "tzH": int(tv.home_tz)}
        for side, code in (("home", r.home_team), ("away", r.away_team)):
            if tv[f"{side}_early"]:
                row.setdefault("early", []).append(code)
        if isinstance(r.referee, str):
            rs = ref_shrunk[r.referee]
            row["ref"] = r.referee
            row["refGames"] = int(round(rs["pens"][1]))
            row["refPens"] = round(rs["pens"][0], 1)
            row["refTotal"] = round(rs["total"][0], 1)
            row["refHome"] = round(rs["home"][0], 1)
        upcoming.append(row)
    return {"teams": out_teams, "upcoming": upcoming}
