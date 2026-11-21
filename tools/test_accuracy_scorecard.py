import json
import unittest
from datetime import datetime, timezone

from accuracy_scorecard import (
    apply_platt,
    build_scorecard,
    no_vig,
    sentence,
    shifted_probability,
)


NOW = datetime(2026, 11, 21, 22, tzinfo=timezone.utc)


def game(home_score, away_score, week=10):
    return {
        'season': 2026,
        'week': week,
        'date': __import__('datetime').date(2026, 11, 15),
        'away': 'BUF',
        'home': 'KC',
        'home_score': home_score,
        'away_score': away_score,
    }


def close(market, outcome, decimal, line, book='draftkings'):
    return {
        'at': '2026-11-15T16:00:00Z',
        'book': book,
        'eventId': 'nflverse:2026_10_BUF_KC',
        'kickoff': '2026-11-15T18:00:00Z',
        'season': 2026,
        'week': 10,
        'away': 'BUF',
        'home': 'KC',
        'market': market,
        'outcome': outcome,
        'line': line,
        'decimal': decimal,
    }


def model():
    return {
        'v2': {
            'sigma': 13,
            'totalSigma': 13,
            'marginCap': 4,
            'totalCap': 6,
            'scales': {
                'qb': 0, 'injury': 0, 'rest': 0, 'travel': 0,
                'weather': 0, 'injuryTotal': 0, 'qbTotal': 0,
            },
            'coverCalibration': {'intercept': 0, 'slope': 1},
            'totalCalibration': {'intercept': 0, 'slope': 1},
            'teams': {'BUF': {'homeLon': -78.8}, 'KC': {'homeLon': -94.5}},
        }
    }


