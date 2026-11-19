#!/usr/bin/env python3
"""Refresh dated NFL history and stored matchup context from free nflverse CSVs.

No odds API, live-availability claim, or inferred injury-report date. The two
required sources validate before either asset is changed. An optional injury
failure retains its previous records and provenance, with an explicit failure
status. Downloads are bounded; output files are replaced atomically.
"""
from __future__ import annotations

import argparse
import copy
import csv
import hashlib
import io
import json
import math
import os
import sys
import tempfile
import urllib.request
from datetime import date, datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
RELEASES = "https://github.com/nflverse/nflverse-data/releases/download"
SCHEDULE_URL = f"{RELEASES}/schedules/games.csv"
LICENSE_URL = "https://creativecommons.org/licenses/by/4.0/"
TEAMS = set("ARI ATL BAL BUF CAR CHI CIN CLE DAL DEN DET GB HOU IND JAX KC LV LAC LA MIA MIN NE NO NYG NYJ PHI PIT SF SEA TB TEN WAS".split())
ALIASES = {"LAR": "LA", "OAK": "LV", "SD": "LAC", "STL": "LA"}
POST = {"WC", "DIV", "CON", "SB", "POST"}
LISTED_STATUSES = {"Out", "Questionable", "Doubtful"}
NOTE = "nflverse participation, the play-by-play record of who was on the field, is not updated during the season. Snap counts are used instead."


def iso(at: datetime) -> str:
    if at.tzinfo is None:
        raise ValueError("Retrieval time must include a timezone.")
    return at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def nfl_season(day: date) -> int:
    """January/February belong to the preceding NFL season."""
    return day.year if day.month >= 3 else day.year - 1


def day_value(raw: str) -> date:
    value = date.fromisoformat(raw)
    if value.isoformat() != raw:
        raise ValueError("Expected an ISO calendar date.")
    return value


def _integer(raw: object, field: str, low: int, high: int) -> int:
    try:
        number = float(str(raw))
        if not math.isfinite(number) or not number.is_integer():
            raise ValueError()
        value = int(number)
    except (ValueError, TypeError, OverflowError) as error:
        raise ValueError(f"Invalid {field}.") from error
    if not low <= value <= high:
        raise ValueError(f"Invalid {field}.")
    return value


def _line(raw: object, low: float, high: float) -> float | None:
    """Optional closing line; blank or out of range stays unknown, never zero."""
    text = str(raw or "").strip()
    if not text:
        return None
    try:
        value = float(text)
    except ValueError:
        return None
    if not math.isfinite(value) or not low <= value <= high:
        return None
    return value


def _text(raw: object, field: str) -> str:
    if not isinstance(raw, str) or not raw.strip() or len(raw) > 240:
        raise ValueError(f"Missing or invalid {field}.")
    return raw.strip()


def _team(raw: object) -> str:
    value = _text(raw, "NFL team").upper()
    value = ALIASES.get(value, value)
    if value not in TEAMS:
        raise ValueError("Unknown NFL team.")
    return value


def _game_type(raw: str) -> str:
    if raw == "REG":
        return raw
    if raw in POST:
        return "POST"
    raise ValueError("Unsupported game type.")


def csv_rows(raw: bytes, required: set[str]) -> list[dict[str, str]]:
    reader = csv.DictReader(io.StringIO(raw.decode("utf-8-sig")))
    if not required.issubset(reader.fieldnames or []):
        raise ValueError("Source CSV schema is unavailable.")
    rows = list(reader)
    if not rows or any(None in row for row in rows):
        raise ValueError("Source CSV is empty or malformed.")
    return rows


