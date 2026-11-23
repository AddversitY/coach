"""Player skill ratings built from many free variables, weighted by what predicts.

For every quarterback, receiver, tight end and running back, before each game,
we summarize everything he has done in earlier games (all seasons, recent games
counting more, small samples pulled toward the position average):

- opportunity: snap share, target share, air-yard share, targets per pass play
  on the field, red-zone target share, carry share, goal-line carry share
- efficiency: yards per target, EPA per target, first downs per target, catch
  rate, depth of target, yards after catch, touchdowns per target, yards per
  carry, rushing EPA, success rate
- Next Gen Stats (2016+): separation, cushion, YAC over expected, rushing
  yards over expected, completion % over expected, time to throw,
  aggressiveness
- context: the quarterbacks who threw to him and the defenses he faced
  (from the Kalman ratings in elo_props), age, years in the league, draft slot

A ridge regression learns how much each variable is worth by asking which
ones predicted the NEXT game's production per opportunity, using only
earlier seasons. The rating is that prediction; the 40-99 overall is its
percentile within the position. Nothing here feeds Coach's chance.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

from elo_data import BASE, fetch, pbp_path

HALF_LIFE_GAMES = 16.0
SEASON_DECAY = 0.75  # extra fade at each new season
TRAIN_LAST = 2022    # weights are learned on seasons up to here for the test

SKILL_COLUMNS = [
    "game_id", "season", "week", "season_type", "posteam", "defteam", "play_type", "qb_dropback",
    "qb_scramble", "sack", "epa", "success", "yards_gained", "yardline_100", "complete_pass",
    "interception", "air_yards", "yards_after_catch", "first_down", "pass_touchdown", "rush_touchdown",
    "passer_player_id", "receiver_player_id", "rusher_player_id", "cpoe", "two_point_attempt",
    "qb_kneel", "qb_spike",
]


def skill_plays(cache: Path, season: int) -> pd.DataFrame:
    out = cache / f"skill_{season}.parquet"
    if out.exists():
        return pd.read_parquet(out)
    raw = pd.read_parquet(pbp_path(cache, season), columns=SKILL_COLUMNS)
    raw = raw[raw.season_type.isin(["REG", "POST"]) & raw.play_type.isin(["pass", "run"]) & raw.epa.notna()
              & (raw.two_point_attempt != 1) & (raw.qb_kneel != 1) & (raw.qb_spike != 1)]
    raw = raw.drop(columns=["two_point_attempt", "qb_kneel", "qb_spike", "season_type"])
    raw.to_parquet(out)
    return raw


def player_games(cache: Path, seasons, snaps: pd.DataFrame) -> pd.DataFrame:
    """One row per (player, game) with raw counts for every variable."""
    p = pd.concat([skill_plays(cache, s) for s in seasons], ignore_index=True)
    p["rz"] = (p.yardline_100 <= 20).astype(float)
    p["gl"] = (p.yardline_100 <= 5).astype(float)
    team = p.groupby(["game_id", "posteam"]).agg(
        team_db=("qb_dropback", "sum"), team_plays=("epa", "size"),
        team_rz_db=("rz", lambda s: float((s * p.loc[s.index, "qb_dropback"]).sum())),
        team_runs=("qb_dropback", lambda s: float((1 - s).sum())),
        team_gl_runs=("gl", lambda s: float((s * (1 - p.loc[s.index, "qb_dropback"])).sum())),
    ).reset_index()
    tgt = p[(p.qb_dropback == 1) & (p.sack != 1) & p.receiver_player_id.notna()].copy()
    tgt["ay"] = tgt.air_yards.fillna(0)
    tgt["ry"] = tgt.yards_gained * tgt.complete_pass
    tgt["yac"] = tgt.yards_after_catch.fillna(0) * tgt.complete_pass
    tgt["fd"] = tgt.first_down.fillna(0) * tgt.complete_pass
    team_air = tgt.groupby(["game_id", "posteam"]).ay.sum().rename("team_air").reset_index()
    rec = tgt.groupby(["game_id", "posteam", "receiver_player_id"]).agg(
        targets=("epa", "size"), rec=("complete_pass", "sum"), rec_yds=("ry", "sum"), rec_epa=("epa", "sum"),
        air=("ay", "sum"), yac=("yac", "sum"), rec_fd=("fd", "sum"), rec_td=("pass_touchdown", "sum"),
        rz_tgt=("rz", "sum")).reset_index().rename(columns={"receiver_player_id": "player"})
    ru = p[p.rusher_player_id.notna()].copy()
    ru["designed"] = (ru.qb_scramble != 1).astype(float)
    rush = ru.groupby(["game_id", "posteam", "rusher_player_id"]).agg(
        carries=("designed", "sum"), rush_plays=("epa", "size"), rush_yds=("yards_gained", "sum"),
        rush_epa=("epa", "sum"), rush_succ=("success", "sum"), rush_td=("rush_touchdown", "sum"),
        gl_car=("gl", "sum"), rush_fd=("first_down", "sum")).reset_index().rename(columns={"rusher_player_id": "player"})
    db = p[(p.qb_dropback == 1) & p.passer_player_id.notna()].copy()
    db["att"] = ((db.sack != 1) & (db.qb_scramble != 1)).astype(float)
    db["pyds"] = db.yards_gained * db.complete_pass
    db["cp"] = db.cpoe.fillna(0) * db.att
    pas = db.groupby(["game_id", "posteam", "passer_player_id"]).agg(
        dropbacks=("epa", "size"), att=("att", "sum"), pass_epa=("epa", "sum"), pass_yds=("pyds", "sum"),
        sacks=("sack", "sum"), ints=("interception", "sum"), ptd=("pass_touchdown", "sum"),
        cpoe_sum=("cp", "sum"), pass_air=("air_yards", lambda s: float(s.fillna(0).sum()))).reset_index() \
        .rename(columns={"passer_player_id": "player"})
    g = rec.merge(rush, on=["game_id", "posteam", "player"], how="outer").merge(pas, on=["game_id", "posteam", "player"], how="outer")
    # Add zero-stat games for players who took snaps (so a quiet game counts).
    s = snaps.dropna(subset=["gsis_id"])
    s = s[(s.offense_pct > 0) & s.position.isin(["QB", "RB", "FB", "WR", "TE"])][["game_id", "gsis_id", "offense_pct", "season", "week"]]
    s = s.rename(columns={"gsis_id": "player", "offense_pct": "snap_pct"}).drop_duplicates(["game_id", "player"])
    g = g.merge(s[["game_id", "player", "snap_pct"]], on=["game_id", "player"], how="outer")
    # posteam for snap-only rows: from another row of the same game is ambiguous; use the snap file's team via side.
    meta = p.groupby("game_id").agg(season=("season", "first"), week=("week", "first")).reset_index()
    g = g.merge(meta, on="game_id", how="left")
    side = snaps.dropna(subset=["gsis_id"])[["game_id", "gsis_id", "team"]].rename(columns={"gsis_id": "player", "team": "snap_team"}).drop_duplicates(["game_id", "player"])
    g = g.merge(side, on=["game_id", "player"], how="left")
    # nflverse snap counts use the same club codes as play-by-play.
    g["posteam"] = g.posteam.fillna(g.snap_team)
    g = g.dropna(subset=["posteam", "season"])
    g = g.merge(team, on=["game_id", "posteam"], how="left").merge(team_air, on=["game_id", "posteam"], how="left")
    defteam = p.groupby(["game_id", "posteam"]).defteam.first().reset_index()
    g = g.merge(defteam, on=["game_id", "posteam"], how="left")
    num = [c for c in g.columns if c not in ("game_id", "posteam", "player", "defteam", "snap_team", "season", "week")]
    g[num] = g[num].fillna(0.0)
    g["season"] = g.season.astype(int)
    g["week"] = g.week.astype(int)
    return g.drop(columns=["snap_team"])


def add_ngs(g: pd.DataFrame, cache: Path) -> pd.DataFrame:
    def load(name, cols):
        path = fetch(f"{BASE}/nextgen_stats/{name}.parquet", cache / f"{name}.parquet")
        d = pd.read_parquet(path)
        d = d[(d.week > 0) & d.season_type.isin(["REG", "POST"])]
        return d[["season", "week", "player_gsis_id"] + cols].rename(columns={"player_gsis_id": "player"})
    rec = load("ngs_receiving", ["avg_separation", "avg_cushion", "avg_yac_above_expectation"])
    ru = load("ngs_rushing", ["rush_yards_over_expected_per_att", "efficiency"])
    pa = load("ngs_passing", ["avg_time_to_throw", "aggressiveness", "completion_percentage_above_expectation"])
    for d in (rec, ru, pa):
        d.drop_duplicates(["season", "week", "player"], inplace=True)
        g = g.merge(d, on=["season", "week", "player"], how="left")
    return g


# (numerator, denominator, prior pseudo-count in denominator units)
RATES = {
    "snap": ("snap_pct", None, 4),
    "tgt_share": ("targets", "team_db", 60),
    "air_share": ("air", "team_air", 400),
    "tgt_per_route": ("targets", "routes", 60),
    "rz_share": ("rz_tgt", "team_rz_db", 15),
    "ypt": ("rec_yds", "targets", 30),
    "epa_tgt": ("rec_epa", "targets", 30),
    "fd_tgt": ("rec_fd", "targets", 30),
    "catch": ("rec", "targets", 30),
    "adot": ("air", "targets", 30),
    "yac_rec": ("yac", "rec", 20),
    "td_tgt": ("rec_td", "targets", 60),
    "car_share": ("carries", "team_runs", 40),
    "gl_share": ("gl_car", "team_gl_runs", 8),
    "ypc": ("rush_yds", "rush_plays", 40),
    "rush_epa": ("rush_epa", "rush_plays", 40),
    "rush_succ": ("rush_succ", "rush_plays", 40),
    "epa_db": ("pass_epa", "dropbacks", 150),
    "ypa": ("pass_yds", "att", 150),
    "sack_rate": ("sacks", "dropbacks", 150),
    "int_rate": ("ints", "att", 150),
    "cpoe": ("cpoe_sum", "att", 150),
    "pass_adot": ("pass_air", "att", 150),
}
NGS = ["avg_separation", "avg_cushion", "avg_yac_above_expectation", "rush_yards_over_expected_per_att",
       "efficiency", "avg_time_to_throw", "aggressiveness", "completion_percentage_above_expectation"]


def decayed_features(g: pd.DataFrame) -> pd.DataFrame:
    """Pre-game features: decayed sums over EARLIER games only, shrunk to the position mean."""
    g = g.sort_values(["player", "season", "week"]).reset_index(drop=True)
    g["routes"] = g.snap_pct * g.team_db  # pass plays on the field (a route proxy)
    lam = 0.5 ** (1 / HALF_LIFE_GAMES)
    cols = sorted({c for n, d, _ in RATES.values() for c in (n, d) if c})
    vals = g[cols].to_numpy(float)
    ngs_vals = g[NGS].to_numpy(float)
    players = g.player.to_numpy()
    seasons = g.season.to_numpy()
    out = np.full((len(g), len(cols)), np.nan)
    ngs_out = np.full((len(g), len(NGS)), np.nan)
    games_out = np.zeros(len(g))
    acc = np.zeros(len(cols))
    nacc = np.zeros(len(NGS))
    nw = np.zeros(len(NGS))
    count = 0.0
    for i in range(len(g)):
        if i == 0 or players[i] != players[i - 1]:
            acc[:] = 0
            nacc[:] = 0
            nw[:] = 0
            count = 0.0
        elif seasons[i] != seasons[i - 1]:
            f = SEASON_DECAY ** (seasons[i] - seasons[i - 1])
            acc *= f
            nacc *= f
            nw *= f
            count *= f
        out[i] = acc
        games_out[i] = count
        with np.errstate(invalid="ignore", divide="ignore"):
            ngs_out[i] = np.where(nw > 0, nacc / nw, np.nan)
        acc = acc * lam + vals[i]
        ok = ~np.isnan(ngs_vals[i])
        nacc = nacc * lam
        nw = nw * lam
        nacc[ok] += ngs_vals[i][ok]
        nw[ok] += 1
        count = count * lam + 1
    sums = pd.DataFrame(out, columns=cols, index=g.index)
    feat = g[["player", "game_id", "season", "week", "posteam", "defteam"]].copy()
    feat["games"] = games_out
    for name, (n, d, k) in RATES.items():
        den = games_out if d is None else sums[d]
        num = sums[n]
        feat[f"{name}_raw"] = num
        feat[f"{name}_den"] = den
    for j, c in enumerate(NGS):
        feat[c] = ngs_out[:, j]
    return feat


def shrink(feat: pd.DataFrame, pos: pd.Series, train_mask: pd.Series) -> pd.DataFrame:
    """Rate = (num + k*mean)/(den + k), with the position mean taken from training rows."""
    f = feat.copy()
    for name, (n, d, k) in RATES.items():
        num, den = f[f"{name}_raw"], f[f"{name}_den"]
        rate = num / den.replace(0, np.nan)
        means = rate[train_mask & (den > k)].groupby(pos[train_mask & (den > k)]).mean()
        m = pos.map(means).fillna(rate[train_mask].mean())
        f[name] = (num + k * m) / (den + k)
        f[f"{name}_n"] = np.log1p(den)
    for c in NGS:
        m = f.loc[train_mask, c].groupby(pos[train_mask]).mean()
        f[f"{c}_missing"] = f[c].isna().astype(float)
        f[c] = f[c].fillna(pos.map(m)).fillna(0.0)
    return f


TARGETS = {
    # Next game's production per team pass play (receivers) or per team play (backs),
    # and EPA per dropback for passers.
    "WR": ("rec_yds", "team_db"),
    "TE": ("rec_yds", "team_db"),
    "RB": ("scrimmage", "team_plays"),
    "QB": ("pass_epa", "dropbacks"),
}
FEATURES = {
    "WR": ["snap", "tgt_share", "air_share", "tgt_per_route", "rz_share", "ypt", "epa_tgt", "fd_tgt", "catch", "adot",
           "yac_rec", "td_tgt", "avg_separation", "avg_cushion", "avg_yac_above_expectation"],
    "TE": ["snap", "tgt_share", "air_share", "tgt_per_route", "rz_share", "ypt", "epa_tgt", "fd_tgt", "catch", "adot",
           "yac_rec", "td_tgt", "avg_separation", "avg_cushion", "avg_yac_above_expectation"],
    "RB": ["snap", "car_share", "gl_share", "ypc", "rush_epa", "rush_succ", "tgt_share", "ypt", "catch", "yac_rec",
           "rush_yards_over_expected_per_att", "efficiency"],
    "QB": ["epa_db", "ypa", "sack_rate", "int_rate", "cpoe", "pass_adot", "rush_epa", "ypc",
           "avg_time_to_throw", "aggressiveness", "completion_percentage_above_expectation"],
}
CONTEXT = ["qb_ypa", "qb_ypt", "opp_def", "age", "age2", "exp", "draft", "undrafted", "games_log"]


def context_features(feat: pd.DataFrame, g: pd.DataFrame, people: pd.DataFrame, qb_rating: dict, def_rating: dict) -> pd.DataFrame:
    f = feat.copy()
    bd = people.set_index("gsis_id")
    birth = pd.to_datetime(bd["birth_date"], errors="coerce")
    year = f.season + f.week / 52.0
    by = f.player.map(birth).dt.year + f.player.map(birth).dt.dayofyear / 365.0
    f["age"] = (year - by).fillna(26.0)
    f["age2"] = (f.age - 26.0) ** 2
    rookie = f.player.map(bd["rookie_season"])
    f["exp"] = (f.season - rookie).clip(0, 20).fillna(3.0)
    pick = f.player.map(bd["draft_pick"])
    f["undrafted"] = pick.isna().astype(float)
    f["draft"] = np.log(pick.fillna(260.0))
    f["games_log"] = np.log1p(f.games)
    f["qb_ypa"] = [qb_rating.get(k, 0.0) for k in zip(f.game_id, f.posteam)]
    f["qb_ypt"] = f["qb_ypa"]
    f["opp_def"] = [def_rating.get(k, 0.0) for k in zip(f.game_id, f.defteam)]
    return f


def ridge(x, y, w, lam):
    mu = np.average(x, axis=0, weights=w)
    sd = np.sqrt(np.average((x - mu) ** 2, axis=0, weights=w))
    sd[sd == 0] = 1
    z = (x - mu) / sd
    z1 = np.column_stack([np.ones(len(z)), z])
    reg = lam * np.eye(z1.shape[1])
    reg[0, 0] = 0
    beta = np.linalg.solve((z1 * w[:, None]).T @ z1 + reg, (z1 * w[:, None]).T @ y)
    return mu, sd, beta


def predict(model, x):
    mu, sd, beta = model
    return beta[0] + ((x - mu) / sd) @ beta[1:]


# ---------------------------------------------------------------------------
# Measured physical traits (NFL Scouting Combine, via nflverse) and defenders.

COMBINE = ["ht_in", "wt", "forty", "bench", "vertical", "broad_jump", "cone", "shuttle", "speed_score"]
DEF_COLUMNS = ["game_id", "season", "week", "season_type", "sack_player_id", "half_sack_1_player_id",
               "half_sack_2_player_id", "qb_hit_1_player_id", "qb_hit_2_player_id", "interception_player_id",
               "pass_defense_1_player_id", "pass_defense_2_player_id", "tackle_for_loss_1_player_id",
               "tackle_for_loss_2_player_id", "solo_tackle_1_player_id", "forced_fumble_player_1_player_id"]


def combine_table(cache: Path, people: pd.DataFrame) -> pd.DataFrame:
    path = fetch(f"{BASE}/combine/combine.parquet", cache / "combine.parquet")
    c = pd.read_parquet(path).dropna(subset=["pfr_id"]).drop_duplicates("pfr_id", keep="last")

    def inches(h):
        try:
            ft, inch = str(h).split("-")
            return int(ft) * 12 + int(inch)
        except ValueError:
            return np.nan
    c["ht_in"] = c.ht.map(inches)
    c["speed_score"] = c.wt * 200 / c.forty**4
    ids = people.dropna(subset=["pfr_id"])[["gsis_id", "pfr_id"]]
    c = c.merge(ids, on="pfr_id", how="inner")
    return c.set_index("gsis_id")[COMBINE]


def defender_production(cache: Path, seasons, snaps: pd.DataFrame) -> pd.DataFrame:
    """Per defender-season: sacks, QB hits, TFL, pass breakups, picks, forced fumbles, solo tackles, snaps."""
    rows = []
    for s in seasons:
        out = cache / f"def_{s}.parquet"
        if out.exists():
            d = pd.read_parquet(out)
        else:
            d = pd.read_parquet(pbp_path(cache, s), columns=DEF_COLUMNS)
            d = d[d.season_type.isin(["REG", "POST"])]
            d.to_parquet(out)
        counts = {}
        for col, key, w in (("sack_player_id", "sacks", 1), ("half_sack_1_player_id", "sacks", 0.5),
                            ("half_sack_2_player_id", "sacks", 0.5), ("qb_hit_1_player_id", "hits", 1),
                            ("qb_hit_2_player_id", "hits", 1), ("interception_player_id", "ints", 1),
                            ("pass_defense_1_player_id", "pbu", 1), ("pass_defense_2_player_id", "pbu", 1),
                            ("tackle_for_loss_1_player_id", "tfl", 1), ("tackle_for_loss_2_player_id", "tfl", 1),
                            ("solo_tackle_1_player_id", "solo", 1), ("forced_fumble_player_1_player_id", "ff", 1)):
            vc = d[col].dropna().value_counts() * w
            for pid, n in vc.items():
                counts.setdefault(pid, {}).setdefault(key, 0.0)
                counts[pid][key] += n
        for pid, c in counts.items():
            rows.append({"player": pid, "season": s, **c})
    prod = pd.DataFrame(rows).fillna(0.0)
    sn = snaps.dropna(subset=["gsis_id"]).groupby(["gsis_id", "season"]).defense_snaps.sum().rename("def_snaps").reset_index()
    sn = sn.rename(columns={"gsis_id": "player"})
    return sn.merge(prod, on=["player", "season"], how="left").fillna(0.0)


def availability(snaps: pd.DataFrame, season: int, week: int) -> pd.Series:
    """Share of his team's games a player took a snap in, this season and last (last counts half)."""
    s = snaps.dropna(subset=["gsis_id"])
    s = s[(s.season.isin([season - 1, season])) & ((s.offense_snaps + s.defense_snaps) > 0)]
    s = s[(s.season < season) | (s.week < week)]
    played = s.groupby(["gsis_id", "season"]).game_id.nunique().unstack(fill_value=0)
    team_games = snaps[(snaps.season.isin([season - 1, season])) & ((snaps.season < season) | (snaps.week < week))] \
        .groupby("season").week.nunique()
    num = sum(played.get(y, 0) * (0.5 if y < season else 1.0) for y in played.columns)
    den = sum(team_games.get(y, 0) * (0.5 if y < season else 1.0) for y in played.columns)
    return (num / max(den, 1)).clip(0, 1)


