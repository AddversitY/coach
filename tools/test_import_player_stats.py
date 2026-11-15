import tempfile
import unittest
from datetime import date
from pathlib import Path

from import_player_stats import (
    METRICS, atomic_write, build_bundle, latest_completed_season, nfl_season, validate_replacement,
)


def fixture():
    game = dict(game_id='2026_10_BUF_KC', gameday='2026-11-09', season='2026',
                week='10', game_type='REG', home_team='KC', away_team='BUF',
                home_score='20', away_score='24')
    row = {key: '' for key in METRICS}
    row.update(player_id='player-1', player_display_name='Test Player', position='QB',
               game_id=game['game_id'], season='2026', week='10', season_type='REG',
               team='BUF', opponent_team='KC', passing_yards='0', attempts='20')
    return game, row


class PlayerImportTests(unittest.TestCase):
    def test_zero_missing_and_coverage_are_based_on_completed_records(self):
        game, row = fixture()
        bundle = build_bundle({game['game_id']: game}, {2026: [row]}, date(2026, 11, 14), 2026)
        stats = dict(zip(bundle['statKeys'], bundle['rows'][0]['stats']))
        self.assertEqual(stats['passing_yards'], 0)
        self.assertIsNone(stats['receiving_yards'])
        self.assertEqual(bundle['cutoff'], '2026-11-09')
        self.assertNotIn('retrievedAt', bundle)  # Set only after a successful fetch.

    def test_future_and_unfinished_games_are_excluded(self):
        game, row = fixture()
        for changes in ({'gameday': '2026-11-15'}, {'home_score': ''}):
            future = dict(game, **changes)
            with self.assertRaisesRegex(ValueError, 'no eligible'):
                build_bundle({game['game_id']: future}, {2026: [row]}, date(2026, 11, 14), 2026)

    def test_invalid_identity_opponent_and_nonfinite_stats_fail(self):
        game, row = fixture()
        for change in ({'opponent_team': 'DAL'}, {'team': 'DAL'},
                       {'season': '2025'}, {'passing_yards': 'NaN'}):
            with self.assertRaises(ValueError):
                build_bundle({game['game_id']: game}, {2026: [dict(row, **change)]},
                             date(2026, 11, 14), 2026)
        with self.assertRaisesRegex(ValueError, 'Unmatched'):
            build_bundle({}, {2026: [row]}, date(2026, 11, 14), 2026)
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            build_bundle({game['game_id']: game}, {2026: [row, row]}, date(2026, 11, 14), 2026)

    def test_regression_retains_previous_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / 'players.json'
            previous = dict(currentSeason=2026, cutoff='2026-11-09', rows=[{}] * 100)
            atomic_write(destination, previous)
            saved = destination.read_bytes()
            for changes in ({'cutoff': '2026-11-02'}, {'rows': [{}] * 90}):
                with self.assertRaises(ValueError):
                    validate_replacement(dict(previous, **changes), destination, date(2026, 11, 14))
                self.assertEqual(destination.read_bytes(), saved)

    def test_atomic_encoding_failure_does_not_replace_good_asset(self):
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / 'players.json'
            atomic_write(destination, {'rows': [0]})
            saved = destination.read_bytes()
            with self.assertRaises(ValueError):
                atomic_write(destination, {'rows': [float('nan')]})
            self.assertEqual(destination.read_bytes(), saved)
            self.assertEqual(list(Path(tmp).glob('*.tmp')), [])

    def test_postseason_calendar_does_not_roll_season_early(self):
        self.assertEqual(nfl_season(date(2027, 1, 20)), 2026)
        self.assertEqual(nfl_season(date(2027, 2, 10)), 2026)
        self.assertEqual(nfl_season(date(2027, 9, 10)), 2027)

    def test_offseason_selects_latest_played_season(self):
        game, _ = fixture()
        next_game = dict(game, season='2027', gameday='2027-09-09', home_score='', away_score='')
        schedule = {'old': dict(game, gameday='2027-02-07', game_type='SB'), 'new': next_game}
        self.assertEqual(latest_completed_season(schedule, date(2027, 3, 15)), 2026)
        self.assertEqual(latest_completed_season(schedule, date(2027, 8, 15)), 2026)
        schedule['new'].update(home_score='20', away_score='10')
        self.assertEqual(latest_completed_season(schedule, date(2027, 9, 10)), 2027)


if __name__ == '__main__':
    unittest.main()
