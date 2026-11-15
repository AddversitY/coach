"""Coordinator tests use synthetic assets and never start a model or network call."""
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from datetime import date, datetime, timezone
from pathlib import Path
from unittest.mock import patch

from refresh_research import ASSETS, default_as_of, refresh_research


class ResearchRefreshTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.assets = Path(self.temporary.name) / "assets"
        self.assets.mkdir()
        self.previous = {name: (json.dumps({"previous": name}) + "\n").encode() for name in ASSETS}
        for name, raw in self.previous.items():
            (self.assets / name).write_bytes(raw)
        self.as_of = date(2026, 11, 14)
        self.now = datetime(2026, 11, 15, 12, tzinfo=timezone.utc)
        self.calls = []

    def assert_previous_intact(self):
        self.assertEqual({name: (self.assets / name).read_bytes() for name in ASSETS}, self.previous)

    def write_json(self, path, data):
        path.write_text(json.dumps(data), encoding="utf-8")

    def successful_runner(self, command, **options):
        self.assert_previous_intact()
        self.assertTrue(options["check"])
        self.assertTrue(options["capture_output"])
        self.calls.append(command)
        script = Path(command[1]).name
        if script == "import_player_stats.py":
            destination = Path(command[command.index("--output") + 1])
            self.assertNotEqual(destination.parent, self.assets)
            self.assertEqual(command[command.index("--cutoff") + 1], "2026-11-14")
            self.write_json(destination, {
                "cutoff": "2026-11-09", "statKeys": ["targets"],
                "rows": [{"date": "2026-11-09", "stats": [4]}],
            })
        elif script == "import_evidence.py":
            stage = Path(command[command.index("--output-dir") + 1])
            self.assertEqual(command[command.index("--as-of") + 1], "2026-11-14")
            self.write_json(stage / ASSETS[1], {
                "cutoff": "2026-11-12", "games": [{"date": "2026-11-12"}],
            })
            self.write_json(stage / ASSETS[2], {
                "snaps": [{"week": 10}], "injuries": [],
                "provenance": {
                    "snaps": {"cutoff": "2026-11-12", "status": "fresh"},
                    "injuries": {"cutoff": None, "status": "unavailable"},
                },
            })
            self.write_json(Path(command[command.index("--report") + 1]), {"warnings": ["injury_source_unavailable"]})
        elif script == "parlay_simulation.py":
            stage = Path(command[command.index("--asset-dir") + 1])
            self.write_json(stage / ASSETS[3], {
                "schema": 1, "uniqueGames": 2, "dataCutoff": "2026-11-09",
                "correlated": {"count": 2}, "independent": {"count": 2},
                "sourceHashes": {name: hashlib.sha256((stage / name).read_bytes()).hexdigest() for name in ASSETS[:2]},
            })
        else:
            self.fail("Unexpected external command")
        return subprocess.CompletedProcess(command, 0, "", "")

    def refresh(self, runner=None):
        return refresh_research(asset_dir=self.assets, as_of=self.as_of, now=self.now,
                                runner=runner or self.successful_runner)

    def test_all_processing_uses_stage_then_replaces_the_complete_batch(self):
        report = self.refresh()
        self.assertEqual(len(self.calls), 3)
        for name in ASSETS:
            self.assertNotEqual((self.assets / name).read_bytes(), self.previous[name])
        self.assertEqual(report["playerCutoff"], "2026-11-09")
        self.assertEqual(report["historyCutoff"], "2026-11-12")
        self.assertEqual(report["validationGames"], 2)
        self.assertEqual(report["sources"]["warnings"], ["injury_source_unavailable"])
        self.assertEqual(report["oddsRequests"], 0)
        stage = Path(self.calls[0][-1]).parent
        self.assertFalse(stage.exists(), "Temporary evidence must be cleaned up.")

    def test_any_command_failure_leaves_originals_untouched(self):
        for failed_script in ("import_player_stats.py", "import_evidence.py", "parlay_simulation.py"):
            with self.subTest(script=failed_script):
                self.calls.clear()
                def runner(command, **options):
                    if Path(command[1]).name == failed_script:
                        raise subprocess.CalledProcessError(1, command, stderr="synthetic source failure")
                    return self.successful_runner(command, **options)
                with self.assertRaisesRegex(RuntimeError, "previous assets preserved"):
                    self.refresh(runner)
                self.assert_previous_intact()

    def test_timeout_leaves_originals_untouched(self):
        def runner(command, **options):
            raise subprocess.TimeoutExpired(command, options["timeout"])
        with self.assertRaises(subprocess.TimeoutExpired):
            self.refresh(runner)
        self.assert_previous_intact()

    def test_invalid_json_or_report_hash_cannot_replace_good_assets(self):
        for problem in ("nonfinite", "wrong_hash", "future_row", "wrong_cutoff"):
            with self.subTest(problem=problem):
                self.calls.clear()
                def runner(command, **options):
                    result = self.successful_runner(command, **options)
                    if Path(command[1]).name != "parlay_simulation.py":
                        return result
                    stage = Path(command[command.index("--asset-dir") + 1])
                    report_path = stage / ASSETS[3]
                    if problem == "nonfinite":
                        report_path.write_text('{"bad":NaN}', encoding="utf-8")
                    elif problem == "wrong_hash":
                        report = json.loads(report_path.read_text())
                        report["sourceHashes"][ASSETS[0]] = "wrong"
                        self.write_json(report_path, report)
                    else:
                        player_path = stage / ASSETS[0]
                        players = json.loads(player_path.read_text())
                        if problem == "future_row":
                            players["rows"][0]["date"] = "2026-11-16"
                        else:
                            players["cutoff"] = "2026-11-08"
                        self.write_json(player_path, players)
                    return result
                with self.assertRaises(ValueError):
                    self.refresh(runner)
                self.assert_previous_intact()

    def test_replace_failure_rolls_back_every_previous_file(self):
        original_replace = os.replace
        failed = False
        def replace(source, destination):
            nonlocal failed
            if Path(destination).name == ASSETS[2] and not failed:
                failed = True
                raise OSError("synthetic disk failure")
            return original_replace(source, destination)
        with patch("import_evidence.os.replace", side_effect=replace):
            with self.assertRaisesRegex(OSError, "synthetic disk failure"):
                self.refresh()
        self.assertTrue(failed)
        self.assert_previous_intact()
        self.assertEqual(sorted(path.name for path in self.assets.iterdir()), sorted(ASSETS))

    def test_future_as_of_is_rejected_before_any_command(self):
        self.as_of = date(2026, 11, 16)
        with self.assertRaisesRegex(ValueError, "future"):
            self.refresh()
        self.assertEqual(self.calls, [])
        self.assert_previous_intact()

    def test_default_cutoff_uses_previous_eastern_day_across_utc_rollover(self):
        self.assertEqual(default_as_of(datetime(2026, 11, 15, 2, tzinfo=timezone.utc)), date(2026, 11, 13))
        self.assertEqual(default_as_of(datetime(2026, 3, 9, 3, tzinfo=timezone.utc)), date(2026, 3, 7))
        self.assertEqual(default_as_of(datetime(2026, 3, 9, 12, tzinfo=timezone.utc)), date(2026, 3, 8))


if __name__ == "__main__":
    unittest.main()