# ---------------------------------------------------------------------------
# Pipeline

CONTEXT_COLS = ["qb_q", "opp_ypt", "opp_ypc", "opp_epa", "age", "age2", "exp", "draft", "undrafted", "games_log"]
POS_MAP = {"FB": "RB", "HB": "RB"}


def feature_list(pos: str) -> list[str]:
    base = FEATURES[pos]
    return (base + [c + "_n" for c in base if c in RATES] + [c + "_missing" for c in base if c in NGS]
            + CONTEXT_COLS)


def _defense_allowed(g: pd.DataFrame) -> dict:
    d = g.groupby(["game_id", "defteam"]).agg(
        ty=("rec_yds", "sum"), tt=("targets", "sum"), ry=("rush_yds", "sum"), rp=("rush_plays", "sum"),
        pe=("pass_epa", "sum"), pdb=("dropbacks", "sum"), season=("season", "first"), week=("week", "first")
    ).reset_index().sort_values(["defteam", "season", "week"])
    lam = 0.5 ** (1 / HALF_LIFE_GAMES)
    state = {}
    last = {}
    for team, x in d.groupby("defteam"):
        acc = np.zeros(6)
        prev = None
        for r in x.itertuples(index=False):
            if prev is not None and r.season != prev:
                acc *= 0.6
            state[(r.game_id, team)] = acc.copy()
            acc = acc * lam + np.array([r.ty, r.tt, r.ry, r.rp, r.pe, r.pdb])
            prev = r.season
        last[team] = acc.copy()
    return state, last