def parse_schedule(rows: list[dict[str, str]]) -> dict[str, dict]:
    games: dict[str, dict] = {}
    for row in rows:
        # Only regular and postseason games are relevant to this research app.
        if row.get("game_type") not in {"REG", *POST}:
            continue
        game_id = _text(row.get("game_id"), "game ID")
        if game_id in games:
            raise ValueError("Duplicate schedule game ID.")
        home, away = _team(row.get("home_team")), _team(row.get("away_team"))
        if home == away:
            raise ValueError("A game cannot have the same team on both sides.")
        home_raw, away_raw = row.get("home_score", ""), row.get("away_score", "")
        if bool(home_raw.strip()) != bool(away_raw.strip()):
            raise ValueError("Schedule has an incomplete score pair.")
        games[game_id] = dict(
            id=game_id, season=_integer(row.get("season"), "season", 1920, 2200),
            week=_integer(row.get("week"), "week", 1, 23),
            date=day_value(_text(row.get("gameday"), "game date")),
            gameType=_game_type(row["game_type"]), home=home, away=away,
            homeScore=None if not home_raw.strip() else _integer(home_raw, "home score", 0, 150),
            awayScore=None if not away_raw.strip() else _integer(away_raw, "away score", 0, 150),
        )
        # nflverse closing lines: spread_line is the home margin the market expected.
        spread, total = _line(row.get("spread_line"), -40, 40), _line(row.get("total_line"), 20, 80)
        if spread is not None:
            games[game_id]["spreadLine"] = spread
        if total is not None:
            games[game_id]["totalLine"] = total
    if not games:
        raise ValueError("No NFL schedule games are available.")
    return games


def completed(game: dict, as_of: date) -> bool:
    return game["date"] <= as_of and game["homeScore"] is not None and game["awayScore"] is not None


def latest_completed_season(schedule: dict[str, dict], as_of: date) -> int:
    """Use recorded games, so offseason refreshes keep the available season."""
    seasons = [game["season"] for game in schedule.values() if completed(game, as_of)]
    if not seasons:
        raise ValueError("No completed NFL season records are available through the cutoff.")
    return max(seasons)


def build_history(schedule: dict[str, dict], as_of: date, season: int,
                  retrieved_at: datetime, source_sha256: str) -> dict:
    games = [
        {key: value.isoformat() if key == "date" else value for key, value in game.items() if key != "gameType"}
        for game in schedule.values()
        if season - 4 <= game["season"] <= season and game["gameType"] == "REG" and completed(game, as_of)
    ]
    games.sort(key=lambda row: (row["date"], row["id"]))
    if not games:
        raise ValueError("No completed history is available through the cutoff.")
    return dict(
        schema=1, source="nflverse schedules", sourceUrl=SCHEDULE_URL,
        sourceSha256=source_sha256, retrievedAt=iso(retrieved_at),
        cutoff=max(row["date"] for row in games), currentSeason=season,
        license="CC BY 4.0", licenseUrl=LICENSE_URL,
        changes=f"Selected completed {season - 4}–{season} regular-season games on or before {as_of.isoformat()}; retained dates, teams, final scores and nflverse closing spread/total lines where published (for trend research; no prices). Current week may be incomplete; historical revisions are not point-in-time replay.",
        games=games,
    )


def _provenance(*, source_url: str, as_of: date, cutoff: date | None,
                retrieved_at: datetime, season: int, weeks: list[int],
                sha256: str, count: int, source_count: int) -> dict:
    return dict(sourceUrl=source_url, cutoff=None if cutoff is None else cutoff.isoformat(),
                retrievedAt=iso(retrieved_at), season=season,
                throughWeek=max(weeks, default=None), sha256=sha256,
                status="undated" if cutoff is None else "fresh" if (as_of - cutoff).days <= 14 else "stale",
                rowCount=count, sourceRowCount=source_count)


def _percentage(raw: str | None) -> float | None:
    if raw in (None, "", "NA"):
        return None
    try:
        value = float(raw)
    except ValueError as error:
        raise ValueError("Invalid snap share.") from error
    if not math.isfinite(value) or not 0 <= value <= 1:
        raise ValueError("Snap shares must be finite fractions from zero to one.")
    return value


