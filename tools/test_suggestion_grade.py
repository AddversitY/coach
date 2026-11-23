import unittest
from datetime import datetime, timezone

import suggestion_grade as G


def obs(book, market, outcome, decimal, line, at):
    return {'at': at, 'book': book, 'kickoff': '2026-11-22T18:00:00Z', 'away': 'ARI', 'home': 'KC',
            'market': market, 'outcome': outcome, 'line': line, 'decimal': decimal, 'player': ''}


def suggestion(**extra):
    base = {'eventId': 'nflverse:2026_11_ARI_KC', 'away': 'ARI', 'home': 'KC', 'kickoff': '2026-11-22T18:00:00Z',
            'market': 'spreads', 'player': '', 'side': 'home', 'outcome': 'Kansas City Chiefs', 'line': -3,
            'book': 'fanduel', 'decimal': 2.0, 'at': '2026-11-22T10:00:00Z'}
    base.update(extra)
    return base


class SuggestionGradeTests(unittest.TestCase):
    def test_append_skips_unchanged_prices(self):
        log = {'rows': []}
        self.assertEqual(G.append(log, [suggestion()]), 1)
        self.assertEqual(G.append(log, [suggestion(at='2026-11-22T11:00:00Z')]), 0)
        self.assertEqual(G.append(log, [suggestion(decimal=1.95)]), 1)

    def test_grades_against_market_close_and_result(self):
        late = '2026-11-22T17:50:00Z'
        history = {'observations': [
            obs('draftkings', 'spreads', 'Kansas City Chiefs', 1.91, -3.5, late),
            obs('draftkings', 'spreads', 'Arizona Cardinals', 1.91, 3.5, late),
            obs('betmgm', 'spreads', 'Kansas City Chiefs', 1.91, -3.5, late),
            obs('betmgm', 'spreads', 'Arizona Cardinals', 1.91, 3.5, late),
        ]}
        log = {'rows': [suggestion()]}
        closing = {'games': [{'season': 2026, 'week': 11, 'home': 'KC', 'away': 'ARI', 'homeScore': 27, 'awayScore': 24}]}
        graded = G.grade(log, history, closing, now=datetime(2026, 11, 23, tzinfo=timezone.utc))
        self.assertEqual(len(graded), 1)
        self.assertIsNone(graded[0]['clvPinnacle'])
        self.assertGreater(graded[0]['clvMarket'], 0)  # Took -3 at even money; closed -3.5 at 50%.
        self.assertEqual(graded[0]['result'], 'push')

    def test_future_games_are_not_graded(self):
        graded = G.grade({'rows': [suggestion()]}, {'observations': []}, None,
                         now=datetime(2026, 11, 22, 12, tzinfo=timezone.utc))
        self.assertEqual(graded, [])


if __name__ == '__main__':
    unittest.main()