def _allowed(acc):
    if acc is None:
        return 8.0, 4.3, 0.0
    return (acc[0] + 8 * 200) / (acc[1] + 200), (acc[2] + 4.3 * 150) / (acc[3] + 150), acc[4] / (acc[5] + 300)


def build(cache: Path, seasons, snaps: pd.DataFrame, games: pd.DataFrame, people: pd.DataFrame):
    """Returns (pregame feature rows with actual results, current features per active player)."""
    g = add_ngs(player_games(cache, seasons, snaps), cache)
    posmap = people.set_index("gsis_id").position.map(lambda p: POS_MAP.get(p, p))
    last_season = int(g.season.max())
    last_week = int(g[g.season == last_season].week.max())
    # One empty "next game" row per active skill player, so the same code gives current features.
    recent = g[(g.season == last_season)].sort_values("week").drop_duplicates("player", keep="last")
    nxt = recent[["player", "posteam"]].copy()
    for c in g.columns:
        if c not in nxt.columns:
            nxt[c] = 0.0 if c not in NGS else np.nan
    nxt["game_id"] = "next_" + nxt.player
    nxt["season"], nxt["week"], nxt["defteam"] = last_season, last_week + 1, None
    allg = pd.concat([g, nxt[g.columns]], ignore_index=True)
    f = decayed_features(allg)
    f["pos"] = f.player.map(posmap)
    f = f[f.pos.isin(list(TARGETS))].copy()
    train = (f.season < last_season) & ~f.game_id.str.startswith("next_")
    f = shrink(f, f.pos, train)
    starters = {}
    for r in games.itertuples(index=False):
        starters[(r.game_id, r.home_team)] = r.home_qb_id
        starters[(r.game_id, r.away_team)] = r.away_qb_id
    qb_rows = f[f.pos == "QB"]
    qbk = dict(zip(zip(qb_rows.player, qb_rows.game_id), qb_rows.epa_db))
    latest_qb = {}
    for r in recent.itertuples(index=False):
        if posmap.get(r.player) == "QB" and r.dropbacks >= 10:
            latest_qb[r.posteam] = r.player
    def qb_quality(gid, team):
        if gid.startswith("next_"):
            qb = latest_qb.get(team)
            return qbk.get((qb, "next_" + qb), np.nan) if qb else np.nan
        return qbk.get((starters.get((gid, team)), gid), np.nan)
    f["qb_q"] = [qb_quality(gid, t) for gid, t in zip(f.game_id, f.posteam)]
    f["qb_q"] = f.qb_q.fillna(qb_rows.epa_db.quantile(0.2))
    state, _ = _defense_allowed(g)
    allowed = np.array([_allowed(state.get(k)) for k in zip(f.game_id, f.defteam)])
    f["opp_ypt"], f["opp_ypc"], f["opp_epa"] = allowed.T
    f = context_features(f, allg, people, {}, {})
    actual = g.set_index(["player", "game_id"])
    idx = [k for k in zip(f.player, f.game_id)]
    have = actual.reindex(idx)
    for c in ("rec_yds", "rush_yds", "team_db", "team_plays", "pass_epa", "dropbacks", "snap_pct", "targets", "rec"):
        f["a_" + c] = have[c].to_numpy()
    f["a_scrimmage"] = f.a_rec_yds + f.a_rush_yds
    current = f[f.game_id.str.startswith("next_")].copy()
    hist = f[~f.game_id.str.startswith("next_")].copy()
    return hist, current, g


