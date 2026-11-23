import unittest
from datetime import datetime, timezone

import backup_watch as B

KEYS = ['attempts', 'carries', 'completions', 'passing_yards', 'receiving_yards', 'receptions', 'rushing_yards',
        'targets']
PARAMS = {
    'starterShare': {'QB': 0.7, 'RB': 0.5, 'WR': 0.7, 'TE': 0.7},
    'inheritedShare': {'WR:targets': 0.5, 'RB:carries': 0.3, 'RB:targets': 0.3, 'QB:attempts': 0.6,
                       'TE:targets': 0.3},
    'positionMeans': {'WR': {'receiving_yards/targets': 8.0, 'receptions/targets': 0.6}},
    'shrink': {'targets': 60, 'carries': 80, 'attempts': 150},
    'priorGames': 4,
    'quantiles': [0.25, 0.5, 0.75],
    'ratioQuantiles': {'WR:player_reception_yds': [0.5, 1.0, 1.5], 'WR:player_receptions': [0.5, 1.0, 1.5]},
}


def stat_row(pid, name, team, week, targets, yards=0, receptions=0):
    values = {'targets': targets, 'receiving_yards': yards, 'receptions': receptions}
    return {'playerId': pid, 'name': name, 'position': 'WR', 'team': team, 'season': 2026, 'week': week,
            'seasonType': 'REG', 'stats': [values.get(k, 0) for k in KEYS]}


def make_usage():
    rows, usage = [], []
    for week in (1, 2, 3, 4):
        rows += [stat_row('A', 'Alpha One', 'NE', week, 10, 80, 6),   # starter: 10 of 30 targets
                 stat_row('B', 'Bravo Two', 'NE', week, 3, 24, 2),    # backup: 3 of 30
                 stat_row('C', 'Other Guy', 'NE', week, 17, 120, 11)]
        usage += [['A', 2026, week, 'WR', 0.9], ['B', 2026, week, 'WR', 0.4], ['C', 2026, week, 'WR', 0.95]]
    return B.Usage({'statKeys': KEYS, 'rows': rows},
                   {'keys': ['id', 'season', 'week', 'position', 'snap'], 'rows': usage})


RATINGS = {'teams': [{'t': 'NE', 'qb': 'Somebody'}],
           'players': [{'n': 'Alpha One', 'id': 'A', 't': 'NE', 'p': 'WR', 'o': 90, 's': 500},
                       {'n': 'Bravo Two', 'id': 'B', 't': 'NE', 'p': 'WR', 'o': 60, 's': 200},
                       {'n': 'Other Guy', 'id': 'C', 't': 'NE', 'p': 'WR', 'o': 85, 's': 520}]}
STATUSES = {'NE': {'Alpha One': ('Out', '2026-11-27T15:00Z'), 'Other Guy': ('Questionable', '2026-11-27T15:00Z')}}


def obs(outcome, decimal, line=40.5, book='fanduel', market='player_reception_yds', at='2026-11-28T12:00:00Z'):
    return {'at': at, 'book': book, 'eventId': 'nflverse:2026_05_NE_LAC', 'market': market, 'outcome': outcome,
            'player': 'Bravo Two', 'playerId': 'B', 'decimal': decimal, 'line': line,
            'kickoff': '2026-11-30T18:00:00Z'}


class BackupWatchTests(unittest.TestCase):
    def test_backup_is_the_next_man_not_another_starter(self):
        usage = make_usage()
        found = B.stepping_in(RATINGS, STATUSES, usage, PARAMS)
        self.assertEqual(len(found), 1)
        team, group, starters, backup = found[0]
        self.assertEqual((team, group, backup['n']), ('NE', 'WR', 'Bravo Two'))
        self.assertEqual([s['n'] for s in starters], ['Alpha One'])

    def test_projection_inherits_part_of_the_starter_share(self):
        rows = B.projections(RATINGS, STATUSES, make_usage(), PARAMS)
        # Share 0.1 + 0.5 * 1/3 = 0.2667 of 30 targets = 8 targets.
        # Yards per target: (24*4 + 60*8) / (12 + 60) = 8.0.
        self.assertAlmostEqual(rows[0]['projection']['player_reception_yds'], 64.0, places=1)

    def test_over_chance_reads_the_fitted_spread(self):
        q = [0.5, 1.0, 1.5]
        levels = [0.25, 0.5, 0.75]
        self.assertAlmostEqual(B.over_chance(40, 40, levels, q), 0.5)
        self.assertAlmostEqual(B.over_chance(40, 30, levels, q), 0.625)
        self.assertGreater(B.over_chance(40, 10, levels, q), 0.75)
        self.assertLess(B.over_chance(40, 80, levels, q), 0.25)
        self.assertIsNone(B.over_chance(0, 10, levels, q))

    def test_first_price_is_kept_then_scored_at_the_close(self):
        usage = make_usage()
        rows = B.projections(RATINGS, STATUSES, usage, PARAMS)
        early = datetime(2026, 11, 28, 13, tzinfo=timezone.utc)
        bets = B.priced(rows, [obs('Over', 1.91), obs('Under', 1.91)], PARAMS, early)
        self.assertEqual(len(bets), 1)
        self.assertEqual(bets[0]['side'], 'over')  # Projection 64 against a 40.5 line.
        log = {'bets': []}
        self.assertEqual(B.merge(log, bets, early), 1)
        # A later, worse price is not a new sighting.
        later = B.priced(rows, [obs('Over', 1.7, line=45.5), obs('Under', 2.1, line=45.5)], PARAMS, early)
        self.assertEqual(B.merge(log, later, early), 0)
        # After kickoff the same book's last price is the close.
        close = [obs('Over', 1.8, line=40.5, at='2026-11-30T17:55:00Z'),
                 obs('Under', 2.0, line=40.5, at='2026-11-30T17:55:00Z')]
        summary = B.score(log, close, usage, datetime(2026, 11, 30, 21, tzinfo=timezone.utc))
        bet = log['bets'][0]
        self.assertGreater(bet['overClv'], 0)
        self.assertEqual(summary['projectedSideClv']['n'], 1)
        self.assertFalse(summary['passes'])

    def test_other_teams_and_started_games_are_ignored(self):
        rows = B.projections(RATINGS, STATUSES, make_usage(), PARAMS)
        late = datetime(2026, 12, 1, tzinfo=timezone.utc)
        self.assertEqual(B.priced(rows, [obs('Over', 1.91), obs('Under', 1.91)], PARAMS, late), [])
        other = dict(obs('Over', 1.91), eventId='nflverse:2026_05_KC_BUF')
        other_u = dict(obs('Under', 1.91), eventId='nflverse:2026_05_KC_BUF')
        early = datetime(2026, 11, 28, 13, tzinfo=timezone.utc)
        self.assertEqual(B.priced(rows, [other, other_u], PARAMS, early), [])


if __name__ == '__main__':
    unittest.main()