def build_snaps(rows: list[dict[str, str]], schedule: dict[str, dict],
                as_of: date, season: int, retrieved_at: datetime,
                source_sha256: str) -> tuple[list[dict], dict]:
    output, dates, weeks, seen = [], [], [], set()
    for row in rows:
        if _integer(row.get("season"), "snap season", 1920, 2200) != season:
            raise ValueError("Snap source season does not match the request.")
        game = schedule.get(_text(row.get("game_id"), "snap game ID"))
        if game is None:
            raise ValueError("A snap game is absent from the schedule.")
        week = _integer(row.get("week"), "snap week", 1, 23)
        if game["season"] != season or game["week"] != week or game["gameType"] != _game_type(row.get("game_type", "")):
            raise ValueError("Snap game metadata disagrees with the schedule.")
        team, opponent = _team(row.get("team")), _team(row.get("opponent"))
        if {team, opponent} != {game["home"], game["away"]} or team == opponent:
            raise ValueError("Snap teams disagree with the schedule.")
        name = _text(row.get("player"), "snap player")
        position = _text(row.get("position") or "Unknown", "snap position").upper()
        offense, defense = _percentage(row.get("offense_pct")), _percentage(row.get("defense_pct"))
        key = (game["id"], team, row.get("pfr_player_id") or name)
        if key in seen:
            raise ValueError("Duplicate player snap record.")
        seen.add(key)
        if not completed(game, as_of):
            continue
        output.append(dict(week=week, team=team, opponent=opponent,
                           player=name, position=position, offensePct=offense, defensePct=defense))
        dates.append(game["date"])
        weeks.append(week)
    if not output:
        raise ValueError("No completed snap records are available through the cutoff.")
    output.sort(key=lambda row: (row["week"], row["team"], row["player"]))
    provenance = _provenance(source_url=f"{RELEASES}/snap_counts/snap_counts_{season}.csv",
        as_of=as_of, cutoff=max(dates), retrieved_at=retrieved_at, season=season,
        weeks=weeks, sha256=source_sha256, count=len(output), source_count=len(rows))
    return output, provenance


def _report_day(raw: str | None) -> date | None:
    if raw in (None, "", "NA"):
        return None
    if len(raw) == 10:
        return day_value(raw)
    try:
        at = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("Invalid injury report timestamp.") from error
    if at.tzinfo is None:
        raise ValueError("Injury report timestamp lacks a timezone.")
    return at.astimezone(ZoneInfo("America/New_York")).date()


def build_injuries(rows: list[dict[str, str]], schedule: dict[str, dict],
                   as_of: date, season: int, retrieved_at: datetime,
                   source_sha256: str) -> tuple[list[dict], dict]:
    output, report_dates, weeks, seen = [], [], [], set()
    undated, eligible = False, 0
    fixtures = {
        (game["week"], team): game
        for game in schedule.values() if game["season"] == season
        for team in (game["home"], game["away"])
    }
    for row in rows:
        if _integer(row.get("season"), "injury season", 1920, 2200) != season:
            raise ValueError("Injury source season does not match the request.")
        week = _integer(row.get("week"), "injury week", 1, 23)
        team = _team(row.get("team"))
        name = _text(row.get("full_name"), "injury player")
        position = _text(row.get("position") or "Unknown", "injury position").upper()
        report_day = _report_day(row.get("date_modified"))
        game = fixtures.get((week, team))
        if game is None:
            raise ValueError("Injury team/week is absent from the schedule.")
        if _game_type(row.get("season_type") or row.get("game_type", "")) != game["gameType"]:
            raise ValueError("Injury game type disagrees with the schedule.")
        # Without report dates, future fixture weeks cannot establish evidence
        # available by an historical cutoff. Fixture dates do not become report dates.
        if report_day is not None and report_day > as_of or report_day is None and game["date"] > as_of:
            continue
        key = (week, team, row.get("gsis_id") or name)
        if key in seen:
            raise ValueError("Duplicate weekly injury record.")
        seen.add(key)
        eligible += 1
        weeks.append(week)
        if report_day is None:
            undated = True
        else:
            report_dates.append(report_day)
        status = row.get("report_status", "").strip()
        if status not in LISTED_STATUSES:
            continue
        output.append(dict(week=week, team=team, player=name, position=position,
                           status=status, injury=row.get("report_primary_injury", "").strip()))
    if not eligible:
        raise ValueError("No eligible injury source records are available.")
    output.sort(key=lambda row: (row["week"], row["team"], row["player"]))
    provenance = _provenance(source_url=f"{RELEASES}/injuries/injuries_{season}.csv",
        as_of=as_of, cutoff=None if undated or not report_dates else max(report_dates),
        retrieved_at=retrieved_at, season=season, weeks=weeks, sha256=source_sha256,
        count=len(output), source_count=eligible)
    return output, provenance