def training_rows(hist: pd.DataFrame, pos: str):
    num, den = TARGETS[pos]
    x = hist[hist.pos == pos]
    yn = x["a_" + num]
    yd = x["a_" + den]
    keep = (yd > 0) & (x.a_snap_pct > 0) & (x.games >= 1)
    if pos == "QB":
        keep &= yd >= 10
    x = x[keep]
    return x, (yn[keep] / yd[keep]).to_numpy(float), yd[keep].to_numpy(float)


SIMPLE = {"WR": ["tgt_per_route", "ypt"], "TE": ["tgt_per_route", "ypt"], "RB": ["car_share", "ypc", "tgt_share"],
          "QB": ["epa_db"]}


def evaluate(hist: pd.DataFrame, cache: Path, people: pd.DataFrame, train_last: int = TRAIN_LAST, lam: float = 100.0) -> dict:
    """Out-of-sample R^2 of next-game production per opportunity: all variables vs a two-variable rating."""
    cb = combine_table(cache, people)
    report = {}
    for pos in TARGETS:
        x, y, w = training_rows(hist, pos)
        x = x.copy()
        for c in COMBINE:
            v = x.player.map(cb[c])
            x[c + "_missing"] = v.isna().astype(float)
            x[c] = v.fillna(v[x.season <= train_last].mean())
        tr = (x.season <= train_last).to_numpy()
        base_rate = np.average(y[tr], weights=w[tr])
        rows = {}
        for name, cols in (("allVariables", feature_list(pos)), ("simpleRating", SIMPLE[pos]),
                           ("allVariablesPlusCombine", feature_list(pos) + COMBINE + [c + "_missing" for c in COMBINE])):
            X = x[cols].to_numpy(float)
            X = np.nan_to_num(X, nan=0.0)
            m = ridge(X[tr], y[tr], w[tr], lam)
            for s in sorted(x.season[~tr].unique()):
                te = (x.season == s).to_numpy()
                p = predict(m, X[te])
                r2 = 1 - np.average((p - y[te]) ** 2, weights=w[te]) / np.average((base_rate - y[te]) ** 2, weights=w[te])
                rows.setdefault(str(int(s)), {})[name] = round(float(r2), 4)
        report[pos] = {"target": "/".join(TARGETS[pos]), "trainedThrough": train_last, "outOfSampleR2": rows,
                       "playerGames": int((~tr).sum())}
    return report


