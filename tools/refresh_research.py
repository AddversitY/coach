#!/usr/bin/env python3
"""Refresh the four research assets together, with no partial publication.

Every importer and the dependence report operate on temporary copies. Only a
validated, internally consistent batch replaces the previous assets. A failed
source, calculation, validation or file replacement leaves the prior batch in
place. No sportsbook calls or credentials are used.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from import_evidence import atomic_write_batch

ROOT = Path(__file__).resolve().parents[1]
ASSETS = (
    "nfl-player-stats.json",
    "nfl-history.json",
    "nfl-matchup.json",
    "parlay-calibration.json",
)


def eastern_day(now: datetime | None = None) -> date:
    at = now if now is not None else datetime.now(timezone.utc)
    if at.tzinfo is None:
        raise ValueError("Research refresh time must include a timezone.")
    return at.astimezone(ZoneInfo("America/New_York")).date()


def default_as_of(now: datetime | None = None) -> date:
    """A completed Eastern calendar day, including around UTC/DST rollover."""
    return eastern_day(now) - timedelta(days=1)


def calendar_day(raw: object) -> date:
    if not isinstance(raw, str):
        raise ValueError("Research date must be YYYY-MM-DD.")
    value = date.fromisoformat(raw)
    if value.isoformat() != raw:
        raise ValueError("Research date must be YYYY-MM-DD.")
    return value


def _invalid_constant(value: str) -> None:
    raise ValueError(f"Research assets cannot contain {value}.")


def read_object(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8-sig"), parse_constant=_invalid_constant)
    if not isinstance(value, dict):
        raise ValueError(f"{path.name} must contain a JSON object.")
    return value


def _known_cutoff(raw: object, as_of: date, label: str) -> date:
    cutoff = calendar_day(raw)
    if cutoff > as_of:
        raise ValueError(f"{label} coverage exceeds the research date.")
    return cutoff


def validate_batch(stage: Path, as_of: date) -> dict[str, dict]:
    """Catch missing/invalid output and prevent a report from dating new inputs."""
    data = {name: read_object(stage / name) for name in ASSETS}
    players, history, context, report = (data[name] for name in ASSETS)
    rows, games = players.get("rows"), history.get("games")
    if not isinstance(rows, list) or not rows or not isinstance(players.get("statKeys"), list) or not players["statKeys"]:
        raise ValueError("Refreshed player records are missing.")
    if not isinstance(games, list) or not games:
        raise ValueError("Refreshed final scores are missing.")
    player_cutoff = _known_cutoff(players.get("cutoff"), as_of, "Player")
    history_cutoff = _known_cutoff(history.get("cutoff"), as_of, "History")
    for label, records, cutoff in (("Player", rows, player_cutoff), ("History", games, history_cutoff)):
        dates = []
        for row in records:
            if not isinstance(row, dict):
                raise ValueError(f"{label} records must be objects.")
            dates.append(_known_cutoff(row.get("date"), as_of, label))
        if max(dates) != cutoff:
            raise ValueError(f"{label} cutoff must describe the actual records.")
    if not isinstance(context.get("snaps"), list) or not context["snaps"] or not isinstance(context.get("injuries"), list):
        raise ValueError("Refreshed matchup context is missing.")
    provenance = context.get("provenance")
    if not isinstance(provenance, dict):
        raise ValueError("Matchup sources need independent provenance.")
    for name in ("snaps", "injuries"):
        source = provenance.get(name)
        if not isinstance(source, dict):
            raise ValueError(f"{name} provenance is missing.")
        if source.get("cutoff") is not None:
            _known_cutoff(source["cutoff"], as_of, name)
    hashes = report.get("sourceHashes")
    expected_hashes = {
        name: hashlib.sha256((stage / name).read_bytes()).hexdigest()
        for name in ASSETS[:2]
    }
    if hashes != expected_hashes or report.get("dataCutoff") != players["cutoff"]:
        raise ValueError("Dependence report does not match the refreshed evidence.")
    if report.get("schema") != 1 or not isinstance(report.get("uniqueGames"), int) or report["uniqueGames"] < 1:
        raise ValueError("Dependence report has no validation games.")
    for name in ("correlated", "independent"):
        score = report.get(name)
        if not isinstance(score, dict) or not isinstance(score.get("count"), int) or score["count"] < 1:
            raise ValueError("Dependence report has no paired validation records.")
    return data


def refresh_research(*, asset_dir: Path, as_of: date, now: datetime | None = None,
                     runner=subprocess.run) -> dict:
    if as_of > eastern_day(now):
        raise ValueError("Research date cannot be in the future.")
    asset_dir = asset_dir.resolve()
    previous = {name: (asset_dir / name).read_bytes() for name in ASSETS}
    with tempfile.TemporaryDirectory(prefix="odds-edge-research-") as temporary:
        stage = Path(temporary)
        for name, raw in previous.items():
            (stage / name).write_bytes(raw)
        commands = (
            ("Player box scores", [sys.executable, str(ROOT / "tools/import_player_stats.py"), "--cutoff", as_of.isoformat(), "--output", str(stage / ASSETS[0])], 360),
            ("Matchup evidence", [sys.executable, str(ROOT / "tools/import_evidence.py"), "--as-of", as_of.isoformat(), "--output-dir", str(stage), "--report", str(stage / "refresh-report.json")], 300),
            ("Dependence report", [sys.executable, str(ROOT / "model/parlay_simulation.py"), "--asset-dir", str(stage)], 900),
        )
        for label, command, timeout in commands:
            try:
                runner(command, cwd=ROOT, check=True, capture_output=True, text=True, timeout=timeout)
            except subprocess.CalledProcessError as error:
                detail = (error.stderr or error.stdout or "").strip()[-1600:]
                raise RuntimeError(f"{label} refresh failed; previous assets preserved. {detail}") from error
        data = validate_batch(stage, as_of)
        refresh_report = read_object(stage / "refresh-report.json")
        atomic_write_batch({asset_dir / name: (stage / name).read_bytes() for name in ASSETS})
    return {
        "asOf": as_of.isoformat(),
        "playerCutoff": data[ASSETS[0]]["cutoff"],
        "historyCutoff": data[ASSETS[1]]["cutoff"],
        "sources": refresh_report,
        "validationGames": data[ASSETS[3]]["uniqueGames"],
        "assets": list(ASSETS),
        "oddsRequests": 0,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--as-of", type=calendar_day, help="Inclusive Eastern game/report date; defaults to yesterday in Eastern time.")
    parser.add_argument("--asset-dir", type=Path, default=ROOT / "assets")
    args = parser.parse_args()
    report = refresh_research(asset_dir=args.asset_dir, as_of=args.as_of or default_as_of())
    print(json.dumps(report, allow_nan=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Research refresh failed; previous assets preserved: {type(error).__name__}: {error}", file=sys.stderr)
        raise SystemExit(1)
