import unittest
from datetime import datetime, timedelta, timezone

import book_lag
import edge_log
import niche_watch
import public_splits

NOW = datetime(2026, 11, 23, 12, tzinfo=timezone.utc)
KICK = '2026-11-26T18:00:00Z'


def quote(book, market, outcome, line, decimal, at='2026-11-23T10:00:00Z', player=''):
    return {'at': at, 'book': book, 'away': 'KC', 'home': 'BUF', 'kickoff': KICK, 'market': market,
            'outcome': outcome, 'line': line, 'decimal': decimal, 'player': player}


class EdgeLogTests(unittest.TestCase):
    def test_normalize_reads_worker_event_ids_and_maps_codes(self):
        rows = edge_log.normalize([{'eventId': 'nflverse:2026_12_LA_SEA', 'decimal': 1.9, 'market': 'player_rush_yds'},
                                   {'away': 'LAR', 'home': 'SF', 'decimal': 2.0}, {'away': 'A', 'home': 'B'}])
        self.assertEqual([(r['away'], r['home']) for r in rows], [('LA', 'SEA'), ('LA', 'SF')])

    def test_best_price_prefers_the_better_number_then_the_price(self):
        rows = [quote('fanduel', 'totals', 'Under', 47.5, 1.91), quote('draftkings', 'totals', 'Under', 48.5, 1.87),
                quote('pinnacle', 'totals', 'Under', 49.5, 1.95), quote('betmgm', 'totals', 'Over', 47.5, 1.95)]
        bet = edge_log.best_price(rows, 'KC', 'BUF', 'totals', 'under', now=NOW)
        self.assertEqual((bet['book'], bet['line']), ('draftkings', 48.5))
        self.assertEqual(edge_log.best_price(rows, 'KC', 'BUF', 'totals', 'over', now=NOW)['book'], 'betmgm')
        self.assertIsNone(edge_log.best_price(rows, 'KC', 'BUF', 'totals', 'under', now=NOW + timedelta(days=5)))
        old = quote('fliff', 'totals', 'Under', 50.5, 2.0, at='2026-11-19T10:00:00Z')
        self.assertEqual(edge_log.best_price(rows + [old], 'KC', 'BUF', 'totals', 'under', now=NOW)['book'], 'draftkings')

    def test_merge_keeps_the_first_sighting(self):
        log = {'alerts': []}
        first = {'away': 'KC', 'home': 'BUF', 'kickoff': KICK, 'angle': 'x', 'bet': {'decimal': 2.0}}
        self.assertEqual(edge_log.merge(log, [first], ('away', 'home', 'kickoff', 'angle')), 1)
        later = {**first, 'bet': {'decimal': 1.5}}
        self.assertEqual(edge_log.merge(log, [later], ('away', 'home', 'kickoff', 'angle')), 0)
        self.assertEqual(log['alerts'][0]['bet']['decimal'], 2.0)

    def test_score_uses_the_book_consensus_when_pinnacle_has_no_close(self):
        rows = [quote('fanduel', 'player_rush_yds', 'Over', 60.5, 1.8, at='2026-11-26T17:00:00Z', player='A'),
                quote('fanduel', 'player_rush_yds', 'Under', 60.5, 2.0, at='2026-11-26T17:00:00Z', player='A')]
        log = {'alerts': [{'away': 'KC', 'home': 'BUF', 'kickoff': KICK, 'angle': 'a',
                           'bet': {'market': 'player_rush_yds', 'side': 'over', 'line': 60.5, 'decimal': 2.1,
                                   'player': 'A'}}]}
        summary = edge_log.score(log, rows, now=datetime(2026, 11, 27, tzinfo=timezone.utc))
        self.assertEqual(log['alerts'][0]['clvReference'], 'book consensus')
        self.assertGreater(log['alerts'][0]['clv'], 0)
        self.assertEqual(summary['clv']['n'], 1)
        self.assertFalse(summary['passes'])


class PublicSplitsTests(unittest.TestCase):
    def payload(self, home_bets, home_money):
        return {'data': [{'scheduled': '2026-11-26T18:00:00+00:00',
                          'competitors': {'home': {'abbreviation': 'BUF'}, 'away': {'abbreviation': 'KC'}},
                          'bettingSplits': {'spread': {'home': {'betsPercentage': home_bets, 'stakePercentage': home_money},
                                                       'away': {'betsPercentage': 100 - home_bets,
                                                                'stakePercentage': 100 - home_money}}}}]}

    def test_fade_and_follow_the_money(self):
        found = public_splits.signals(self.payload(75, 60), NOW)
        self.assertIn(('KC', 'BUF', datetime(2026, 11, 26, 18, tzinfo=timezone.utc), 'fade the public (spread)',
                       'spreads', 'away', '70-80%'), found)
        self.assertTrue(any(s[3] == 'follow the money (spread)' and s[5] == 'away' for s in found))
        self.assertEqual(public_splits.signals(self.payload(55, 52), NOW), [])

    def test_build_never_stores_raw_percentages(self):
        rows = [quote('fanduel', 'spreads', 'Kansas City Chiefs', 2.5, 1.91)]
        current = public_splits.build(self.payload(75, 75), rows, NOW)
        self.assertTrue(current)
        self.assertNotIn('75', str({k: v for k, v in current[0].items() if k not in ('bet', 'kickoff', 'checkedAt')}))