def fit_and_rate(hist: pd.DataFrame, current: pd.DataFrame, lam: float = 100.0):
    """Fit on every finished season, then rate each active player. Also returns weights."""
    last = int(current.season.max())
    out = []
    weights = {}
    for pos in TARGETS:
        x, y, w = training_rows(hist[hist.season < last], pos)
        cols = feature_list(pos)
        m = ridge(np.nan_to_num(x[cols].to_numpy(float)), y, w, lam)
        weights[pos] = {c: round(float(b), 5) for c, b in zip(cols, m[2][1:])}
        cur = current[current.pos == pos].copy()
        cur["skill"] = predict(m, np.nan_to_num(cur[cols].to_numpy(float)))
        # Also predicted for the season's played games (for the prop check).
        out.append(cur)
    return pd.concat(out), weights


def pregame_predictions(hist: pd.DataFrame, season: int, lam: float = 100.0) -> pd.DataFrame:
    """Rate every player-game of `season` with weights fit on earlier seasons only."""
    out = []
    for pos in TARGETS:
        x, y, w = training_rows(hist[hist.season < season], pos)
        cols = feature_list(pos)
        m = ridge(np.nan_to_num(x[cols].to_numpy(float)), y, w, lam)
        cur = hist[(hist.season == season) & (hist.pos == pos)].copy()
        cur["skill"] = predict(m, np.nan_to_num(cur[cols].to_numpy(float)))
        out.append(cur)
    return pd.concat(out)


