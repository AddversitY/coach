import json
import unittest
from datetime import datetime, timezone

import prediction_markets as P
import qb_news as Q
import weather_watch as W


class KalshiTests(unittest.TestCase):
    def test_fee_and_team_split(self):
        self.assertEqual(P.kalshi_fee(0.5), 0.02)
        self.assertEqual(P.split_teams('KXNFLGAME-26NOV22JACNYG', {'JAC', 'NYG'}), ('JAC', 'NYG'))
        self.assertEqual(P.split_teams('KXNFLGAME-26NOV22GBLAR', {'GB', 'LAR'}), ('GB', 'LAR'))

    def test_mid_uses_last_candle_before_time(self):
        candles = [
            {'end_period_ts': 100, 'yes_bid': {'close_dollars': '0.40'}, 'yes_ask': {'close_dollars': '0.42'}},
            {'end_period_ts': 200, 'yes_bid': {'close_dollars': '0.50'}, 'yes_ask': {'close_dollars': '0.52'}},
        ]
        self.assertAlmostEqual(P.mid_at(candles, 150)[0], 0.41)
        self.assertIsNone(P.mid_at(candles, 50))

    def test_book_price_above_kalshi_fair_is_flagged(self):
        at = '2026-11-28T12:00:00Z'
        row = lambda book, outcome, dec: {'at': at, 'book': book, 'kickoff': '2026-11-29T18:00:00Z', 'away': 'NE',
                                          'home': 'LAC', 'market': 'h2h', 'outcome': outcome, 'line': None,
                                          'decimal': dec, 'player': ''}
        history = {'observations': [row('fanduel', 'Los Angeles Chargers', 2.2), row('fanduel', 'New England Patriots', 1.7)]}
        kalshi = {('NE', 'LAC', '2026-11-29'): {'LAC': (0.50, 0.51), 'NE': (0.50, 0.51)}}
        flags = P.compare(kalshi, history, datetime(2026, 11, 28, 13, tzinfo=timezone.utc))
        kinds = {(f['kind'], f['side']) for f in flags}
        self.assertIn(('book beats Kalshi', 'home'), kinds)
        self.assertNotIn(('book beats Kalshi', 'away'), kinds)


class WeatherTests(unittest.TestCase):
    def test_window_covers_three_hours_from_kickoff(self):
        payload = {'hourly': {
            'time': ['2026-11-29T17:00', '2026-11-29T18:00', '2026-11-29T19:00', '2026-11-29T20:00', '2026-11-29T21:00'],
            'wind_speed_10m': [5, 16, 18, 20, 40], 'wind_gusts_10m': [8, 25, 30, 28, 60],
            'precipitation': [0, 0.5, 0.2, 0, 3], 'temperature_2m': [40, 41, 42, 43, 44]}}
        window = W.game_window(payload, datetime(2026, 11, 29, 18, tzinfo=timezone.utc))
        self.assertEqual(window['windMph'], 18.0)
        self.assertEqual(window['gustMph'], 30)
        self.assertEqual(window['rainMm'], 0.7)


class StarterTests(unittest.TestCase):
    def test_top_starters_get_expected_moves(self):
        ratings = {'players': [
            {'n': 'Wide One', 't': 'NE', 'p': 'WR', 'o': 90, 's': 600},
            {'n': 'Wide Two', 't': 'NE', 'p': 'WR', 'o': 80, 's': 500},
            {'n': 'Wide Three', 't': 'NE', 'p': 'WR', 'o': 70, 's': 100},
        ]}
        statuses = {'NE': {'Wide One': ('Out', 'x'), 'Wide Two': ('Questionable', 'x'), 'Wide Three': ('Out', 'x')}}
        alerts = Q.starter_alerts(ratings, statuses)
        names = [a['player'] for a in alerts]
        self.assertEqual(names, ['Wide One', 'Wide Two'])  # The third receiver is not a starter.
        self.assertEqual(alerts[0]['expectedLineMovePoints'], 0.49)


if __name__ == '__main__':
    unittest.main()