class AccuracyScorecardTests(unittest.TestCase):
    def test_no_vig_needs_both_sides(self):
        self.assertAlmostEqual(no_vig(1.91, 1.91), 0.5)
        self.assertIsNone(no_vig(1.91, None))
        self.assertIsNone(no_vig(1.0, 1.91))

    def test_zero_residual_leaves_the_market_before_calibration(self):
        self.assertAlmostEqual(shifted_probability(0.62, 0, 13), 0.62)
        self.assertAlmostEqual(apply_platt(0.5, 0, 1), 0.5)

    def test_a_week_without_a_saved_close_is_unavailable(self):
        card = build_scorecard(
            closes=[],
            schedule=[game(24, 17)],
            model=model(),
            props=[],
            chances=[],
            previous=None,
            now=NOW,
            season=2026,
        )
        week = next(row for row in card['weeks'] if row['week'] == 10)
        self.assertEqual(week['status'], 'unavailable')
        self.assertIsNone(week['coachBrier'])
        self.assertIn('unavailable', week['sentence'])
        self.assertIn('No closing prices were saved', week['sentence'])
        self.assertIsNone(card['seasonToDate']['coachBrier'])

    def test_finished_game_scores_coach_and_the_book_on_the_same_line(self):
        closes = [
            close('spreads', 'Kansas City Chiefs', 1.91, -3.5),
            close('spreads', 'Buffalo Bills', 1.91, 3.5),
            close('totals', 'Over', 1.91, 44.5),
            close('totals', 'Under', 1.91, 44.5),
            close('h2h', 'Kansas City Chiefs', 1.50, None),
            close('h2h', 'Buffalo Bills', 2.60, None),
        ]
        card = build_scorecard(
            closes=closes,
            schedule=[game(24, 17)],
            model=model(),
            props=[],
            chances=[],
            previous=None,
            now=NOW,
            season=2026,
        )
        week = next(row for row in card['weeks'] if row['week'] == 10)
        self.assertEqual(week['status'], 'scored')
        self.assertEqual(week['picks'], 3)
        self.assertIsNotNone(week['coachBrier'])
        self.assertIsNotNone(week['bookBrier'])
        self.assertIn('lower is better', week['sentence'])
        self.assertIn('not a pick', week['sentence'])
        self.assertNotIn('unit', week['sentence'].lower())
        self.assertNotIn('bankroll', week['sentence'].lower())
        families = {row['family'] for row in card['lines']}
        self.assertEqual(families, {'spreads', 'totals', 'h2h'})
        spread = next(row for row in card['lines'] if row['family'] == 'spreads')
        self.assertEqual(spread['result'], 1)
        self.assertAlmostEqual(spread['book'], 0.5)

    def test_a_push_does_not_enter_the_score(self):
        closes = [
            close('spreads', 'Kansas City Chiefs', 1.91, -7.0),
            close('spreads', 'Buffalo Bills', 1.91, 7.0),
        ]
        card = build_scorecard(
            closes=closes,
            schedule=[game(24, 17)],
            model=model(),
            props=[],
            chances=[],
            previous=None,
            now=NOW,
            season=2026,
        )
        week = next(row for row in card['weeks'] if row['week'] == 10)
        self.assertEqual(week['picks'], 0)
        self.assertEqual(week['pushes'], 1)
        self.assertIsNone(week['coachBrier'])
        self.assertIn('pushed', week['sentence'])

    def test_closer_tally_uses_the_chance_nearer_the_result(self):
        text = sentence(
            {
                'status': 'scored',
                'picks': 2,
                'coachBrier': 0.253,
                'bookBrier': 0.251,
                'coachLogLoss': 0.700,
                'bookLogLoss': 0.696,
                'coachCloser': 0,
                'bookCloser': 2,
                'same': 0,
                'waiting': 0,
                'families': {
                    'spreads': {'status': 'unavailable'},
                    'totals': {'status': 'unavailable'},
                    'h2h': {'status': 'unavailable'},
                    'props': {'status': 'scored'},
                },
            },
            season=2026,
            week=2,
        )
        self.assertIn('the books were slightly more accurate: 0.251 vs 0.253', text)
        self.assertIn('lower is better', text)
        self.assertIn('Coach was closer on 0 and the books on 2', text)
        self.assertIn('Spreads, totals and moneylines are unavailable', text)

    def test_a_prop_without_a_served_chance_is_not_invented(self):
        card = build_scorecard(
            closes=[],
            schedule=[game(None, None, week=2)],
            model=model(),
            props=[{
                'season': 2026, 'week': 2, 'playerId': '00-1', 'metric': 'passing_yards',
                'line': 208.5, 'actual': 187, 'prior': 0.49,
            }],
            chances=[],
            previous=None,
            now=NOW,
            season=2026,
        )
        week = next(row for row in card['weeks'] if row['week'] == 2)
        self.assertEqual(week['status'], 'unavailable')
        self.assertEqual(week['reason'], 'no-chance')
        self.assertIsNone(week['coachBrier'])
        self.assertIn("Coach's chance", week['sentence'])
        self.assertEqual(card['lines'], [])

    def test_a_saved_prop_chance_is_scored_against_the_close(self):
        card = build_scorecard(
            closes=[],
            schedule=[],
            model=model(),
            props=[{
                'season': 2026, 'week': 2, 'playerId': '00-1', 'metric': 'passing_yards',
                'line': 208.5, 'actual': 187, 'prior': 0.50,
            }],
            chances=[{
                'season': 2026, 'week': 2, 'playerId': '00-1', 'metric': 'passing_yards',
                'line': 208.5, 'coach': 0.80,
            }],
            previous=None,
            now=NOW,
            season=2026,
        )
        week = next(row for row in card['weeks'] if row['week'] == 2)
        self.assertEqual(week['picks'], 1)
        self.assertEqual(week['bookCloser'], 1)
        self.assertEqual(week['coachCloser'], 0)
        self.assertAlmostEqual(week['bookBrier'], 0.25)
        self.assertAlmostEqual(week['coachBrier'], 0.64)

    def test_two_closes_for_one_prop_count_once(self):
        base = {
            'season': 2026, 'week': 2, 'playerId': '00-1', 'metric': 'passing_yards',
            'line': 208.5, 'actual': 187,
        }
        card = build_scorecard(
            closes=[],
            schedule=[],
            model=model(),
            props=[
                {**base, 'prior': 0.70, 'pinnacle': None, 'books': 4, 'stale': 0},
                {**base, 'prior': 0.50, 'pinnacle': 0.49, 'books': 2, 'stale': 0},
            ],
            chances=[{**base, 'coach': 0.80}],
            previous=None,
            now=NOW,
            season=2026,
        )
        self.assertEqual(len(card['lines']), 1)
        self.assertAlmostEqual(card['lines'][0]['book'], 0.50)
        self.assertEqual(card['seasonToDate']['picks'], 1)

    def test_a_frozen_chance_is_not_replaced(self):
        first = build_scorecard(
            closes=[
                close('h2h', 'Kansas City Chiefs', 1.50, None),
                close('h2h', 'Buffalo Bills', 2.60, None),
            ],
            schedule=[game(24, 17)],
            model=model(),
            props=[],
            chances=[],
            previous=None,
            now=NOW,
            season=2026,
        )
        stored = json.loads(json.dumps(first))
        stored['lines'][0]['coach'] = 0.42
        second = build_scorecard(
            closes=[
                close('h2h', 'Kansas City Chiefs', 1.20, None),
                close('h2h', 'Buffalo Bills', 4.0, None),
            ],
            schedule=[game(24, 17)],
            model=model(),
            props=[],
            chances=[],
            previous=stored,
            now=NOW,
            season=2026,
        )
        self.assertEqual(second['lines'][0]['coach'], 0.42)
        self.assertEqual(len(second['lines']), 1)

    def test_unfinished_saved_closes_wait_instead_of_inventing_a_result(self):
        card = build_scorecard(
            closes=[
                close('h2h', 'Kansas City Chiefs', 1.50, None),
                close('h2h', 'Buffalo Bills', 2.60, None),
            ],
            schedule=[game(None, None)],
            model=model(),
            props=[],
            chances=[],
            previous=None,
            now=NOW,
            season=2026,
        )
        week = next(row for row in card['weeks'] if row['week'] == 10)
        self.assertEqual(week['status'], 'pending')
        self.assertIsNone(week['coachBrier'])
        self.assertIn('no final result', week['sentence'])
        self.assertEqual(card['lines'], [])


if __name__ == '__main__':
    unittest.main()