ATTRIBUTES = {
    # name: (column, higher is better)
    "Speed": ("forty", False),
    "Agility": ("agility", False),
    "Jumping": ("jump", True),
    "Strength": ("bench", True),
    "Size": ("size", True),
    "Separation": ("avg_separation", True),
    "Catching": ("catch", True),
    "Yards after catch": ("avg_yac_above_expectation", True),
    "Deep threat": ("deep", True),
    "Earning targets": ("tgt_per_route", True),
    "Red zone": ("rz_share", True),
    "Vision (yards over expected)": ("rush_yards_over_expected_per_att", True),
    "Rushing": ("rush_epa", True),
    "Accuracy (over expected)": ("cpoe", True),
    "Decisions (avoids picks)": ("int_rate", False),
    "Pocket (avoids sacks)": ("sack_rate", False),
    "Aggressiveness": ("aggressiveness", True),
    "Quick release": ("avg_time_to_throw", False),
    "Pass rush": ("pass_rush", True),
    "Coverage": ("coverage", True),
    "Run stopping": ("run_stop", True),
    "Durability": ("availability", True),
}
POSITION_ATTRS = {
    "WR": ["Speed", "Agility", "Jumping", "Size", "Separation", "Catching", "Yards after catch", "Deep threat",
           "Earning targets", "Red zone", "Durability"],
    "TE": ["Speed", "Agility", "Jumping", "Strength", "Size", "Separation", "Catching", "Yards after catch",
           "Earning targets", "Red zone", "Durability"],
    "RB": ["Speed", "Agility", "Jumping", "Strength", "Size", "Vision (yards over expected)", "Rushing", "Catching",
           "Yards after catch", "Durability"],
    "QB": ["Speed", "Size", "Accuracy (over expected)", "Decisions (avoids picks)", "Pocket (avoids sacks)",
           "Aggressiveness", "Quick release", "Deep threat", "Rushing", "Durability"],
    "DEF": ["Speed", "Agility", "Jumping", "Strength", "Size", "Pass rush", "Coverage", "Run stopping", "Durability"],
    "OL": ["Speed", "Agility", "Jumping", "Strength", "Size", "Durability"],
}
OL_POSITIONS = {"T", "G", "C", "OL", "OT", "OG"}


