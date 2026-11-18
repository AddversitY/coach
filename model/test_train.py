"""Publication safeguards; all inputs are small local fixtures."""

import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from datetime import date

from train import acquire_snaps, load_offense, load_schedule, write_document
from weather import historical_weather


def valid_document():
    return {
        "v2": {"players": [{"name": str(i)} for i in range(201)]},
        "backtest": {"decided": 600, "hitRate": .5, "favoriteHitRate": .5},
        "teams": {str(i): {} for i in range(32)},
        "coverModel": {}, "totalModel": {},
        "projection": {"homeFieldAdvantage": 2.0},
    }


class TrainingPublicationTest(unittest.TestCase):
    def test_missing_core_sources_cannot_silently_use_a_partial_fit(self):
        with patch("train.download", return_value=False):
            with self.assertRaisesRegex(SystemExit, "Schedule source missing"):
                load_schedule()
            with self.assertRaisesRegex(SystemExit, "Play-by-play source missing for 2026"):
                load_offense([2026])

    def test_archive_outage_stops_remote_retries_and_labels_fallbacks(self):
        stadiums = ["Lambeau Field", "Highmark Stadium", "MetLife Stadium",
                    "Soldier Field", "Gillette Stadium"]
        games = [{"id": str(i), "stadium": stadium, "roof": "outdoors",
                  "date": date(2026, 11, 1), "hour": 13,
                  "temp": 40 if i else None, "wind": None}
                 for i, stadium in enumerate(stadiums)]
        with TemporaryDirectory() as directory, patch("weather._archive", return_value=None) as archive:
            result = historical_weather(games, Path(directory))
        self.assertEqual([call.kwargs["fetch"] for call in archive.call_args_list],
                         [True, True, True, False, False])
        self.assertEqual(result["0"].source, "missing")
        self.assertEqual(result["1"].source, "nflverse-fallback")
        self.assertIsNone(result["1"].precip)

    def test_clean_checkout_acquires_each_season_and_refreshes_latest(self):
        with TemporaryDirectory() as directory:
            calls = []

            def fetch(url, path, *, force):
                season = int(path.stem.rsplit("_", 1)[1])
                calls.append((season, force, url))
                path.write_text(
                    "player,team,season,week,offense_pct,defense_pct,position\n" +
                    "".join(f"Player {i},BUF,{season},1,0.8,0,WR\n" for i in range(201)),
                    encoding="utf-8",
                )
                return True

            rows = acquire_snaps([2025, 2026], Path(directory), fetch)
            self.assertEqual(len(rows), 402)
            self.assertEqual([(season, force) for season, force, _ in calls],
                             [(2025, False), (2026, True)])
            self.assertTrue(all("/snap_counts/" in url for _, _, url in calls))

    def test_missing_or_short_season_aborts(self):
        with TemporaryDirectory() as directory:
            cache = Path(directory)
            with self.assertRaisesRegex(SystemExit, "missing for 2026"):
                acquire_snaps([2026], cache, lambda *args, **kwargs: False)
            (cache / "snap_counts_2026.csv").write_text(
                "player,team,season,week,offense_pct\nOne,BUF,2026,1,0.8\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(SystemExit, "Incomplete snap counts"):
                acquire_snaps([2026], cache, lambda *args, **kwargs: True)

    def test_bad_reports_cannot_replace_previous_report(self):
        with TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            output.write_text('{"previous":true}', encoding="utf-8")
            document = valid_document()
            document["v2"]["players"] = []
            with self.assertRaises(SystemExit):
                write_document(document, output)
            self.assertEqual(json.loads(output.read_text()), {"previous": True})
            document = valid_document()
            document["badFloat"] = float("nan")
            with self.assertRaises(ValueError):
                write_document(document, output)
            self.assertEqual(json.loads(output.read_text()), {"previous": True})
            write_document(valid_document(), output)
            self.assertEqual(len(json.loads(output.read_text())["v2"]["players"]), 201)
            self.assertFalse(output.with_suffix(".json.part").exists())


if __name__ == "__main__":
    unittest.main()
