import json
import tempfile
import unittest
import home_collector
from argparse import Namespace
from datetime import datetime, timezone

from home_collector import (
    attach_identity, decimal_price, due_games, due_slots, merge_store, parse_draftkings, run,
)

NOW = datetime(2026, 11, 22, 22, 50, tzinfo=timezone.utc)  # 2.5 hours before the SNF kickoff

# Trimmed from DraftKings' logged-out feed on Nov 22, 2026 (home connection).
DK = {
    'events': [{
        'id': '34118073', 'name': 'MIN Vikings @ SF 49ers', 'startEventDate': '2026-11-23T01:20:00.0000000Z',
        'status': 'NOT_STARTED',
        'participants': [
            {'id': '18465', 'name': 'SF 49ers', 'venueRole': 'Home', 'metadata': {'shortName': 'SF'}},
            {'id': '18409', 'name': 'MIN Vikings', 'venueRole': 'Away', 'metadata': {'shortName': 'MIN'}},
        ],
    }],
    'markets': [
        {'id': '389656322', 'eventId': '34118073', 'name': 'Brock Purdy Passing Yards O/U', 'subcategoryId': 9524,
         'marketType': {'id': '13552', 'name': 'Passing Yards O/U'}},
        {'id': '389658654', 'eventId': '34118073', 'name': 'Anytime TD Scorer', 'subcategoryId': 12438,
         'marketType': {'id': '11019', 'name': 'Anytime Touchdown Scorer'}},
        {'id': '1', 'eventId': '34118073', 'name': 'First TD Scorer', 'marketType': {'name': 'First Touchdown Scorer'}},
    ],
    'selections': [
        {'marketId': '389656322', 'label': 'Over', 'outcomeType': 'Over', 'points': 241.5,
         'displayOdds': {'american': '−112', 'decimal': '1.89'}, 'trueOdds': 1.89285715,
         'participants': [{'id': '641156', 'name': 'Brock Purdy', 'type': 'Player', 'venueRole': 'HomePlayer'}]},
        {'marketId': '389656322', 'label': 'Under', 'outcomeType': 'Under', 'points': 241.5,
         'displayOdds': {'american': '−112', 'decimal': '1.89'}, 'trueOdds': 1.89285715,
         'participants': [{'id': '641156', 'name': 'Brock Purdy', 'type': 'Player', 'venueRole': 'HomePlayer'}]},
        {'marketId': '389658654', 'label': 'Christian McCaffrey', 'outcomeType': 'Anytime Scorer',
         'displayOdds': {'american': '−160', 'decimal': '1.62'}, 'trueOdds': 1.625,
         'participants': [{'id': '20415', 'name': 'Christian McCaffrey', 'type': 'Player', 'venueRole': 'HomePlayer'}]},
        {'marketId': '389658654', 'label': 'Justin Jefferson', 'outcomeType': 'Anytime Scorer',
         'displayOdds': {'american': '+140', 'decimal': '2.40'}, 'trueOdds': 2.4,
         'participants': [{'id': '485454', 'name': 'Justin Jefferson', 'venueRole': 'AwayPlayer'}]},
        {'marketId': '1', 'label': 'Justin Jefferson', 'outcomeType': 'First Scorer', 'trueOdds': 8.0,
         'participants': [{'name': 'Justin Jefferson'}]},
    ],
}
INDEX = {
    'events': [{'id': 'nflverse:2026_12_MIN_SF', 'awayCode': 'MIN', 'homeCode': 'SF', 'startsAt': '2026-11-23T01:20:00Z'}],
    'players': [
        {'id': '00-0037834', 'name': 'Brock Purdy', 'team': 'SF'},
        {'id': '00-0033280', 'name': 'Christian McCaffrey', 'team': 'SF'},
        {'id': '00-0036322', 'name': 'Justin Jefferson', 'team': 'MIN'},
    ],
}


