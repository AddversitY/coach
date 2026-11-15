import csv
import io
import json
import tempfile
import unittest
from datetime import date, datetime, timezone
from pathlib import Path
from unittest.mock import patch

from import_evidence import (
    SCHEDULE_URL, atomic_write_batch, build_history, build_injuries, build_snaps,
    csv_rows, day_value, nfl_season, latest_completed_season, parse_schedule, refresh_evidence, _guard_regression,
    retained_injuries,
)

NOW = datetime(2026, 11, 15, 7, tzinfo=timezone.utc)
AS_OF = date(2026, 11, 15)


def game(game_id="2026_09_BUF_KC", week="9", day="2026-11-01", **changes):
    return dict(game_id=game_id, season="2026", game_type="REG", week=week,
                gameday=day, home_team="KC", away_team="BUF",
                home_score="21", away_score="17", **changes)


def schedule_rows():
    return [game(), game("2026_10_BUF_KC", "10", "2026-11-08"),
            game("2026_11_BUF_KC", "11", "2026-11-15")]


def snap(game_id="2026_10_BUF_KC", week="10", **changes):
    row = dict(game_id=game_id, season="2026", game_type="REG", week=week,
               player="Josh Allen", pfr_player_id="AlleJo02", position="QB",
               team="BUF", opponent="KC", offense_pct="0.9", defense_pct="0")
    row.update(changes)
    return row


def injury(week="10", **changes):
    row = dict(season="2026", season_type="REG", week=week, team="BUF",
               full_name="Josh Allen", gsis_id="00-0034857", position="QB",
               report_status="Questionable", report_primary_injury="Knee")
    row.update(changes)
    return row


