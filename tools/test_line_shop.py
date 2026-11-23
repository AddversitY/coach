import gzip
import unittest
from datetime import datetime, timezone

import line_shop as L


def obs(book, market, outcome, decimal, line=None, at='2026-11-22T10:00:00Z', player=''):
    return {
        'at': at, 'book': book, 'kickoff': '2026-11-22T18:00:00Z', 'away': 'ARI', 'home': 'KC',
        'market': market, 'outcome': outcome, 'line': line, 'decimal': decimal, 'player': player,
    }


class PriceMathTests(unittest.TestCase):
    def test_no_vig_and_value(self):
        self.assertAlmostEqual(L.no_vig(1.91, 1.91), 0.5)
        self.assertAlmostEqual(L.decimal_from_american(-110), 1 + 100 / 110)
        self.assertAlmostEqual(L.decimal_from_american(150), 2.5)
        self.assertAlmostEqual(L.expected_value(0.5, 2.1), 0.05)
        self.assertIsNone(L.no_vig(1.0, 2.0))

    def test_shift_moves_toward_the_side_the_line_helps(self):
        # A higher total makes the over less likely.
        self.assertLess(L.shift_chance(0.5, 45.5, 46.5, 'totals'), 0.5)
        # A home line of -3 moving to -2.5 makes the home cover more likely.
        self.assertGreater(L.shift_chance(0.5, -3, -2.5, 'spreads'), 0.5)
        self.assertIsNone(L.shift_chance(0.5, 40, 50, 'totals'))
        self.assertEqual(L.shift_chance(0.42, 3, 3, 'spreads'), 0.42)

    def test_gate_needs_bets_and_positive_low_end(self):
        self.assertFalse(L.gate({'n': 50, 'low': 0.05})[0])
        self.assertFalse(L.gate({'n': 500, 'low': -0.001})[0])
        self.assertTrue(L.gate({'n': 500, 'low': 0.004})[0])

    def test_summary_range_contains_mean(self):
        result = L.summarize([0.1, -0.05, 0.02, 0.0, 0.03] * 10, rounds=300)
        self.assertEqual(result['n'], 50)
        self.assertLessEqual(result['low'], result['mean'])
        self.assertGreaterEqual(result['high'], result['mean'])
        self.assertEqual(L.summarize([])['n'], 0)


class HistoryTests(unittest.TestCase):
    def history(self):
        early = '2026-11-22T10:00:00Z'
        late = '2026-11-22T17:50:00Z'
        return {'observations': [
            # Pinnacle 50/50 on KC -3 early, then KC -3.5 at 50/50 late (moved toward KC).
            obs('pinnacle', 'spreads', 'Kansas City Chiefs', 1.95, -3, early),
            obs('pinnacle', 'spreads', 'Arizona Cardinals', 1.95, 3, early),
            obs('pinnacle', 'spreads', 'Kansas City Chiefs', 1.95, -3.5, late),
            obs('pinnacle', 'spreads', 'Arizona Cardinals', 1.95, 3.5, late),
            # A soft book pays 2.05 on KC -3 early: a flag, and it beat the close.
            obs('fanduel', 'spreads', 'Kansas City Chiefs', 2.05, -3, early),
            obs('fanduel', 'spreads', 'Arizona Cardinals', 1.80, 3, early),
            # Totals: soft over at the same line but a worse price is not a flag.
            obs('pinnacle', 'totals', 'Over', 1.90, 47.5, early),
            obs('pinnacle', 'totals', 'Under', 2.00, 47.5, early),
            obs('draftkings', 'totals', 'Over', 1.87, 47.5, early),
            # Moneyline without a line.
            obs('pinnacle', 'h2h', 'Kansas City Chiefs', 1.50, None, early),
            obs('pinnacle', 'h2h', 'Arizona Cardinals', 2.80, None, early),
            obs('betmgm', 'h2h', 'Arizona Cardinals', 3.10, None, early),
        ]}

    def test_flags_only_beat_the_fair_price(self):
        flags = L._flag_rows([row for row in self.history()['observations'] if row['at'].endswith('10:00:00Z')])
        keys = {(f['book'], f['market'], f['side']) for f in flags}
        self.assertIn(('fanduel', 'spreads', 'home'), keys)
        self.assertIn(('betmgm', 'h2h', 'away'), keys)
        self.assertNotIn(('draftkings', 'totals', 'over'), keys)
        self.assertNotIn(('fanduel', 'spreads', 'away'), keys)

    def test_flags_use_newest_pinnacle_snapshot_before_kickoff(self):
        now = datetime(2026, 11, 22, 17, 55, tzinfo=timezone.utc)
        flags = L.flags_from_history(self.history(), now=now)
        # The late snapshot has no soft price, so nothing is flagged now.
        self.assertEqual(flags, [])
        after = datetime(2026, 11, 22, 19, 0, tzinfo=timezone.utc)
        self.assertEqual(L.flags_from_history(self.history(), now=after), [])

    def test_early_flag_is_scored_against_the_moved_close(self):
        scored = L.history_clv(self.history())
        spread = [row for row in scored if row['market'] == 'spreads']
        self.assertEqual(len(spread), 1)
        # Close is KC -3.5 at 50%, so KC -3 is better than 50%: positive CLV.
        self.assertGreater(spread[0]['clv'], 0.025)

    def test_report_is_not_adopted_without_enough_bets(self):
        report = L.build_report(self.history(), {}, now=datetime(2026, 11, 22, 9, tzinfo=timezone.utc))
        self.assertFalse(report['adopted'])
        self.assertEqual(report['schema'], L.SCHEMA)


class PropLineTests(unittest.TestCase):
    HEADER = (
        'event_id,commence_time,market,bookmaker,player_name,outcome_name,line,price_american,'
        'actual_value,closing_price,closing_at,closing_point,opening_price,opening_point,opening_at\n'
    )

    def row(self, book, side, open_price, close_price, open_at, line=50.5, actual=60):
        return (
            f'1,2026-09-20T17:00:00+00:00,player_reception_yds,{book},A Player,{side},{line},{close_price},'
            f'{actual},{close_price},2026-09-20T16:00:00+00:00,{line},{open_price},{line},{open_at}\n'
        )

    def test_no_look_ahead_and_scoring(self):
        text = self.HEADER
        text += self.row('pinnacle', 'Over', -110, -130, '2026-09-17T12:00:00+00:00')
        text += self.row('pinnacle', 'Under', -110, 110, '2026-09-17T12:00:00+00:00')
        # Opened after Pinnacle, pays +120 on the over: flagged; the close moved to the over.
        text += self.row('draftkings', 'Over', 120, -125, '2026-09-18T12:00:00+00:00')
        text += self.row('draftkings', 'Under', -150, 105, '2026-09-18T12:00:00+00:00')
        # Opened before Pinnacle: not scored by the open test.
        text += self.row('fanduel', 'Over', 130, -125, '2026-09-16T12:00:00+00:00')
        rows = L.load_propline(fetch=lambda url: gzip.compress(text.encode()))
        result = L.backtest_propline(rows)
        self.assertEqual(result['open']['flags'], 1)
        self.assertGreater(result['open']['clv']['mean'], 0)
        self.assertFalse(result['open']['passes'])


if __name__ == '__main__':
    unittest.main()
