import copy
import unittest

from forecast_lab import block_interval, compare, prepare, select_spec, walk_forward


class ForecastLabTests(unittest.TestCase):
    def test_later_outcomes_cannot_change_selection(self):
        earlier = [dict(season=2024, squaredError=3.) for _ in range(110)]
        development = [({'ridge': 2., 'halfLifeDays': 90.}, earlier),
                       ({'ridge': 8., 'halfLifeDays': 180.}, [dict(r, squaredError=4.) for r in earlier])]
        chosen, _ = select_spec(development)
        contaminated = [(s, r+[dict(season=2026, squaredError=999999. if i == 0 else 0.)]*900)
                        for i, (s, r) in enumerate(development)]
        self.assertEqual(chosen, select_spec(contaminated)[0])

    def test_missing_closing_pairs_are_not_filled_with_a_fake_market(self):
        c = dict(id='a', season=2025, week=1, markets={'moneyline': dict(p=.6, baseline=.5, y=1)})
        report = compare([c], [c])
        self.assertEqual(report['moneyline']['games'], 1)
        self.assertNotIn('spreads', report)
        self.assertIsNone(report['moneyline']['marketDifference95'])
        self.assertAlmostEqual(report['moneyline']['brier'], .16)
        self.assertAlmostEqual(report['moneyline']['marketBrier'], .25)

    def test_block_intervals_preserve_paired_differences(self):
        rows = [dict(season=2025, week=w, difference=-.02) for w in range(1, 18) for _ in range(10)]
        for bound in block_interval(rows, 'difference', repetitions=50):
            self.assertAlmostEqual(bound, -.02)

    def test_same_week_and_future_labels_cannot_change_a_forecast(self):
        from datetime import date, timedelta
        rows = []
        day = date(2022, 9, 1)
        for week in range(1, 50):
            for i in range(16):
                rows.append(dict(id=f'{week}-{i}', season=2022 if week < 20 else 2023 if week < 40 else 2024,
                                 week=week, date=str(day+timedelta(days=7*week)),
                                 home='BUF', away='KC', homeScore=24+i%7, awayScore=20+i%5,
                                 neutral=False, closing={'home_moneyline': '-110', 'away_moneyline': '-110'}))
        spec = {'ridge': 8., 'halfLifeDays': 180.}
        first = walk_forward(rows, spec)
        changed = copy.deepcopy(rows)
        target = first[-32]
        for row in changed:
            if row['week'] >= target['week']:
                row['homeScore'], row['awayScore'] = 0, 70
        second = {r['id']: r for r in walk_forward(changed, spec)}
        # Actual labels and scoring errors change; the emitted probability does not.
        self.assertEqual(target['markets']['moneyline']['p'], second[target['id']]['markets']['moneyline']['p'])

    def test_future_source_results_are_excluded(self):
        game = dict(id='x', date='2026-11-20', season=2026, week=11, home='BUF', away='KC', homeScore=30, awayScore=10)
        self.assertEqual(prepare({'cutoff': '2026-11-16', 'games': [game]}, []), [])


if __name__ == '__main__':
    unittest.main()
