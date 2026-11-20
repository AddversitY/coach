#!/usr/bin/env python3
"""Build assets/nfl-recent-evidence.json from public nflverse CSVs.

The main player bundle is refreshed on its own schedule. This file adds the
completed games, team box scores, later player rows and later injury
designations that file does not have yet. It does not scrape a sportsbook,
does not invent a row, and does not copy a front-office or transaction feed
because nflverse does not publish one here.

Sack yards in the 2026 team file are negative. Net yards are passing yards
plus that value plus rushing yards, which is how the file lines up with
official team totals. Blank counts stay null.
"""
from __future__ import annotations

import csv
import hashlib
import json
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "assets" / "nfl-recent-evidence.json"
RELEASES = "https://github.com/nflverse/nflverse-data/releases/download"
CACHE = Path("/tmp/nflverse")
ALIASES = {"LAR": "LA", "OAK": "LV", "SD": "LAC", "STL": "LA"}
# The committed player and injury bundles already cover this day.
MAIN_CUTOFF = "2026-11-16"


def team(value: str) -> str:
    value = (value or "").strip().upper()
    return ALIASES.get(value, value)


def num(raw: str | None) -> float | None:
    text = (raw or "").strip()
    if text in ("", "NA", "NaN", "None"):
        return None
    value = float(text)
    if value != value or value in (float("inf"), float("-inf")):
        raise ValueError(f"Non-finite team stat {raw!r}")
    return value