def percentile_40_99(values: pd.Series, groups: pd.Series, higher: bool = True) -> pd.Series:
    v = values if higher else -values
    return (40 + 59 * v.groupby(groups).rank(pct=True)).round()


DEF_GROUP = {"CB": "DB", "S": "DB", "FS": "DB", "SS": "DB", "DB": "DB", "SAF": "DB",
             "DE": "DL", "DT": "DL", "NT": "DL", "DL": "DL", "OLB": "LB", "ILB": "LB", "MLB": "LB", "LB": "LB"}


def player_attributes(rated: pd.DataFrame, current: pd.DataFrame, cb: pd.DataFrame, def_prod: pd.DataFrame,
                      avail: pd.Series, season: int) -> dict:
    """Madden-style sub-ratings (40-99, percentile within position) from measured data only.

    rated: one row per rated player with columns player, position, side.
    Returns {player: {attribute: value}}; a trait with no measurement is left out.
    """
    df = rated[["player", "position", "side"]].drop_duplicates(["player", "side"]).copy()
    df["group"] = np.where(df.side == "defense", df.position.map(DEF_GROUP).fillna("DEF"),
                           df.position.map(lambda p: "OL" if p in OL_POSITIONS else POS_MAP.get(p, p)))
    phys = cb.reindex(df.player)
    phys.index = df.index
    df["forty"] = phys.forty
    df["agility"] = phys[["cone", "shuttle"]].mean(axis=1, skipna=True)
    jz = (phys.vertical - phys.vertical.mean()) / phys.vertical.std() + (phys.broad_jump - phys.broad_jump.mean()) / phys.broad_jump.std()
    df["jump"] = jz
    df["bench"] = phys.bench
    df["size"] = (phys.ht_in - phys.ht_in.mean()) / phys.ht_in.std() + (phys.wt - phys.wt.mean()) / phys.wt.std()
    cur = current.drop_duplicates("player").set_index("player")
    for c in ("avg_separation", "catch", "avg_yac_above_expectation", "tgt_per_route", "rz_share",
              "rush_yards_over_expected_per_att", "rush_epa", "cpoe", "int_rate", "sack_rate", "aggressiveness",
              "avg_time_to_throw", "adot", "ypt", "pass_adot"):
        if c in cur.columns:
            df[c] = df.player.map(cur[c])
    # NGS traits only count when the player had NGS rows (not the filled average).
    for c in ("avg_separation", "avg_yac_above_expectation", "rush_yards_over_expected_per_att", "aggressiveness",
              "avg_time_to_throw"):
        miss = df.player.map(cur.get(f"{c}_missing", pd.Series(dtype=float)))
        df.loc[miss == 1, c] = np.nan
    df["deep"] = np.where(df.group == "QB", df.get("pass_adot"), df.get("adot") * 0.5 + df.get("ypt") * 0.5)
    # Defenders: per-snap production, this season plus half of last season.
    dp = def_prod[def_prod.season.isin([season - 1, season])].copy()
    wgt = np.where(dp.season == season, 1.0, 0.5)
    for c in ("sacks", "hits", "ints", "pbu", "tfl", "solo", "ff", "def_snaps"):
        dp[c] = dp[c] * wgt
    agg = dp.groupby("player")[["sacks", "hits", "ints", "pbu", "tfl", "solo", "ff", "def_snaps"]].sum()
    snaps_ = agg.def_snaps + 200  # shrink small samples
    df["pass_rush"] = df.player.map((agg.sacks * 3 + agg.hits) / snaps_)
    df["coverage"] = df.player.map((agg.ints * 2 + agg.pbu) / snaps_)
    df["run_stop"] = df.player.map((agg.tfl * 2 + agg.solo * 0.5 + agg.ff) / snaps_)
    df["availability"] = df.player.map(avail)
    out = {}
    for name, (col, higher) in ATTRIBUTES.items():
        if col not in df.columns:
            continue
        vals = pd.to_numeric(df[col], errors="coerce")
        pct = percentile_40_99(vals, df.group, higher)
        df[f"attr::{name}"] = pct
    for idx, r in df.iterrows():
        key = "DEF" if r.side == "defense" else ("OL" if r.position in OL_POSITIONS else POS_MAP.get(r.position, r.position))
        names = POSITION_ATTRS.get(key, POSITION_ATTRS["DEF"] if r.side == "defense" else [])
        out[(r.player, r.side)] = {n: int(r[f"attr::{n}"]) for n in names if pd.notna(r.get(f"attr::{n}"))}
    df["def_production"] = np.where(df.group == "DL", df.pass_rush * 1.0 + df.run_stop * 0.5,
                           np.where(df.group == "DB", df.coverage * 1.0 + df.run_stop * 0.3,
                                    df.pass_rush * 0.5 + df.coverage * 0.5 + df.run_stop * 0.7))
    prod = dict(zip(zip(df.player, df.side), df.def_production))
    return out, prod


def receiving_projection(hist: pd.DataFrame, g: pd.DataFrame, seasons) -> pd.DataFrame:
    """WR/TE receiving-yard projection = skill (yards per team pass play) x the team's
    average pass plays over its previous 8 games. Weights from earlier seasons only."""
    tg = g.groupby(["game_id", "posteam"]).agg(team_db=("team_db", "first"), season=("season", "first"),
                                               week=("week", "first")).reset_index()
    tg = tg.sort_values(["posteam", "season", "week"])
    tg["exp_db"] = tg.groupby("posteam").team_db.transform(lambda s: s.shift(1).rolling(8, min_periods=1).mean())
    exp = dict(zip(zip(tg.game_id, tg.posteam), tg.exp_db))
    out = []
    for s in seasons:
        p = pregame_predictions(hist, s)
        p = p[p.pos.isin(["WR", "TE"])].copy()
        p["proj"] = p.skill.clip(lower=0) * np.array([exp.get(k, np.nan) for k in zip(p.game_id, p.posteam)])
        out.append(p[["player", "game_id", "season", "week", "proj", "a_rec_yds", "a_snap_pct"]])
    return pd.concat(out).dropna(subset=["proj"])
