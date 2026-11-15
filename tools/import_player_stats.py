#!/usr/bin/env python3
"""Rebuild assets/nfl-player-stats.json from nflverse box scores.

The files are the public nflverse releases, CC BY 4.0. This script does
not call The Odds API and does not scrape a sportsbook. The Tuesday
workflow runs it so the bundled snapshot is not left on an old cutoff.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import tempfile
import urllib.request
from datetime import date, datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "assets" / "nfl-player-stats.json"
CACHE = ROOT / "model" / ".cache" / "player-stats"

RELEASES = "https://github.com/nflverse/nflverse-data/releases/download"
GROUPS = {
    "passing": [
        "completions",
        "attempts",
        "passing_yards",
        "passing_tds",
        "passing_interceptions",
        "sacks_suffered",
    ],
    "rushing": [
        "carries",
        "rushing_yards",
        "rushing_tds",
        "rushing_fumbles_lost",
    ],
    "receiving": [
        "targets",
        "receptions",
        "receiving_yards",
        "receiving_tds",
        "receiving_yards_after_catch",
        "receiving_fumbles_lost",
    ],
    "defense": [
        "def_tackles_solo",
        "def_tackles_with_assist",
        "def_tackle_assists",
        "def_sacks",
        "def_interceptions",
        "def_pass_defended",
        "def_tds",
        "def_fumbles_forced",
    ],
    "kicking": ["fg_made", "fg_att", "pat_made", "pat_att"],
    "punting": ["pt_att", "pt_yards"],
}
METRICS = sorted({metric for group in GROUPS.values() for metric in group})
POST = {"WC", "DIV", "CON", "SB", "POST"}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--cutoff",
        default=datetime.now(ZoneInfo('America/New_York')).date().isoformat(),
        help="Inclusive game date. Later games, and games without a score, are left out.",
    )
    parser.add_argument("--current-season", type=int)
    parser.add_argument("--output", type=Path, default=DESTINATION)
    args = parser.parse_args()
    cutoff = date.fromisoformat(args.cutoff)
    schedule_path = _download(
        f"{RELEASES}/schedules/games.csv",
        CACHE / "games.csv",
    )
    schedule = _schedule(schedule_path)
    current_season = args.current_season or latest_completed_season(schedule, cutoff)
    seasons = list(range(current_season - 3, current_season + 1))
    sources: list[dict[str, object]] = []
    records: dict[int, list[dict[str, str]]] = {}
    for season in seasons:
        url = f"{RELEASES}/stats_player/stats_player_week_{season}.csv"
        path = _download(url, CACHE / f"stats_player_week_{season}.csv")
        sources.append({"season": season, "url": url, "sha256": _sha256(path)})
        with path.open(newline="", encoding="utf-8-sig") as handle:
            reader = csv.DictReader(handle)
            required = METRICS + ['player_id', 'player_display_name', 'game_id',
                                  'season_type', 'season', 'week', 'team', 'opponent_team', 'position']
            missing = [key for key in required if key not in (reader.fieldnames or [])]
            if missing:
                raise ValueError(f"{path.name} is missing {', '.join(missing)}")
            records[season] = list(reader)
            if len(records[season]) < 500:
                raise ValueError(f"Unexpected player source size for {season}")
    bundle = build_bundle(schedule, records, cutoff, current_season)
    bundle.update(sourceFiles=sources, scheduleSha256=_sha256(schedule_path),
                  retrievedAt=datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'))
    validate_replacement(bundle, args.output, cutoff)
    atomic_write(args.output, bundle)
    print(json.dumps({"rows": len(bundle['rows']),
                      "players": len({row['playerId'] for row in bundle['rows']}),
                      "bytes": args.output.stat().st_size, "cutoff": bundle['cutoff'],
                      "excluded": bundle['excludedFutureOrUnfinished']}))


def nfl_season(day: date) -> int:
    """January/February games belong to the previous NFL season."""
    return day.year - 1 if day.month <= 2 else day.year


def latest_completed_season(schedule, cutoff: date) -> int:
    """Keep the last played season through the offseason, not a missing CSV."""
    seasons = [int(game['season']) for game in schedule.values()
               if game['game_type'] in {'REG', *POST}
               and date.fromisoformat(game['gameday']) <= cutoff
               and game['home_score'] != '' and game['away_score'] != '']
    if not seasons:
        raise ValueError('No completed NFL season is available')
    return max(seasons)


def build_bundle(schedule, records, cutoff: date, current_season: int):
    """Normalize complete source records without network or filesystem writes."""
    rows: list[dict[str, object]] = []
    seen: set[str] = set()
    excluded = 0
    unattributed = 0
    for season in sorted(records):
        if season not in range(current_season - 3, current_season + 1):
            raise ValueError('Source season is outside the selected four seasons')
        for record in records[season]:
            if not record.get("player_id") or not record.get("player_display_name"):
                unattributed += 1
                continue
            game = schedule.get(record["game_id"])
            if game is None:
                raise ValueError(
                    f"Unmatched game {record['game_id']}; refresh the schedule before importing."
                )
            played = date.fromisoformat(game["gameday"])
            if played > cutoff or game["home_score"] == "" or game["away_score"] == "":
                excluded += 1
                continue
            season_type = _season_type(game["game_type"])
            if (
                season_type != record["season_type"]
                or int(game["season"]) != int(record["season"])
                or int(game["week"]) != int(record["week"])
            ):
                raise ValueError(f"Mismatched game metadata {record['game_id']}")
            if int(record['season']) != season:
                raise ValueError('Player row is in the wrong season source')
            if season_type not in {'REG', 'POST'}:
                excluded += 1
                continue
            if record["team"] == game["home_team"]:
                opponent = game["away_team"]
            elif record["team"] == game["away_team"]:
                opponent = game["home_team"]
            else:
                raise ValueError(f"Team does not match game {record['game_id']}")
            if opponent != record["opponent_team"]:
                raise ValueError(f"Opponent does not match game {record['game_id']}")
            key = f"{record['player_id']}|{season}|{record['season_type']}|{record['week']}"
            if key in seen:
                raise ValueError(f"Duplicate player game {key}")
            seen.add(key)
            stats = [_number(record[metric], metric) for metric in METRICS]
            rows.append(
                {
                    "playerId": record["player_id"],
                    "name": record["player_display_name"],
                    "position": record["position"] or "Unknown",
                    "team": record["team"],
                    "opponent": record["opponent_team"],
                    "season": int(record["season"]),
                    "week": int(record["week"]),
                    "date": game["gameday"],
                    "seasonType": record["season_type"],
                    "stats": stats,
                }
            )
    if not rows:
        raise ValueError('Player source has no eligible completed games')
    latest = max(row["date"] for row in rows)
    bundle = {
        "schema": 1,
        "sport": "american_football",
        "league": "NFL",
        "currentSeason": current_season,
        "cutoff": latest,
        "source": "nflverse contributors — player box scores and schedules",
        "sourceUrl": "https://github.com/nflverse/nflverse-data/releases/tag/stats_player",
        "dictionaryUrl": "https://nflreadr.nflverse.com/articles/dictionary_player_stats.html",
        "license": "CC BY 4.0",
        "licenseUrl": "https://creativecommons.org/licenses/by/4.0/",
        "scheduleUrl": f"{RELEASES}/schedules/games.csv",
        "changes": (
            "Selected four NFL seasons through the latest completed game on or before the cutoff; "
            "joined completed schedules by game ID; retained identity, historical teams, dates and "
            "additive box-score counts. All source zeroes retained; missing values stay null. "
            "Packed numeric arrays use statKeys to preserve metrics compactly. No headshots, odds, "
            "rates, injuries or projections. Regular season and postseason kept distinct."
        ),
        "coverage": (
            "Recorded player box-score rows, not a complete participation or DNP log. "
            "Current season and current week can be incomplete. Historical revisions may be present; "
            "not point-in-time replay."
        ),
        "excludedFutureOrUnfinished": excluded,
        "excludedUnattributedRows": unattributed,
        "statKeys": METRICS,
        "rows": rows,
    }
    return bundle


def validate_replacement(bundle, destination: Path, requested_cutoff: date):
    if not destination.exists():
        return
    previous = json.loads(destination.read_text(encoding='utf-8-sig'))
    if previous.get('currentSeason') != bundle['currentSeason']:
        return
    old_cutoff = previous.get('cutoff')
    if old_cutoff and requested_cutoff.isoformat() >= old_cutoff:
        if bundle['cutoff'] < old_cutoff:
            raise ValueError('Player coverage regressed; previous asset retained')
        if len(bundle['rows']) < len(previous.get('rows', [])) * .98:
            raise ValueError('Player source lost more than 2% of rows; previous asset retained')


def atomic_write(destination: Path, bundle):
    destination.parent.mkdir(parents=True, exist_ok=True)
    pending = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=destination.parent,
                                         prefix=destination.name+'.', suffix='.tmp', delete=False) as handle:
            pending = Path(handle.name)
            json.dump(bundle, handle, separators=(',', ':'), allow_nan=False)
        os.replace(pending, destination)
    finally:
        if pending is not None and pending.exists():
            pending.unlink()


def _download(url: str, path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": "odds-edge-player-stats"})
    with urllib.request.urlopen(request, timeout=45) as response:
        payload = response.read(40_000_001)
        if len(payload) > 40_000_000:
            raise ValueError('Unexpectedly large player source')
        path.write_bytes(payload)
    return path


def _schedule(path: Path) -> dict[str, dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        required = ['game_id', 'gameday', 'season', 'week', 'game_type', 'home_team',
                    'away_team', 'home_score', 'away_score']
        if not set(required).issubset(reader.fieldnames or []):
            raise ValueError('Schedule is missing required columns')
        result = {}
        for row in reader:
            identity = row['game_id']
            if not identity or identity in result:
                raise ValueError('Schedule identities are missing or duplicated')
            date.fromisoformat(row['gameday'])
            result[identity] = row
        if not result:
            raise ValueError('Schedule is empty')
        return result


def _season_type(game_type: str) -> str:
    if game_type == "REG":
        return "REG"
    if game_type in POST:
        return "POST"
    return game_type


def _number(raw: str, metric: str) -> int | float | None:
    if raw is None or raw == "" or raw == "NA":
        return None
    value = float(raw)
    if value != value or value in (float("inf"), float("-inf")):
        raise ValueError(f"Nonfinite statistic {metric}")
    if value.is_integer():
        return int(value)
    return value


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    digest.update(path.read_bytes())
    return digest.hexdigest()


if __name__ == "__main__":
    main()
