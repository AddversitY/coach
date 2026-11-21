"""Build assets/prop-usage.json from a local nflverse cache.

Reads snap counts, weekly player stats, play-by-play, and participation
from --cache (default /tmp/prop-data/nfl). Writes derived player-week
shares only. Raw CSVs are not copied into the repo.

2026 route share stays null: pbp_participation_2026 was not published.
"""

from __future__ import annotations

import argparse
import csv
import json
from collections import defaultdict
from pathlib import Path

from prop_shares import SKILL_POSITIONS, norm_name, share

SEASONS = (2023, 2024, 2025, 2026)


def _float(text: str) -> float | None:
    cleaned = text.strip()
    if not cleaned:
        return None
    try:
        value = float(cleaned)
    except ValueError:
        return None
    if value != value or value in (float("inf"), float("-inf")):
        return None
    return value


def _snap_key(name: str, team: str, season: int, week: int) -> tuple:
    return (norm_name(name), team, season, week)


def load_snaps(cache: Path) -> dict:
    snaps: dict = {}
    for season in SEASONS:
        path = cache / f"snap_counts_{season}.csv"
        if not path.exists():
            continue
        with path.open(newline="") as handle:
            for row in csv.DictReader(handle):
                if row.get("game_type") not in (None, "", "REG"):
                    continue
                position = (row.get("position") or "").strip()
                if position not in SKILL_POSITIONS:
                    continue
                try:
                    week = int(row["week"])
                    file_season = int(row["season"])
                except (KeyError, ValueError):
                    continue
                pct = _float(row.get("offense_pct") or "")
                if pct is None or pct < 0:
                    continue
                if pct > 1.5:
                    pct = pct / 100
                if pct > 1:
                    pct = 1
                key = _snap_key(row.get("player") or "", row.get("team") or "", file_season, week)
                if key in snaps and snaps[key] != round(pct, 4):
                    snaps[key] = "collision"
                else:
                    snaps[key] = round(pct, 4)
    return snaps


def load_red_zone(cache: Path) -> tuple[dict, dict]:
    player: dict = defaultdict(float)
    team: dict = defaultdict(float)
    for season in SEASONS:
        path = cache / f"play_by_play_{season}.csv"
        if not path.exists():
            continue
        with path.open(newline="") as handle:
            for row in csv.DictReader(handle):
                if row.get("season_type") != "REG":
                    continue
                yard = _float(row.get("yardline_100") or "")
                if yard is None or yard > 20:
                    continue
                try:
                    week = int(row["week"])
                    file_season = int(row["season"])
                except (KeyError, ValueError):
                    continue
                club = (row.get("posteam") or "").strip()
                if not club:
                    continue
                credited = None
                if row.get("rush_attempt") == "1":
                    credited = (row.get("rusher_player_id") or "").strip()
                elif row.get("pass_attempt") == "1":
                    credited = (row.get("receiver_player_id") or "").strip()
                if not credited:
                    continue
                player[(credited, file_season, week)] += 1
                team[(club, file_season, week)] += 1
    return player, team


def load_routes(cache: Path) -> tuple[dict, dict]:
    """Share of team dropbacks where the player was on the field.

    The participation `route` column is the targeted player's charted
    route, so it is not a participation count. 2026 has no participation
    file, so those weeks stay missing.
    """
    player: dict = defaultdict(float)
    team: dict = defaultdict(float)
    for season in (2023, 2024, 2025):
        pbp = cache / f"play_by_play_{season}.csv"
        part = cache / f"pbp_participation_{season}.csv"
        if not pbp.exists() or not part.exists():
            continue
        dropbacks: dict = {}
        with pbp.open(newline="") as handle:
            for row in csv.DictReader(handle):
                if row.get("season_type") != "REG" or row.get("qb_dropback") != "1":
                    continue
                club = (row.get("posteam") or "").strip()
                if not club:
                    continue
                try:
                    week = int(row["week"])
                    file_season = int(row["season"])
                    play_id = row["play_id"]
                    game_id = row["game_id"]
                except (KeyError, ValueError):
                    continue
                dropbacks[(game_id, play_id)] = (club, file_season, week)
                team[(club, file_season, week)] += 1
        with part.open(newline="") as handle:
            for row in csv.DictReader(handle):
                key = (row.get("nflverse_game_id") or "", row.get("play_id") or "")
                found = dropbacks.get(key)
                if found is None:
                    continue
                club, file_season, week = found
                listed = row.get("offense_players") or ""
                for player_id in listed.split(";"):
                    player_id = player_id.strip()
                    if player_id:
                        player[(player_id, file_season, week)] += 1
    return player, team