class BookLagTests(unittest.TestCase):
    def test_stale_book_is_logged_on_the_side_its_number_favors(self):
        t0, t1 = '2026-11-23T08:00:00Z', '2026-11-23T10:00:00Z'
        rows = []
        for book in ('fanduel', 'draftkings', 'betmgm'):
            rows += [quote(book, 'totals', 'Over', 47.5, 1.91, at=t0), quote(book, 'totals', 'Under', 47.5, 1.91, at=t0)]
        for book in ('fanduel', 'draftkings'):
            rows += [quote(book, 'totals', 'Over', 49.5, 1.91, at=t1), quote(book, 'totals', 'Under', 49.5, 1.91, at=t1)]
        rows += [quote('betmgm', 'totals', 'Over', 47.5, 1.91, at=t1), quote('betmgm', 'totals', 'Under', 47.5, 1.91, at=t1)]
        stale = book_lag.stale_now(rows, NOW)
        self.assertEqual([(s['staleBook'], s['bet']['side'], s['bet']['line']) for s in stale], [('betmgm', 'over', 47.5)])
        lags = {(r['book'], r['market']): r for r in book_lag.lags(rows)}
        self.assertEqual(lags[('betmgm', 'totals')]['neverMatched'], 1)


class NicheWatchTests(unittest.TestCase):
    def game(self, **extra):
        base = {'game_id': 'g', 'season': '2026', 'game_type': 'REG', 'week': '13', 'gameday': '2026-11-26',
                'gametime': '13:00', 'weekday': 'Thursday', 'away_team': 'KC', 'home_team': 'DEN', 'location': 'Home',
                'roof': 'outdoors', 'surface': 'grass', 'home_rest': '4', 'away_rest': '4', 'home_qb_id': 'q1',
                'away_qb_id': 'q2', 'home_coach': 'c1', 'away_coach': 'c2', 'result': ''}
        base.update(extra)
        return base

    def test_game_angles(self):
        from collections import defaultdict
        qb = defaultdict(lambda: defaultdict(int))
        qb['q2']['DEN'] = 10
        coach = defaultdict(lambda: defaultdict(int))
        angles = niche_watch.game_angles(self.game(), {}, qb, coach, {'KC': True}, {'tempF': 20})
        names = {a[0]: a[2] for a in angles}
        self.assertEqual(names['venue: Denver altitude, Denver side'], 'home')
        self.assertEqual(names['short week: Thanksgiving, under'], 'under')
        self.assertEqual(names['revenge: quarterback against his former team, his side'], 'away')
        self.assertIn('venue: freezing (32F or colder), under', names)
        self.assertIn('venue: dome team outdoors in the cold, home side', names)

    def test_late_season_angles(self):
        from collections import defaultdict
        table = {'DEN': (13, 3, 0, 1, 17), 'KC': (5, 11, 0, 1, 17)}
        empty = defaultdict(lambda: defaultdict(int))
        names = {a[0]: a[2] for a in niche_watch.game_angles(self.game(weekday='Sunday', gameday='2027-01-03'),
                                                             table, empty, empty, {}, None)}
        self.assertEqual(names['late season: team out of the race (approx.), its side'], 'away')
        self.assertEqual(names['late season: final week, team that may rest starters, its side'], 'home')

    def test_side_to_log_follows_the_backtest(self):
        clv = lambda m: {'clv': {'mean': m}}
        research = {'angles': {'a': {'named side': {'find': clv(-0.05), 'check': clv(-0.06)},
                                     'other side': {'find': clv(0.01), 'check': clv(0.02)}}}}
        self.assertEqual(niche_watch.side_to_log(research, 'a', 'home'), 'away')
        self.assertEqual(niche_watch.side_to_log(research, 'missing', 'under'), 'under')

    def test_kickoff_is_eastern_time(self):
        self.assertEqual(niche_watch.kickoff_of(self.game()), datetime(2026, 11, 26, 18, tzinfo=timezone.utc))


if __name__ == '__main__':
    unittest.main()