class HomeCollectorTests(unittest.TestCase):
    def test_parses_over_under_and_anytime_touchdown(self):
        rows = parse_draftkings(DK, NOW)
        by = {(r['market'], r['player'], r['outcome']): r for r in rows}
        self.assertEqual(len(rows), 4)  # first TD is left out
        over = by[('player_pass_yds', 'Brock Purdy', 'Over')]
        self.assertEqual((over['line'], over['decimal'], over['away'], over['home']), (241.5, 1.892857, 'MIN', 'SF'))
        self.assertEqual(over['kickoff'], '2026-11-23T01:20:00Z')
        td = by[('player_anytime_td', 'Justin Jefferson', 'Yes')]
        self.assertEqual((td['line'], td['decimal']), (0.5, 2.4))

    def test_american_odds_with_unicode_minus(self):
        self.assertEqual(decimal_price({'displayOdds': {'american': '−125'}}), 1.8)
        self.assertEqual(decimal_price({'displayOdds': {'american': '+150'}}), 2.5)
        self.assertIsNone(decimal_price({'displayOdds': {}}))

    def test_started_games_and_one_sided_lines_are_skipped(self):
        started = json.loads(json.dumps(DK))
        started['events'][0]['status'] = 'STARTED'
        self.assertEqual(parse_draftkings(started, NOW), [])
        lonely = json.loads(json.dumps(DK))
        lonely['selections'] = lonely['selections'][:1]
        self.assertEqual(parse_draftkings(lonely, NOW), [])

    def test_identity_uses_coach_schedule_and_player_ids(self):
        rows = attach_identity(parse_draftkings(DK, NOW), INDEX)
        self.assertTrue(all(r['eventId'] == 'nflverse:2026_12_MIN_SF' for r in rows))
        self.assertEqual({r['playerId'] for r in rows}, {'00-0037834', '00-0033280', '00-0036322'})
        self.assertNotIn('away', rows[0])

    def test_windows_match_the_worker(self):
        self.assertEqual(due_slots(180, set()), ['T-3h'])
        self.assertEqual(due_slots(180, {'T-3h'}), [])
        self.assertEqual(due_slots(120, set()), ['T-3h'])  # missed 3h window is caught up
        self.assertEqual(due_slots(600, set()), ['T-24h'])  # a missed day-before window is caught up
        self.assertEqual(due_slots(2000, set()), [])
        self.assertEqual(due_games(INDEX, {}, NOW), {'nflverse:2026_12_MIN_SF': ['T-3h']})

    def test_merge_keeps_other_books_and_replaces_same_side(self):
        old = {'book': 'draftkings', 'eventId': 'e', 'market': 'm', 'player': 'p', 'outcome': 'Over', 'decimal': 2.0, 'at': '2026-11-22T20:00:00Z', 'kickoff': '2026-11-23T01:20:00Z'}
        other = {**old, 'book': 'fanduel'}
        stale = {**old, 'book': 'bovada', 'kickoff': '2026-11-20T18:00:00Z'}
        new = {**old, 'decimal': 1.9, 'at': '2026-11-22T22:50:00Z'}
        merged = merge_store({'observations': [old, other, stale]}, [new], NOW)['observations']
        self.assertEqual(sorted((r['book'], r['decimal']) for r in merged), [('draftkings', 1.9), ('fanduel', 2.0)])

    def test_run_merges_into_the_worker_store_and_marks_the_window(self):
        calls = []
        store = {'observations': [{'book': 'fanduel', 'eventId': 'nflverse:2026_12_MIN_SF', 'market': 'player_pass_yds', 'player': 'Brock Purdy', 'outcome': 'Over', 'decimal': 1.9, 'at': '2026-11-22T22:00:00Z', 'kickoff': '2026-11-23T01:20:00Z'}]}

        def fetch(url, data=None, headers=None):
            calls.append((url, data, headers))
            if 'coach-index' in url:
                return 200, INDEX
            if 'draftkings' in url:
                return 200, DK
            if data is None:
                return 200, store
            return 200, {'accepted': True}

        import os
        os.environ['BOOK_PROPS_INGEST_SECRET'] = 'test-secret'
        try:
            with tempfile.TemporaryDirectory() as folder:
                args = Namespace(folder=folder, dry_run=False, force=False)
                line = run(args, fetch=fetch, pause=lambda _s: None, now=NOW)
                self.assertIn('4 prices for 1 games', line)
                self.assertIn('pushed (HTTP 200)', line)
                posted = json.loads(calls[-1][1])
                self.assertEqual({r['book'] for r in posted['observations']}, {'draftkings', 'fanduel'})
                self.assertEqual(calls[-1][2]['Authorization'], 'Bearer test-secret')
                self.assertEqual(sum('draftkings' in c[0] for c in calls), 7)
                calls.clear()
                again = run(args, fetch=fetch, pause=lambda _s: None, now=NOW)
                self.assertIn('No pre-kickoff window open', again)
                self.assertFalse(any('draftkings' in c[0] for c in calls))
        finally:
            del os.environ['BOOK_PROPS_INGEST_SECRET']

    def test_no_window_means_no_book_requests(self):
        calls = []

        def fetch(url, data=None, headers=None):
            calls.append(url)
            return (200, INDEX) if 'coach-index' in url else (200, DK)

        with tempfile.TemporaryDirectory() as folder:
            later = datetime(2026, 11, 21, 12, 0, tzinfo=timezone.utc)  # 37 hours out
            run(Namespace(folder=folder, dry_run=False, force=False), fetch=fetch, pause=lambda _s: None, now=later)
        self.assertEqual(calls, ['https://addversity.github.io/coach/data/coach-index.json'])


