import json
import unittest
from datetime import datetime, timedelta, timezone

import line_timing
from price_history import FetchResult, capture_dense, empty_history


class LineTimingTests(unittest.TestCase):
    def test_slots_follow_the_pre_kickoff_marks(self):
        self.assertEqual(line_timing.slots_to_capture(24 * 60, []), ['T-24h'])
        self.assertEqual(line_timing.slots_to_capture(6 * 60, []), ['T-6h'])
        self.assertEqual(line_timing.slots_to_capture(3 * 60, []), ['T-3h'])
        self.assertEqual(line_timing.slots_to_capture(90, []), ['T-90m'])
        self.assertEqual(line_timing.slots_to_capture(30, []), ['T-30m'])
        self.assertEqual(line_timing.slots_to_capture(10, []), ['last'])
        self.assertEqual(line_timing.slots_to_capture(0, []), [])
        self.assertEqual(line_timing.slots_to_capture(90, ['T-90m']), [])
        self.assertEqual(line_timing.slots_to_capture(35, []), ['T-30m'])
        self.assertEqual(line_timing.slots_to_capture(50, []), ['T-90m'])

    def test_credit_plan_stops_at_the_reserve_and_the_cap(self):
        budget = line_timing.budget_template('2026-11')
        allowed, reason = line_timing.allow_spend(budget, 'game', None)
        self.assertFalse(allowed)
        self.assertIn('unavailable', reason)
        allowed, reason = line_timing.allow_spend(budget, 'game', 52)
        self.assertFalse(allowed)
        self.assertIn('reserve', reason)
        allowed, _reason = line_timing.allow_spend(budget, 'game', 400)
        self.assertTrue(allowed)
        budget['gameLineSpent'] = 46
        allowed, reason = line_timing.allow_spend(budget, 'game', 400)
        self.assertFalse(allowed)
        self.assertIn('cap', reason)
        self.assertEqual(
            line_timing.BACKEND_MAIN_LINE
            + line_timing.BACKEND_PROPS
            + line_timing.BACKEND_PINNACLE
            + line_timing.GAME_LINE_CAP
            + line_timing.PROP_CAP,
            400,
        )
        self.assertLess(
            400 + line_timing.CREDIT_RESERVE,
            line_timing.FREE_PLAN_CREDITS,
        )

    def test_open_to_close_late_move_key_number_and_disagreement(self):
        kickoff = '2026-11-22T18:00:00Z'
        rows = []
        for at, line, book in (
            ('2026-11-22T14:00:00Z', -2.5, 'draftkings'),
            ('2026-11-22T14:00:00Z', -2.5, 'fanduel'),
            ('2026-11-22T17:00:00Z', -4.5, 'draftkings'),
            ('2026-11-22T17:00:00Z', -3.5, 'fanduel'),
            ('2026-11-22T17:00:00Z', -4.5, 'pinnacle'),
        ):
            rows.append(self.spread(at, line, book, kickoff))
        moves = line_timing.build_moves(rows)
        self.assertEqual(len(moves), 1)
        move = moves[0]
        self.assertEqual(move['openLine'], -2.5)
        self.assertEqual(move['closeLine'], -4.5)
        self.assertEqual(move['lateFrom'], -2.5)
        self.assertEqual(move['lateTo'], -4.5)
        self.assertEqual(move['keyNumbers'], [3])
        self.assertEqual(move['pinnacleLine'], -4.5)
        self.assertEqual(move['retailLine'], -3.5)
        self.assertEqual(move['againstPublic'], 'unavailable')
        self.assertIsNone(move['steam'])

    def test_one_snapshot_has_no_move_and_steam_needs_three_books(self):
        kickoff = '2026-11-22T18:00:00Z'
        single = line_timing.build_moves([
            self.spread('2026-11-22T17:00:00Z', -3, 'draftkings', kickoff),
        ])
        self.assertIsNone(single[0]['openToClose'])
        self.assertIsNone(single[0]['lateMove'])
        self.assertIsNone(single[0]['keyNumbers'])
        rows = []
        for book, earlier, later in (
            ('draftkings', -3, -4),
            ('fanduel', -3, -4),
            ('betmgm', -3, -4.5),
        ):
            rows.append(self.spread('2026-11-22T16:00:00Z', earlier, book, kickoff))
            rows.append(self.spread('2026-11-22T16:10:00Z', later, book, kickoff))
        steam = line_timing.build_moves(rows)[0]['steam']
        self.assertEqual(steam['direction'], 'home')
        self.assertEqual(len(steam['books']), 3)

    def test_dense_capture_spends_three_credits_and_hides_the_key(self):
        secret = 'super-secret-value'
        kickoff = datetime(2026, 11, 22, 18, 0, tzinfo=timezone.utc)
        now = kickoff - timedelta(minutes=90)
        calls = []

        def fetch(url, headers):
            calls.append(url)
            if '/events?' in url and '/odds' not in url:
                return FetchResult(200, json.dumps([{
                    'id': 'ev1',
                    'commence_time': '2026-11-22T18:00:00Z',
                    'home_team': 'Houston Texans',
                    'away_team': 'Indianapolis Colts',
                }]), {'x-requests-remaining': '400', 'x-requests-last': '0'})
            if '/events/' in url:
                return FetchResult(200, json.dumps([{
                    'id': 'ev1',
                    'commence_time': '2026-11-22T18:00:00Z',
                    'home_team': 'Houston Texans',
                    'away_team': 'Indianapolis Colts',
                    'bookmakers': [{
                        'key': 'draftkings',
                        'markets': [{
                            'key': 'player_reception_yds',
                            'outcomes': [{
                                'name': 'Over',
                                'description': 'Nico Collins',
                                'price': 1.91,
                                'point': 74.5,
                            }],
                        }],
                    }],
                }]), {'x-requests-remaining': '396', 'x-requests-last': '1'})
            if '/odds?' in url:
                return FetchResult(200, json.dumps([{
                    'id': 'ev1',
                    'commence_time': '2026-11-22T18:00:00Z',
                    'home_team': 'Houston Texans',
                    'away_team': 'Indianapolis Colts',
                    'bookmakers': [{
                        'key': 'draftkings',
                        'markets': [{
                            'key': 'spreads',
                            'outcomes': [
                                {'name': 'Houston Texans', 'price': 1.91, 'point': -3},
                                {'name': 'Indianapolis Colts', 'price': 1.91, 'point': 3},
                            ],
                        }],
                    }],
                }]), {'x-requests-remaining': '397', 'x-requests-last': '3'})
            return FetchResult(403, json.dumps({'apiKey': secret}), {})

        history = empty_history()
        summary = capture_dense(
            history, None, fetch=fetch, pause=lambda _seconds: None, now=now, key=secret,
        )
        text = json.dumps(history)
        self.assertNotIn(secret, text)
        self.assertEqual(summary['gameCredits'], 3)
        self.assertEqual(summary['propCredits'], 1)
        self.assertEqual(history['budget']['gameLineSpent'], 3)
        self.assertEqual(history['budget']['propSpent'], 1)
        self.assertTrue(any(row['market'] == 'spreads' and row['line'] == -3 for row in history['observations']))
        self.assertTrue(any(row['player'] == 'Nico Collins' for row in history['observations']))
        self.assertTrue(calls)

    def test_low_remaining_does_not_call_the_odds_endpoint(self):
        secret = 'another-secret'
        kickoff = datetime(2026, 11, 22, 18, 0, tzinfo=timezone.utc)
        now = kickoff - timedelta(minutes=90)
        odds_calls = []

        def fetch(url, headers):
            if '/odds' in url:
                odds_calls.append(url)
            if '/events?' in url:
                return FetchResult(200, '[]', {'x-requests-remaining': '52', 'x-requests-last': '0'})
            return FetchResult(403, '', {})

        history = empty_history()
        history['observations'].append({
            'at': '2026-11-22T12:00:00Z',
            'source': 'saved',
            'book': 'draftkings',
            'eventId': 'ev1',
            'kickoff': '2026-11-22T18:00:00Z',
            'home': 'HOU',
            'away': 'IND',
            'market': 'spreads',
            'outcome': 'Houston Texans',
            'player': '',
            'line': -3,
            'decimal': 1.91,
            'status': 'open',
        })
        summary = capture_dense(
            history, None, fetch=fetch, pause=lambda _seconds: None, now=now, key=secret,
        )
        self.assertEqual(odds_calls, [])
        self.assertEqual(summary['gameCredits'], 0)
        self.assertNotIn(secret, json.dumps(history))

    def test_offseason_does_not_call_the_odds_host(self):
        kickoff = datetime(2026, 11, 22, 18, 0, tzinfo=timezone.utc)
        now = datetime(2026, 4, 1, tzinfo=timezone.utc)
        calls = []

        def fetch(url, headers):
            calls.append(url)
            return FetchResult(200, '[]', {'x-requests-remaining': '400', 'x-requests-last': '0'})

        history = empty_history()
        history['observations'].append(self.spread(
            '2026-11-22T16:30:00Z', -3, 'draftkings', kickoff.strftime('%Y-%m-%dT%H:%M:%SZ'),
        ))
        # A stored kickoff can look due if the clock is wrong. April must not spend.
        history['observations'][-1]['kickoff'] = (now + timedelta(minutes=90)).strftime('%Y-%m-%dT%H:%M:%SZ')
        summary = capture_dense(
            history, None, fetch=fetch, pause=lambda _seconds: None, now=now, key='offseason-secret',
        )
        self.assertFalse(any('the-odds-api' in url or 'apiKey=' in url for url in calls))
        self.assertEqual(summary['gameCredits'], 0)
        self.assertEqual(summary['propCredits'], 0)
        self.assertNotIn('offseason-secret', json.dumps(history))

    def spread(self, at, line, book, kickoff):
        return {
            'at': at,
            'book': book,
            'eventId': 'nflverse:2026_11_IND_HOU',
            'kickoff': kickoff,
            'home': 'HOU',
            'away': 'IND',
            'market': 'spreads',
            'outcome': 'Houston Texans',
            'player': '',
            'line': line,
            'decimal': 1.91,
        }


if __name__ == '__main__':
    unittest.main()
