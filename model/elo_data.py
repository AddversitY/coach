"""Free nflverse inputs for the team and player ratings.

Every file comes from https://github.com/nflverse/nflverse-data (CC BY 4.0).
Downloads are cached; the reduced play table is cached as parquet so a
rerun does not re-read 400 MB of play-by-play.
"""

from __future__ import annotations

import urllib.request
from pathlib import Path

import numpy as np
import pandas as pd

BASE = "https://github.com/nflverse/nflverse-data/releases/download"
FIRST_PBP_SEASON = 2006
FIRST_PARTICIPATION_SEASON = 2016

PLAY_COLUMNS = [
    "game_id", "play_id", "season", "week", "season_type", "posteam", "defteam",
    "home_team", "play_type", "epa", "success", "yards_gained", "qb_dropback",
    "pass_attempt", "rush_attempt", "sack", "complete_pass", "interception",
    "passer_player_id", "rusher_player_id", "receiver_player_id", "air_yards",
    "pass_defense_1_player_id", "two_point_attempt", "qb_kneel", "qb_spike",
    "penalty", "wp",
]
SPECIAL = {"kickoff", "punt", "field_goal", "extra_point"}


def fetch(url: str, path: Path) -> Path | None:
    if path.exists() and path.stat().st_size > 100:
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read()
    except Exception:  # missing season (e.g. participation not posted yet)
        return None
    path.write_bytes(data)
    return path


def pbp_path(cache: Path, season: int) -> Path | None:
    return fetch(f"{BASE}/pbp/play_by_play_{season}.parquet", cache / f"pbp_{season}.parquet")


def participation_path(cache: Path, season: int) -> Path | None:
    if season < FIRST_PARTICIPATION_SEASON:
        return None
    return fetch(
        f"{BASE}/pbp_participation/pbp_participation_{season}.parquet",
        cache / f"part_{season}.parquet",
    )


def snaps_path(cache: Path, season: int) -> Path | None:
    return fetch(f"{BASE}/snap_counts/snap_counts_{season}.parquet", cache / f"snaps_{season}.parquet")


def reduce_season(cache: Path, season: int) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Return (scrimmage plays, special-teams EPA per team-game) for one season."""
    out = cache / f"plays_{season}.parquet"
    st_out = cache / f"st_{season}.parquet"
    if out.exists() and st_out.exists():
        return pd.read_parquet(out), pd.read_parquet(st_out)
    path = pbp_path(cache, season)
    if path is None:
        raise FileNotFoundError(f"play-by-play {season}")
    raw = pd.read_parquet(path, columns=[c for c in PLAY_COLUMNS])
    raw = raw[raw["season_type"].isin(["REG", "POST"])]
    st = raw[raw["play_type"].isin(SPECIAL) & raw["epa"].notna()]
    st_for = st.groupby(["game_id", "posteam"])["epa"].sum()
    st_against = st.groupby(["game_id", "defteam"])["epa"].sum()
    st_for.index.names = st_against.index.names = ["game_id", "team"]
    st_net = st_for.sub(st_against, fill_value=0).rename("st_epa").reset_index()
    plays = raw[
        raw["play_type"].isin(["pass", "run"])
        & raw["epa"].notna()
        & (raw["two_point_attempt"] != 1)
        & (raw["qb_kneel"] != 1)
        & (raw["qb_spike"] != 1)
        & raw["posteam"].notna()
    ].copy()
    plays["is_pass"] = (plays["qb_dropback"] == 1).astype(np.int8)
    part = participation_path(cache, season)
    if part is not None:
        p = pd.read_parquet(part, columns=["nflverse_game_id", "play_id", "offense_players", "defense_players"])
        p = p.rename(columns={"nflverse_game_id": "game_id"})
        plays = plays.merge(p, on=["game_id", "play_id"], how="left")
    else:
        plays["offense_players"] = None
        plays["defense_players"] = None
    keep = [
        "game_id", "play_id", "season", "week", "posteam", "defteam", "home_team", "is_pass",
        "epa", "success", "yards_gained", "sack", "complete_pass", "interception",
        "passer_player_id", "rusher_player_id", "receiver_player_id", "air_yards",
        "pass_defense_1_player_id", "offense_players", "defense_players", "wp",
    ]
    plays = plays[keep]
    plays.to_parquet(out)
    st_net.to_parquet(st_out)
    return plays, st_net


def load_plays(cache: Path, seasons) -> tuple[pd.DataFrame, pd.DataFrame]:
    frames, st = [], []
    for season in seasons:
        p, s = reduce_season(cache, season)
        frames.append(p)
        st.append(s)
    return pd.concat(frames, ignore_index=True), pd.concat(st, ignore_index=True)


def load_snaps(cache: Path, seasons) -> pd.DataFrame:
    """Snap counts keyed by gsis player id (via the nflverse players table)."""
    players = fetch(f"{BASE}/players/players.parquet", cache / "players.parquet")
    ids = pd.read_parquet(players, columns=["gsis_id", "pfr_id", "position"]).dropna(subset=["pfr_id"])
    frames = []
    for season in seasons:
        path = snaps_path(cache, season)
        if path is None:
            continue
        frames.append(pd.read_parquet(path))
    snaps = pd.concat(frames, ignore_index=True)
    snaps = snaps.merge(ids[["gsis_id", "pfr_id"]], left_on="pfr_player_id", right_on="pfr_id", how="left")
    return snaps


def load_games(schedule_csv: Path) -> pd.DataFrame:
    games = pd.read_csv(schedule_csv, low_memory=False)
    games = games[games["season"] >= FIRST_PBP_SEASON]
    return games