if __name__ == '__main__':
    unittest.main()


class PushMergeTests(unittest.TestCase):
    def test_action_push_keeps_prices_from_other_collectors(self):
        import io
        from unittest import mock
        import book_props
        kept = {'book': 'draftkings', 'eventId': 'nflverse:x', 'market': 'player_pass_yds', 'player': 'A', 'outcome': 'Over', 'decimal': 1.9, 'at': '2099-01-01T00:00:00Z', 'kickoff': '2099-01-02T00:00:00Z'}
        mine = {**kept, 'book': 'bovada', 'market': 'player_rush_yds'}
        sent = []

        class Response(io.BytesIO):
            status = 200
            def __enter__(self): return self
            def __exit__(self, *a): return False

        def urlopen(request, timeout=0):
            if request.data is None:
                return Response(json.dumps({'observations': [kept]}).encode())
            sent.append(json.loads(request.data))
            return Response(b'{}')

        with mock.patch('book_props.latest_snapshot', return_value={'schema': 'coach-book-prices-v1', 'observations': [mine]}), \
             mock.patch('urllib.request.urlopen', urlopen):
            self.assertTrue(book_props.push_latest({}, 'https://w.example', 's', None))
        self.assertEqual({r['book'] for r in sent[0]['observations']}, {'draftkings', 'bovada'})


class BetMgmParseTests(unittest.TestCase):
    def fixture(self):
        def market(name, happening, value, options, sub=None, participant='1'):
            params = [{'key': 'DecimalValue', 'value': value}, {'key': 'FixtureParticipant', 'value': participant},
                      {'key': 'Happening', 'value': happening}, {'key': 'Period', 'value': 'FullTime'}]
            if sub:
                params.append({'key': 'MarketSubType', 'value': sub})
            return {'name': {'value': name}, 'status': 'Visible', 'parameters': params, 'options': options}

        def option(label, side, odds):
            return {'name': {'value': label}, 'price': {'odds': odds}, 'parameters': {'optionTypes': [side]}}
        return {'fixtures': [{
            'id': '6:1', 'stage': 'PreMatch', 'startDate': '2026-11-29T18:00:00Z',
            'name': {'value': 'Tennessee Titans @ Jacksonville Jaguars'},
            'participants': [{'id': 1, 'name': {'value': 'Trevor Lawrence'}}],
            'optionMarkets': [
                market('Trevor Lawrence - Passing Yards', 'PassingYards', '258.5', [option('Over 258.5', 'Over', 1.95), option('Under 258.5', 'Under', 1.8)]),
                market('Trevor Lawrence to throw 300+ passing yards', 'PassingYards', '300', [option('Yes', 'Over', 9)], sub='YesNo'),
                market('Trevor Lawrence to score 1+ TDs', 'Touchdown', '0.5', [option('Yes', 'Over', 6.5)], sub='PlayerTD'),
                market('Trevor Lawrence to score 2+ TDs', 'Touchdown', '1.5', [option('Yes', 'Over', 30)], sub='PlayerTD'),
            ]}]}

    def test_main_lines_and_anytime_td_only(self):
        rows = home_collector.parse_betmgm(self.fixture(), datetime(2026, 11, 28, tzinfo=timezone.utc))
        got = sorted((r['market'], r['outcome'], r['line'], r['decimal']) for r in rows)
        self.assertEqual(got, [('player_anytime_td', 'Yes', 0.5, 6.5), ('player_pass_yds', 'Over', 258.5, 1.95), ('player_pass_yds', 'Under', 258.5, 1.8)])
        self.assertEqual({(r['away'], r['home'], r['book']) for r in rows}, {('TEN', 'JAX', 'betmgm')})