def retained_injuries(previous: dict, season: int, attempted_at: datetime) -> tuple[list[dict], dict]:
    rows = copy.deepcopy(previous.get("injuries", []))
    if not isinstance(rows, list):
        raise ValueError("Previous injury records are malformed.")
    prior = previous.get("provenance", {}).get("injuries")
    if isinstance(prior, dict):
        provenance = copy.deepcopy(prior)
        provenance.setdefault("season", previous.get("season"))
    else:
        provenance = dict(sourceUrl=previous.get("injurySource"),
            cutoff=previous.get("cutoff"), retrievedAt=previous.get("retrievedAt"),
            season=previous.get("season"),
            throughWeek=max((row.get("week", 0) for row in rows if isinstance(row, dict)), default=None),
            sha256=None, rowCount=len(rows))
    provenance.update(status="retained" if rows or provenance.get("retrievedAt") else "unavailable",
                      lastAttemptAt=iso(attempted_at), error="source_unavailable")
    return rows, provenance


def download(url: str, limit: int = 20_000_000) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "OddsEdge evidence refresh"})
    with urllib.request.urlopen(request, timeout=45) as response:
        raw = response.read(limit + 1)
    if len(raw) > limit:
        raise ValueError("Unexpected evidence source size.")
    return raw


def _read_existing(path: Path) -> dict:
    if not path.exists():
        return {}
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise ValueError("Previous evidence asset must be an object.")
    return value


def _guard_regression(history: dict, matchup: dict, old_history: dict, old_matchup: dict) -> None:
    """Reject suspicious truncations, while allowing normal source corrections."""
    if len(history["games"]) < 500:
        raise ValueError("History source is unexpectedly incomplete.")
    if len(matchup["snaps"]) < 500:
        raise ValueError("Snap source is unexpectedly incomplete.")
    old_games = old_history.get("games", [])
    old_season = old_history.get("currentSeason") or max((row.get("season", 0) for row in old_games), default=0)
    # A new season intentionally drops the oldest of the five stored seasons.
    # Inside the same season a two-percent loss is already suspicious.
    minimum_ratio = .98 if old_season == history["currentSeason"] else .8
    if len(history["games"]) < minimum_ratio * len(old_games):
        raise ValueError("History coverage unexpectedly regressed.")
    old_cutoff = max((row.get("date", "") for row in old_games), default="")
    if history["cutoff"] < old_cutoff:
        raise ValueError("History date coverage unexpectedly regressed.")
    if old_matchup.get("season") == matchup["season"]:
        old_snaps = old_matchup.get("snaps", [])
        if len(matchup["snaps"]) < .98 * len(old_snaps):
            raise ValueError("Snap coverage unexpectedly regressed.")
        old_week = max((row.get("week", 0) for row in old_snaps), default=0)
        new_week = matchup["provenance"]["snaps"]["throughWeek"] or 0
        if new_week < old_week:
            raise ValueError("Snap week coverage unexpectedly regressed.")
        old_cutoff = old_matchup.get("provenance", {}).get("snaps", {}).get("cutoff")
        new_cutoff = matchup["provenance"]["snaps"]["cutoff"]
        if isinstance(old_cutoff, str) and new_cutoff < old_cutoff:
            raise ValueError("Snap date coverage unexpectedly regressed.")


def atomic_write_batch(payloads: dict[Path, bytes]) -> None:
    """Stage every file first; restore the previous batch if replacement fails."""
    staged: dict[Path, Path] = {}
    old = {path: path.read_bytes() if path.exists() else None for path in payloads}
    replaced: list[Path] = []
    try:
        for path, raw in payloads.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
                temporary = Path(handle.name)
                staged[path] = temporary
                handle.write(raw)
                handle.flush()
                os.fsync(handle.fileno())
        for path, temporary in staged.items():
            os.replace(temporary, path)
            replaced.append(path)
    except Exception:
        for path in replaced:
            original = old[path]
            if original is None:
                path.unlink(missing_ok=True)
            else:
                with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.restore.", delete=False) as handle:
                    restore = Path(handle.name)
                    handle.write(original)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(restore, path)
        raise
    finally:
        for temporary in staged.values():
            temporary.unlink(missing_ok=True)