def encoded(rows):
    out = io.StringIO()
    writer = csv.DictWriter(out, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
    return out.getvalue().encode()


class TransformTests(unittest.TestCase):
    def setUp(self):
        self.schedule = parse_schedule(schedule_rows())

    def test_nfl_season_rollover_does_not_follow_calendar_year(self):
        self.assertEqual(nfl_season(date(2027, 1, 18)), 2026)
        self.assertEqual(nfl_season(date(2027, 2, 14)), 2026)
        self.assertEqual(nfl_season(date(2027, 3, 1)), 2027)

    def test_offseason_keeps_the_latest_completed_season(self):
        schedule = parse_schedule(schedule_rows() + [
            {**game("2026_22_BUF_KC", "22", "2027-02-14"), "game_type": "SB"},
            {**game("2027_01_BUF_KC", "1", "2027-09-12"), "season": "2027", "home_score": "", "away_score": ""},
        ])
        for as_of in [date(2027, 2, 15), date(2027, 3, 1), date(2027, 8, 31)]:
            self.assertEqual(latest_completed_season(schedule, as_of), 2026)

    def test_season_selection_requires_a_completed_game_by_cutoff(self):
        schedule = parse_schedule([{**game(), "home_score": "", "away_score": ""}])
        with self.assertRaisesRegex(ValueError, "No completed"):
            latest_completed_season(schedule, AS_OF)

    def test_calendar_dates_are_strict(self):
        for raw in ["2026-02-30", "20261115", "2026-1-1", "2026-11-15T12:00Z"]:
            with self.assertRaises(ValueError):
                day_value(raw)

    def test_schema_empty_and_ragged_csv_fail_closed(self):
        for raw in [b"hello\nworld\n", b"game_id\n", b"game_id\na,b\n"]:
            with self.assertRaises(ValueError):
                csv_rows(raw, {"game_id"})

    def test_history_excludes_future_unfinished_and_postseason(self):
        rows = schedule_rows() + [
            game("future", "12", "2026-11-22"),
            {**game("unfinished", "10", "2026-11-10"), "home_score": "", "away_score": ""},
            {**game("post", "19", "2026-01-10"), "game_type": "WC"},
        ]
        bundle = build_history(parse_schedule(rows), AS_OF, 2026, NOW, "abc")
        self.assertEqual(len(bundle["games"]), 3)
        self.assertEqual(bundle["cutoff"], "2026-11-15")
        self.assertEqual(bundle["sourceSha256"], "abc")
        self.assertNotIn("gameType", bundle["games"][0])

    def test_history_retains_zero_score_as_completed(self):
        schedule = parse_schedule([{**game(), "away_score": "0"}])
        bundle = build_history(schedule, AS_OF, 2026, NOW, "abc")
        self.assertEqual(bundle["games"][0]["awayScore"], 0)

    def test_duplicate_schedule_and_invalid_teams_are_rejected(self):
        for rows in [[game(), game()], [{**game(), "home_team": "???"}], [{**game(), "away_team": "KC"}]]:
            with self.assertRaises(ValueError):
                parse_schedule(rows)

    def test_partial_score_pair_rejected(self):
        with self.assertRaises(ValueError):
            parse_schedule([{**game(), "away_score": ""}])

    def test_snap_coverage_comes_from_observed_completed_game_dates(self):
        rows, provenance = build_snaps([snap()], self.schedule, AS_OF, 2026, NOW, "snap-hash")
        self.assertEqual(rows[0]["offensePct"], .9)
        self.assertEqual(provenance["cutoff"], "2026-11-08")
        self.assertEqual(provenance["throughWeek"], 10)
        self.assertEqual(provenance["status"], "fresh")
        self.assertEqual(provenance["rowCount"], 1)
        self.assertEqual(provenance["sha256"], "snap-hash")

    def test_snap_identity_and_metadata_must_match_schedule(self):
        for row in [snap(game_id="missing"), snap(week="9"), snap(opponent="NE"), snap(season="2025")]:
            with self.assertRaises(ValueError):
                build_snaps([row], self.schedule, AS_OF, 2026, NOW, "x")

    def test_snap_values_zero_missing_and_invalid_are_distinct(self):
        rows, _ = build_snaps([snap(offense_pct="0", defense_pct="")], self.schedule, AS_OF, 2026, NOW, "x")
        self.assertEqual(rows[0]["offensePct"], 0)
        self.assertIsNone(rows[0]["defensePct"])
        for raw in ["NaN", "Infinity", "1.1", "-0.1"]:
            with self.assertRaises(ValueError):
                build_snaps([snap(offense_pct=raw)], self.schedule, AS_OF, 2026, NOW, "x")

    def test_duplicate_snaps_are_not_double_counted(self):
        with self.assertRaises(ValueError):
            build_snaps([snap(), snap()], self.schedule, AS_OF, 2026, NOW, "x")

    def test_missing_source_positions_remain_unknown(self):
        snaps, _ = build_snaps([snap(position="")], self.schedule, AS_OF, 2026, NOW, "x")
        injuries, _ = build_injuries([injury(position="")], self.schedule, AS_OF, 2026, NOW, "x")
        self.assertEqual(snaps[0]["position"], "UNKNOWN")
        self.assertEqual(injuries[0]["position"], "UNKNOWN")

    def test_unfinished_and_future_snap_games_are_excluded(self):
        schedule = parse_schedule(schedule_rows() + [{**game("future", "12", "2026-11-22"), "home_score": "", "away_score": ""}])
        rows, _ = build_snaps([snap(), snap("future", "12")], schedule, AS_OF, 2026, NOW, "x")
        self.assertEqual(len(rows), 1)

    def test_old_snap_coverage_is_stale_despite_new_retrieval(self):
        _, provenance = build_snaps([snap("2026_09_BUF_KC", "9")], self.schedule, date(2026, 11, 20), 2026, NOW, "x")
        self.assertEqual(provenance["status"], "stale")
        self.assertEqual(provenance["retrievedAt"], "2026-11-15T07:00:00Z")

    def test_undated_injury_week_does_not_become_a_calendar_cutoff(self):
        rows, provenance = build_injuries([injury()], self.schedule, AS_OF, 2026, NOW, "x")
        self.assertEqual(len(rows), 1)
        self.assertEqual(provenance["throughWeek"], 10)
        self.assertIsNone(provenance["cutoff"])
        self.assertEqual(provenance["status"], "undated")
        self.assertEqual(provenance["retrievedAt"], "2026-11-15T07:00:00Z")

    def test_actual_report_dates_use_eastern_calendar_and_exclude_future(self):
        rows, provenance = build_injuries([
            injury(date_modified="2026-11-15T02:00:00Z"),
            injury("11", date_modified="2026-11-16T20:00:00Z"),
        ], self.schedule, AS_OF, 2026, NOW, "x")
        self.assertEqual(len(rows), 1)
        self.assertEqual(provenance["cutoff"], "2026-11-14")

    def test_any_unknown_injury_date_keeps_coverage_unknown(self):
        _, provenance = build_injuries([
            injury(date_modified="2026-11-12"), injury("9", date_modified="")
        ], self.schedule, AS_OF, 2026, NOW, "x")
        self.assertIsNone(provenance["cutoff"])

    def test_practice_participation_is_not_a_game_status(self):
        rows, provenance = build_injuries([injury(report_status="", practice_status="Full Participation in Practice")], self.schedule, AS_OF, 2026, NOW, "x")
        self.assertEqual(rows, [])
        self.assertEqual(provenance["throughWeek"], 10)

    def test_injury_invalid_date_identity_or_duplicate_fail(self):
        cases = [[injury(date_modified="2026-02-30")], [injury(week="4")], [injury(), injury()]]
        for rows in cases:
            with self.assertRaises(ValueError):
                build_injuries(rows, self.schedule, AS_OF, 2026, NOW, "x")

    def test_retained_injuries_preserve_provenance_not_attempt_time(self):
        previous = dict(injuries=[dict(week=9, player="A")], provenance=dict(injuries=dict(
            sourceUrl="https://example.test/injuries.csv", cutoff="2026-11-01",
            retrievedAt="2026-11-02T10:00:00Z", season=2026, sha256="old", status="fresh")))
        rows, provenance = retained_injuries(previous, 2026, NOW)
        self.assertEqual(provenance["retrievedAt"], "2026-11-02T10:00:00Z")
        self.assertEqual(provenance["cutoff"], "2026-11-01")
        self.assertEqual(provenance["sha256"], "old")
        self.assertEqual(provenance["status"], "retained")
        self.assertEqual(provenance["lastAttemptAt"], "2026-11-15T07:00:00Z")
        rows[0]["player"] = "Changed"
        self.assertEqual(previous["injuries"][0]["player"], "A")

    def test_legacy_retained_metadata_stays_unknown(self):
        _, provenance = retained_injuries(dict(season=2026, injuries=[dict(week=10)]), 2026, NOW)
        self.assertIsNone(provenance["cutoff"])
        self.assertIsNone(provenance["retrievedAt"])
        self.assertEqual(provenance["throughWeek"], 10)
        self.assertEqual(provenance["status"], "retained")

    def test_date_coverage_cannot_regress_behind_existing_good_assets(self):
        history = dict(currentSeason=2026, games=[dict(date="2026-11-12")] * 600, cutoff="2026-11-12")
        matchup = dict(season=2026, snaps=[dict(week=10)] * 600,
                       provenance=dict(snaps=dict(throughWeek=10, cutoff="2026-11-12")))
        old_history = dict(games=[dict(date="2026-11-13")] * 600)
        with self.assertRaisesRegex(ValueError, "History date"):
            _guard_regression(history, matchup, old_history, {})
        old_matchup = dict(season=2026, snaps=[dict(week=10)] * 600,
                           provenance=dict(snaps=dict(cutoff="2026-11-13")))
        with self.assertRaisesRegex(ValueError, "Snap date"):
            _guard_regression(history, matchup, {}, old_matchup)

    def test_same_season_coverage_rejects_three_percent_source_loss(self):
        history = dict(currentSeason=2026, cutoff="2026-11-12", games=[dict(date="2026-11-12")] * 970)
        matchup = dict(season=2026, snaps=[dict(week=10)] * 970,
                       provenance=dict(snaps=dict(throughWeek=10, cutoff="2026-11-12")))
        old_history = dict(currentSeason=2026, games=[dict(date="2026-11-12")] * 1000)
        with self.assertRaisesRegex(ValueError, "History coverage"):
            _guard_regression(history, matchup, old_history, {})
        old_matchup = dict(season=2026, snaps=[dict(week=10)] * 1000)
        with self.assertRaisesRegex(ValueError, "Snap coverage"):
            _guard_regression(history, matchup, {}, old_matchup)

    def test_prior_season_injury_fallback_never_relabels_season(self):
        for prior in [dict(season=2025, injuries=[dict(week=18)]),
                      dict(season=2025, injuries=[dict(week=18)], provenance=dict(injuries={}))]:
            _, provenance = retained_injuries(prior, 2026, NOW)
            self.assertEqual(provenance["season"], 2025)


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def fetch(self, url):
        if url == SCHEDULE_URL:
            return encoded(schedule_rows())
        if "/snap_counts/" in url:
            return encoded([snap()])
        return encoded([injury()])

    def test_valid_refresh_writes_both_assets_and_independent_metadata(self):
        report = refresh_evidence(output_dir=self.root, as_of=AS_OF, season=2026, now=NOW, fetch=self.fetch, strict=False)
        matchup = json.loads((self.root / "nfl-matchup.json").read_text())
        self.assertNotIn("retrievedAt", matchup)
        self.assertNotIn("cutoff", matchup)
        self.assertEqual(matchup["provenance"]["snaps"]["cutoff"], "2026-11-08")
        self.assertIsNone(matchup["provenance"]["injuries"]["cutoff"])
        self.assertEqual(report["oddsRequests"], 0)

    def test_default_season_requests_available_sources_during_march(self):
        urls = []
        def fetch(url):
            urls.append(url)
            return self.fetch(url)
        report = refresh_evidence(output_dir=self.root, as_of=date(2027, 3, 1),
                                  now=datetime(2027, 3, 1, tzinfo=timezone.utc), fetch=fetch, strict=False)
        self.assertEqual(report["season"], 2026)
        self.assertTrue(any("snap_counts_2026.csv" in url for url in urls))
        self.assertFalse(any("_2027.csv" in url for url in urls))

    def test_required_source_failure_preserves_both_previous_files(self):
        paths = [self.root / "nfl-history.json", self.root / "nfl-matchup.json"]
        for path in paths:
            path.write_text('{"original":true}')
        def fetch(url):
            return b"malformed" if "/snap_counts/" in url else self.fetch(url)
        with self.assertRaises(ValueError):
            refresh_evidence(output_dir=self.root, as_of=AS_OF, season=2026, now=NOW, fetch=fetch, strict=False)
        self.assertTrue(all(path.read_text() == '{"original":true}' for path in paths))

    def test_optional_injury_failure_retains_old_rows_and_freshens_required_sources(self):
        old = dict(season=2026, injuries=[dict(week=9, player="Stored")], provenance=dict(injuries=dict(
            retrievedAt="2026-11-01T10:00:00Z", cutoff=None, season=2026, status="undated")))
        (self.root / "nfl-matchup.json").write_text(json.dumps(old))
        def fetch(url):
            if "/injuries/" in url:
                raise OSError("offline")
            return self.fetch(url)
        report = refresh_evidence(output_dir=self.root, as_of=AS_OF, season=2026, now=NOW, fetch=fetch, strict=False)
        new = json.loads((self.root / "nfl-matchup.json").read_text())
        self.assertEqual(new["injuries"], old["injuries"])
        self.assertEqual(new["provenance"]["injuries"]["retrievedAt"], "2026-11-01T10:00:00Z")
        self.assertEqual(report["injuries"]["status"], "retained")
        self.assertTrue(report["warnings"])
        self.assertEqual(report["snaps"]["status"], "fresh")

    def test_suspiciously_small_required_sources_do_not_overwrite_assets(self):
        with self.assertRaisesRegex(ValueError, "incomplete"):
            refresh_evidence(output_dir=self.root, as_of=AS_OF, season=2026, now=NOW, fetch=self.fetch)
        self.assertFalse((self.root / "nfl-history.json").exists())
        self.assertFalse((self.root / "nfl-matchup.json").exists())

    def test_optional_report_is_part_of_the_same_atomic_batch(self):
        path = self.root / "report.json"
        result = refresh_evidence(output_dir=self.root, as_of=AS_OF, season=2026, now=NOW,
                                  fetch=self.fetch, strict=False, report_path=path)
        self.assertEqual(json.loads(path.read_text()), result)

    def test_report_path_cannot_replace_an_asset(self):
        with self.assertRaisesRegex(ValueError, "must not replace"):
            refresh_evidence(output_dir=self.root, as_of=AS_OF, season=2026, now=NOW,
                             fetch=self.fetch, strict=False, report_path=self.root / "nfl-matchup.json")
        self.assertFalse((self.root / "nfl-history.json").exists())

    def test_atomic_batch_restores_first_file_when_second_replace_fails(self):
        a, b = self.root / "a.json", self.root / "b.json"
        a.write_bytes(b"old-a")
        b.write_bytes(b"old-b")
        import os
        replace = os.replace
        counter = 0
        def fail_second(source, destination):
            nonlocal counter
            counter += 1
            if counter == 2:
                raise OSError("replacement failed")
            return replace(source, destination)
        with patch("import_evidence.os.replace", side_effect=fail_second):
            with self.assertRaises(OSError):
                atomic_write_batch({a: b"new-a", b: b"new-b"})
        self.assertEqual(a.read_bytes(), b"old-a")
        self.assertEqual(b.read_bytes(), b"old-b")
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["a.json", "b.json"])


if __name__ == "__main__":
    unittest.main()
