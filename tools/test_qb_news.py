import unittest
from datetime import datetime, timezone

import qb_news as Q


def row(at, outcome, line, decimal, book='fanduel'):
    return {'at': at, 'book': book, 'kickoff': '2026-11-30T18:00:00Z', 'away': 'NE', 'home': 'LAC',
            'market': 'spreads', 'outcome': outcome, 'line': line, 'decimal': decimal, 'player': ''}


class QbNewsTests(unittest.TestCase):
    def setUp(self):
        self.ratings = {'teams': [{'t': 'NE', 'qb': 'Drake Maye'}, {'t': 'LAC', 'qb': 'Justin Herbert'}],
                        'players': [{'n': 'Drake Maye', 't': 'NE', 'p': 'QB', 'o': 85, 's': 600},
                                    {'n': 'Tommy DeVito', 't': 'NE', 'p': 'QB', 'o': 60, 's': 40}]}
        self.payload = {'injuries': [
            {'displayName': 'New England Patriots', 'injuries': [
                {'status': 'Out', 'date': '2026-11-27T15:00Z', 'athlete': {'displayName': 'Drake Maye', 'position': {'abbreviation': 'QB'}}},
                {'status': 'Active', 'date': '2026-11-27T15:00Z', 'athlete': {'displayName': 'Tommy DeVito', 'position': {'abbreviation': 'QB'}}},
            ]},
            {'displayName': 'Los Angeles Chargers', 'injuries': [
                {'status': 'Questionable', 'date': '2026-11-27T15:00Z', 'athlete': {'displayName': 'Justin Herbert', 'position': {'abbreviation': 'QB'}}},
            ]},
        ]}
        self.history = {'observations': [
            row('2026-11-26T12:00:00Z', 'Los Angeles Chargers', -3.0, 1.91),
            row('2026-11-28T12:00:00Z', 'Los Angeles Chargers', -6.5, 1.91),
            row('2026-11-28T12:00:00Z', 'New England Patriots', 6.5, 1.91),
            row('2026-11-28T12:00:00Z', 'Los Angeles Chargers', -6.0, 1.87, book='betmgm'),
        ]}

    def test_out_starter_makes_one_alert_with_before_and_after(self):
        statuses = Q.quarterback_statuses(self.payload)
        alerts = Q.build_alerts(self.ratings, statuses, self.history, datetime(2026, 11, 28, 13, tzinfo=timezone.utc))
        self.assertEqual(len(alerts), 1)
        alert = alerts[0]
        self.assertEqual(alert['team'], 'NE')
        self.assertEqual(alert['backup'], 'Tommy DeVito')
        self.assertEqual(alert['homeSpreadBeforeReport'], -3.0)
        self.assertEqual(alert['homeSpreadNow'], -6.25)  # median of -6.5 and -6
        # Best number on the Chargers: -6 beats -6.5.
        self.assertEqual(alert['bet']['line'], -6.0)

    def test_first_sighting_is_kept(self):
        log = {'alerts': []}
        statuses = Q.quarterback_statuses(self.payload)
        now = datetime(2026, 11, 28, 13, tzinfo=timezone.utc)
        alerts = Q.build_alerts(self.ratings, statuses, self.history, now)
        self.assertEqual(Q.merge(log, alerts), 1)
        self.assertEqual(Q.merge(log, alerts), 0)


if __name__ == '__main__':
    unittest.main()