def refresh_evidence(*, output_dir: Path, as_of: date, season: int | None = None,
                     now: datetime, source_dir: Path | None = None,
                     fetch=download, strict: bool = True,
                     report_path: Path | None = None) -> dict:
    history_path, matchup_path = output_dir / "nfl-history.json", output_dir / "nfl-matchup.json"
    previous_history, previous_matchup = _read_existing(history_path), _read_existing(matchup_path)

    def source(filename: str, url: str) -> bytes:
        return (source_dir / filename).read_bytes() if source_dir is not None else fetch(url)

    schedule_raw = source("games.csv", SCHEDULE_URL)
    schedule = parse_schedule(csv_rows(schedule_raw, {"game_id", "season", "game_type", "week", "gameday", "home_team", "away_team", "home_score", "away_score"}))
    if season is None:
        season = latest_completed_season(schedule, as_of)
    history = build_history(schedule, as_of, season, now, hashlib.sha256(schedule_raw).hexdigest())
    snap_raw = source(f"snap_counts_{season}.csv", f"{RELEASES}/snap_counts/snap_counts_{season}.csv")
    snaps, snap_provenance = build_snaps(csv_rows(snap_raw, {"game_id", "season", "game_type", "week", "team", "opponent", "player", "position", "offense_pct", "defense_pct"}),
        schedule, as_of, season, now, hashlib.sha256(snap_raw).hexdigest())
    warnings = []
    try:
        injury_raw = source(f"injuries_{season}.csv", f"{RELEASES}/injuries/injuries_{season}.csv")
        injury_rows = csv_rows(injury_raw, {"season", "week", "team", "full_name", "position", "report_status", "report_primary_injury"})
        if strict and len(injury_rows) < 100:
            raise ValueError("Injury source is unexpectedly incomplete.")
        injuries, injury_provenance = build_injuries(injury_rows, schedule, as_of, season, now, hashlib.sha256(injury_raw).hexdigest())
        previous_injuries = previous_matchup.get("injuries", [])
        if strict and previous_matchup.get("season") == season and len(injuries) < .98 * len(previous_injuries):
            raise ValueError("Injury source unexpectedly regressed.")
    except (OSError, ValueError, UnicodeError, csv.Error):
        injuries, injury_provenance = retained_injuries(previous_matchup, season, now)
        warnings.append("injury_source_unavailable_previous_records_retained" if injuries else "injury_source_unavailable_no_previous_records")
    matchup = dict(schema=1, license="CC BY 4.0", licenseUrl=LICENSE_URL,
        sourceName="nflverse", injurySource=injury_provenance.get("sourceUrl"),
        snapSource=snap_provenance["sourceUrl"], season=season,
        participationNote=NOTE, provenance=dict(snaps=snap_provenance, injuries=injury_provenance),
        snaps=snaps, injuries=injuries)
    if strict:
        _guard_regression(history, matchup, previous_history, previous_matchup)
    report = dict(asOf=as_of.isoformat(), season=season, retrievedAt=iso(now),
                history=dict(cutoff=history["cutoff"], games=len(history["games"])),
                snaps=snap_provenance, injuries=injury_provenance, warnings=warnings,
                oddsRequests=0)
    encoded = {path: (json.dumps(data, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
               for path, data in [(history_path, history), (matchup_path, matchup)]}
    if report_path is not None:
        if report_path.resolve() in {history_path.resolve(), matchup_path.resolve()}:
            raise ValueError("Refresh report must not replace an evidence asset.")
        encoded[report_path] = (json.dumps(report, indent=2, allow_nan=False) + "\n").encode("utf-8")
    atomic_write_batch(encoded)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--as-of", type=day_value, help="Inclusive Eastern game/report date; defaults to today in Eastern time.")
    parser.add_argument("--season", type=int, help="NFL season override; otherwise use the latest season with a completed game by the cutoff.")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "assets")
    parser.add_argument("--source-dir", type=Path, help="Offline CSV directory: games.csv, snap_counts_YEAR.csv, injuries_YEAR.csv.")
    parser.add_argument("--report", type=Path, help="Optional JSON refresh report outside the published app assets.")
    args = parser.parse_args()
    now = datetime.now(timezone.utc)
    today = now.astimezone(ZoneInfo("America/New_York")).date()
    as_of = args.as_of or today
    season = args.season
    if as_of > today or (season is not None and not 1920 <= season <= 2200):
        raise ValueError("Use an available research date and valid NFL season.")
    report = refresh_evidence(output_dir=args.output_dir, as_of=as_of, season=season,
        now=now, source_dir=args.source_dir, report_path=args.report)
    print(json.dumps(report))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Evidence refresh failed; previous assets preserved: {type(error).__name__}: {error}", file=sys.stderr)
        raise SystemExit(1)