def fetch(name: str, url: str) -> Path:
    path = CACHE / name
    if not path.exists() or path.stat().st_size < 1000:
        path.parent.mkdir(parents=True, exist_ok=True)
        request = urllib.request.Request(url, headers={"User-Agent": "coach-recent-evidence"})
        with urllib.request.urlopen(request, timeout=60) as response:
            path.write_bytes(response.read())
    return path


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    games_path = fetch("games.csv", f"{RELEASES}/schedules/games.csv")
    team_path = fetch("team_2026.csv", f"{RELEASES}/stats_team/stats_team_week_2026.csv")
    player_path = fetch("stats_2026.csv", f"{RELEASES}/stats_player/stats_player_week_2026.csv")
    injury_path = fetch("inj_2026.csv", f"{RELEASES}/injuries/injuries_2026.csv")
    schedule = {}
    for row in csv.DictReader(games_path.open(newline="", encoding="utf-8-sig")):
        if row["game_type"] != "REG" or row["season"] != "2026":
            continue
        if not row["home_score"] or not row["away_score"]:
            continue
        if row["gameday"] < "2023-01-01":
            continue
        schedule[row["game_id"]] = {
            "id": row["game_id"],
            "season": int(row["season"]),
            "week": int(row["week"]),
            "date": row["gameday"],
            "home": team(row["home_team"]),
            "away": team(row["away_team"]),
            "homeScore": int(row["home_score"]),
            "awayScore": int(row["away_score"]),
            "spreadLine": num(row["spread_line"]),
            "totalLine": num(row["total_line"]),
            "homeCoach": row["home_coach"].strip() or None,
            "awayCoach": row["away_coach"].strip() or None,
            "homeRest": int(row["home_rest"]) if row["home_rest"] else None,
            "awayRest": int(row["away_rest"]) if row["away_rest"] else None,
        }
    team_weeks = []
    for row in csv.DictReader(team_path.open(newline="", encoding="utf-8-sig")):
        game = schedule.get(row["game_id"])
        if game is None or row["season_type"] != "REG":
            continue
        club = team(row["team"])
        if club not in (game["home"], game["away"]):
            raise ValueError(f"Team {club} is not in {row['game_id']}")
        team_weeks.append({
            "gameId": game["id"],
            "season": game["season"],
            "week": game["week"],
            "date": game["date"],
            "team": club,
            "opponent": team(row["opponent_team"]),
            "attempts": num(row["attempts"]),
            "carries": num(row["carries"]),
            "passingYards": num(row["passing_yards"]),
            "rushingYards": num(row["rushing_yards"]),
            "sackYardsLost": num(row["sack_yards_lost"]),
            "passingInterceptions": num(row["passing_interceptions"]),
            "fumblesLost": num(row["fumbles_lost_total"]),
            "passingEpa": num(row["passing_epa"]),
            "rushingEpa": num(row["rushing_epa"]),
            "defInterceptions": num(row["def_interceptions"]),
        })
    players = []
    kept = (
        "attempts", "carries", "targets", "receptions", "passing_yards",
        "rushing_yards", "receiving_yards", "passing_interceptions",
        "sacks_suffered", "rushing_fumbles_lost", "receiving_fumbles_lost",
    )
    for row in csv.DictReader(player_path.open(newline="", encoding="utf-8-sig")):
        if row["season_type"] != "REG" or int(row["week"]) < 11:
            continue
        game = schedule.get(row["game_id"])
        if game is None or game["date"] <= MAIN_CUTOFF:
            continue
        if not row["player_id"] or not row["player_display_name"]:
            continue
        stats = {key: num(row[key]) for key in kept}
        players.append({
            "playerId": row["player_id"],
            "name": row["player_display_name"],
            "position": row["position"] or "Unknown",
            "team": team(row["team"]),
            "opponent": team(row["opponent_team"]),
            "season": int(row["season"]),
            "week": int(row["week"]),
            "date": game["date"],
            "seasonType": "REG",
            "stats": stats,
        })
    injuries = []
    for row in csv.DictReader(injury_path.open(newline="", encoding="utf-8-sig")):
        kind = (row.get("season_type") or row.get("game_type") or "REG").strip()
        if kind not in ("REG", ""):
            continue
        if int(row["week"]) < 11 or row["season"] != "2026":
            continue
        status = (row.get("report_status") or "").strip()
        practice = (row.get("practice_status") or "").strip()
        if not status and not practice:
            continue
        injuries.append({
            "week": int(row["week"]),
            "team": team(row["team"]),
            "player": row["full_name"].strip(),
            "position": (row.get("position") or "").strip().upper(),
            "status": status,
            "practice": practice,
            "injury": (row.get("report_primary_injury") or "").strip(),
        })
    games = [schedule[key] for key in sorted(schedule)]
    payload = {
        "schema": 1,
        "license": "CC BY 4.0",
        "licenseUrl": "https://creativecommons.org/licenses/by/4.0/",
        "source": "nflverse schedules, team weekly stats, player weekly stats and injuries",
        "retrievedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "mainBundleCutoff": MAIN_CUTOFF,
        "notice": (
            "Games after the main player bundle, plus 2026 team box scores and "
            "head coaches from the schedule. Sack yards are the source's own sign. "
            "No front-office, trade or general-manager feed is in these files. "
            "Third-down attempts are not in the team weekly file. "
            "Snap counts are not copied here; they stay in nfl-matchup.json and "
            "do not yet include every later week."
        ),
        "sources": [
            {"url": f"{RELEASES}/schedules/games.csv", "sha256": sha(games_path)},
            {"url": f"{RELEASES}/stats_team/stats_team_week_2026.csv", "sha256": sha(team_path)},
            {"url": f"{RELEASES}/stats_player/stats_player_week_2026.csv", "sha256": sha(player_path)},
            {"url": f"{RELEASES}/injuries/injuries_2026.csv", "sha256": sha(injury_path)},
        ],
        "games": games,
        "teamWeeks": team_weeks,
        "players": players,
        "injuries": injuries,
    }
    DEST.write_text(json.dumps(payload, separators=(",", ":"), allow_nan=False) + "\n", encoding="utf-8")
    print(json.dumps({
        "games": len(games),
        "teamWeeks": len(team_weeks),
        "players": len(players),
        "injuries": len(injuries),
        "bytes": DEST.stat().st_size,
    }))


if __name__ == "__main__":
    main()