def load_weeks(cache: Path) -> list[dict]:
    rows = []
    for season in SEASONS:
        path = cache / f"stats_player_week_{season}.csv"
        if not path.exists():
            continue
        with path.open(newline="") as handle:
            for row in csv.DictReader(handle):
                if row.get("season_type") != "REG":
                    continue
                position = (row.get("position") or "").strip()
                if position not in SKILL_POSITIONS:
                    continue
                player_id = (row.get("player_id") or "").strip()
                team = (row.get("team") or "").strip()
                if not player_id or not team:
                    continue
                try:
                    week = int(row["week"])
                    file_season = int(row["season"])
                except (KeyError, ValueError):
                    continue
                air = _float(row.get("air_yards_share") or "")
                if air is not None and (air < 0 or air > 1.5):
                    air = None
                if air is not None and air > 1:
                    air = 1
                rows.append(
                    {
                        "id": player_id,
                        "name": row.get("player_display_name") or "",
                        "position": position,
                        "team": team,
                        "season": file_season,
                        "week": week,
                        "air": None if air is None else round(air, 4),
                    }
                )
    return rows


def build(cache: Path) -> dict:
    snaps = load_snaps(cache)
    red_player, red_team = load_red_zone(cache)
    route_player, route_team = load_routes(cache)
    out = []
    for row in load_weeks(cache):
        snap = snaps.get(_snap_key(row["name"], row["team"], row["season"], row["week"]))
        if snap == "collision":
            snap = None
        route = share(
            route_player.get((row["id"], row["season"], row["week"]), 0),
            route_team.get((row["team"], row["season"], row["week"]), 0),
        )
        red = share(
            red_player.get((row["id"], row["season"], row["week"]), 0),
            red_team.get((row["team"], row["season"], row["week"]), 0),
        )
        # A player with no red-zone touch is a real zero only when the team
        # had red-zone rushes or targets. Otherwise the share is missing.
        if (row["team"], row["season"], row["week"]) not in red_team:
            red = None
        if snap is None and route is None and row["air"] is None and red is None:
            continue
        out.append(
            [
                row["id"],
                row["season"],
                row["week"],
                row["position"],
                snap,
                route,
                row["air"],
                red,
            ]
        )
    out.sort(key=lambda item: (item[0], item[1], item[2]))
    return {
        "schema": 1,
        "source": "nflverse contributors",
        "license": "CC BY 4.0",
        "licenseUrl": "https://creativecommons.org/licenses/by/4.0/",
        "sourceUrl": "https://github.com/nflverse/nflverse-data/releases",
        "note": (
            "Derived snap, route, air-yards, and red-zone shares. "
            "Earlier weeks only are used by the model. "
            "2026 route share is unavailable because participation was not published. "
            "Raw play-by-play is not included."
        ),
        "keys": ["id", "season", "week", "position", "snap", "route", "air", "rz"],
        "rows": out,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", default="/tmp/prop-data/nfl")
    parser.add_argument("--out", default="assets/prop-usage.json")
    args = parser.parse_args()
    payload = build(Path(args.cache))
    destination = Path(args.out)
    destination.write_text(json.dumps(payload, separators=(",", ":")))
    print(f"rows {len(payload['rows'])} -> {destination}")


if __name__ == "__main__":
    main()
