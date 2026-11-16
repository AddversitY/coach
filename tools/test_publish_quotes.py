import copy
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from publish_snapshot import build_snapshot, iso
from publish_quotes import (MARKETS, Provider, cached_quotes, main, match_event,
                            normalize_quotes, player_directory, run)


NOW = datetime(2026, 11, 14, 15, tzinfo=timezone.utc)
EVENT_ID = 'a' * 32


def schedule(now=NOW):
    return build_snapshot([dict(game_id='2026_11_BUF_KC', gameday='2026-11-15', gametime='20:20',
        home_team='KC', away_team='BUF', home_score='', away_score='')], now)


def dataset():
    return {'currentSeason': 2026, 'cutoff': '2026-11-12', 'retrievedAt': iso(NOW - timedelta(hours=1)),
            'rows': [dict(playerId='00-0033873', name='Josh Allen', team='BUF', date='2026-11-08', season=2026),
                     dict(playerId='00-0033873', name='Josh Allen', team='BUF', date='2025-11-08', season=2025)]}


def provider_event():
    return dict(id=EVENT_ID, sport_key='americanfootball_nfl', home_team='Kansas City Chiefs',
                away_team='Buffalo Bills', commence_time='2026-11-16T01:20:00Z')


def response():
    return dict(**provider_event(), bookmakers=[dict(key='draftkings', title='arbitrary upstream title',
        privateRaw='DO_NOT_EXPORT', markets=[dict(key='player_pass_yds', last_update=iso(NOW - timedelta(minutes=1)),
        outcomes=[dict(name=side, description='Josh Allen', point=234.5, price=1.91) for side in ('Over', 'Under')])])])


class FakeProvider:
    def __init__(self, raw=None, remaining=100, charged=4, fail=False):
        self.raw, self.remaining, self.charged, self.fail = raw or response(), remaining, charged, fail
        self.calls = []

    def request(self, event_id=None):
        self.calls.append(event_id)
        if event_id and self.fail:
            raise ValueError('Unavailable')
        return (self.raw if event_id else [provider_event()]), {
            'x-requests-last': str(self.charged if event_id else 0),
            'x-requests-used': str(self.charged if event_id else 0),
            'x-requests-remaining': str(self.remaining - (self.charged if event_id else 0))}


class QuotePublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = Path(self.temp.name) / 'private'
        self.provider = FakeProvider()

    def tearDown(self):
        self.temp.cleanup()

    def publish(self, **kwargs):
        defaults = dict(enabled=True, key='PRIVATE_KEY', state_dir=self.state,
                        provider=self.provider, initialize_state=True)
        defaults.update(kwargs)
        return run(schedule(), dataset(), NOW, **defaults)

    def test_default_disabled_and_missing_key_preserve_v1_without_calls(self):
        for args in ({}, {'enabled': True}):
            result, _ = run(schedule(), dataset(), NOW, provider=self.provider, **args)
            self.assertEqual(result, schedule())
        self.assertEqual(self.provider.calls, [])

    def test_missing_ledger_fails_closed_without_provider_calls(self):
        result, message = self.publish(initialize_state=False)
        self.assertEqual(result['schemaVersion'], 1)
        self.assertIn('ledger', message)
        self.assertEqual(self.provider.calls, [])

    def test_pregame_window_skips_distant_games_without_provider_requests(self):
        result, message = self.publish(refresh_window=timedelta(hours=6))
        self.assertEqual(result['schemaVersion'], 1)
        self.assertIn('pregame refresh window', message)
        self.assertEqual(self.provider.calls, [])

    def test_pregame_window_allows_nearby_game_with_existing_limits(self):
        now = NOW + timedelta(hours=29)
        self.provider.raw['bookmakers'][0]['markets'][0]['last_update'] = iso(now - timedelta(minutes=1))
        result, _ = run(schedule(now), dataset(), now, enabled=True, key='PRIVATE_KEY',
                        state_dir=self.state, provider=self.provider, initialize_state=True,
                        refresh_window=timedelta(hours=6))
        self.assertEqual(result['schemaVersion'], 2)
        self.assertEqual(self.provider.calls, [None, EVENT_ID])

    def test_rolled_back_ledger_blocks_paid_request_using_provider_counter(self):
        original = self.provider.request
        def changed_usage(event_id=None):
            data, headers = original(event_id)
            headers['x-requests-used'] = '4'
            return data, headers
        self.provider.request = changed_usage
        result, message = self.publish()
        self.assertEqual(result['schemaVersion'], 1)
        self.assertIn('checkpoint', message)
        self.assertEqual(self.provider.calls, [None])

    def test_cli_enabled_without_key_writes_unchanged_schedule_successfully(self):
        root = Path(self.temp.name)
        input_path, output = root / 'input.json', root / 'public' / 'snapshot.json'
        original = build_snapshot([], datetime.now(timezone.utc))
        input_path.write_text(json.dumps(original))
        args = ['publish_quotes.py', '--schedule', str(input_path), '--output', str(output),
                '--state-dir', str(self.state)]
        with patch.object(sys, 'argv', args), patch.dict(os.environ, {'ODDS_PUBLISH_ENABLED': '1', 'THE_ODDS_API_KEY': ''}), \
                patch.object(Provider, 'request') as request, redirect_stdout(io.StringIO()) as out:
            main()
        self.assertEqual(json.loads(output.read_text()), original)
        self.assertIn('zero odds credits', out.getvalue())
        request.assert_not_called()

    def test_exact_normalization_and_public_privacy(self):
        result, _ = self.publish()
        self.assertEqual(result['schemaVersion'], 2)
        self.assertEqual(self.provider.calls, [None, EVENT_ID])
        self.assertEqual(result['board']['quotes'], [])
        self.assertEqual(result['odds']['coverage']['eventId'], 'nflverse:2026_11_BUF_KC')
        self.assertEqual(result['odds']['coverage']['markets'], list(MARKETS))
        self.assertEqual(result['odds']['coverage']['players'][0]['playerId'], '00-0033873')
        self.assertEqual(result['odds']['coverage']['outsideCoverage'], 'unavailable')
        quote = result['props']['quotes'][0]
        self.assertEqual(quote['selection']['point'], 234.5)
        self.assertEqual(quote['bookId'], 'draftkings')
        self.assertEqual(quote['book'], 'DraftKings')
        self.assertEqual(quote['selection']['rules'], 'player_prop_unverified')
        public = json.dumps(result)
        for private in ('PRIVATE_KEY', 'DO_NOT_EXPORT', 'arbitrary upstream title', 'bookmakers', 'x-requests'):
            self.assertNotIn(private, public)
        for path in self.state.glob('*.json'):
            self.assertNotIn('PRIVATE_KEY', path.read_text())
            self.assertNotIn('DO_NOT_EXPORT', path.read_text())

    def test_cache_reuse_preserves_observation_time_and_zero_calls(self):
        first, _ = self.publish()
        self.provider.calls.clear()
        now = NOW + timedelta(hours=1)
        result, _ = run(schedule(now), dataset(), now, enabled=True, key='PRIVATE_KEY',
                        state_dir=self.state, provider=self.provider)
        self.assertEqual(self.provider.calls, [])
        self.assertEqual(result['odds']['fetchedAt'], first['odds']['fetchedAt'])
        self.assertEqual(result['props']['quotes'], first['props']['quotes'])
        self.assertEqual(result['generatedAt'], iso(now))

    def test_stale_cache_and_daily_cap_do_not_refetch(self):
        self.publish()
        cache_path = self.state / 'quotes.json'
        saved = json.loads(cache_path.read_text())
        saved['fetchedAt'] = iso(NOW - timedelta(hours=19))
        cache_path.write_text(json.dumps(saved))
        self.provider.calls.clear()
        result, _ = self.publish(initialize_state=False)
        self.assertEqual(result['schemaVersion'], 1)
        self.assertEqual(self.provider.calls, [])

    def test_monthly_cap_and_fifty_credit_reserve(self):
        self.state.mkdir()
        entries = [{'at': iso(NOW - timedelta(days=1)), 'credits': 4} for _ in range(15)]
        (self.state / 'ledger.json').write_text(json.dumps({'version': 1, 'fixture': False, 'reservations': entries, 'providerUsed': 0}))
        result, _ = self.publish(initialize_state=False)
        self.assertEqual(result['schemaVersion'], 1)
        self.assertEqual(self.provider.calls, [])
        (self.state / 'ledger.json').unlink()
        self.provider.remaining = 53
        result, _ = self.publish()
        self.assertEqual(result['schemaVersion'], 1)
        self.assertEqual(self.provider.calls, [None])

    def test_failed_paid_call_is_reserved_and_never_retried(self):
        self.provider.fail = True
        with self.assertRaises(ValueError):
            self.publish()
        self.provider.calls.clear()
        result, _ = self.publish(initialize_state=False)
        self.assertEqual(result['schemaVersion'], 1)
        self.assertEqual(self.provider.calls, [])
        ledger = json.loads((self.state / 'ledger.json').read_text())
        self.assertEqual(sum(e['credits'] for e in ledger['reservations']), 4)

    def test_unexpected_provider_billing_blocks_future_publication(self):
        self.provider.charged = 5
        with self.assertRaises(ValueError):
            self.publish()
        self.assertTrue(json.loads((self.state / 'ledger.json').read_text())['blocked'])
        self.provider.calls.clear()
        with self.assertRaises(ValueError):
            self.publish(initialize_state=False)
        self.assertEqual(self.provider.calls, [])

    def test_offline_fixtures_are_explicit_and_cannot_masquerade_as_live(self):
        fixtures = Path(self.temp.name) / 'fixtures'
        fixtures.mkdir()
        for name, value in {'events.json': [provider_event()], 'odds.json': response(),
                'headers.json': {'events': {'x-requests-last': '0', 'x-requests-remaining': '100', 'x-requests-used': '0'},
                                 'odds': {'x-requests-last': '4', 'x-requests-remaining': '96', 'x-requests-used': '4'}}}.items():
            (fixtures / name).write_text(json.dumps(value))
        result, _ = run(schedule(), dataset(), NOW, enabled=True, fixture_dir=fixtures,
                        state_dir=self.state, initialize_state=True)
        self.assertEqual(result['schemaVersion'], 2)
        self.assertTrue(result['odds']['testFixture'])
        with self.assertRaises(ValueError):
            self.publish(initialize_state=False)
        self.assertEqual(self.provider.calls, [])

    def test_wrong_event_team_time_and_duplicate_mapping_fail_closed(self):
        event = schedule()['board']['events'][0]
        directory = player_directory(dataset(), event, NOW)
        for change in ({'id': 'b' * 32}, {'home_team': 'Buffalo Bills'}, {'commence_time': '2026-11-16T01:26:00Z'}):
            raw = response()
            raw.update(change)
            with self.assertRaises(ValueError):
                normalize_quotes(raw, event, provider_event(), directory, NOW)
        with self.assertRaises(ValueError):
            match_event([provider_event(), dict(provider_event(), id='b' * 32)], [event], NOW)
        with self.assertRaises(ValueError):
            match_event([provider_event()], [event, dict(event, id='nflverse:other')], NOW)

    def test_exact_name_latest_club_cutoff_and_ambiguity(self):
        event = schedule()['board']['events'][0]
        for extra in (
            dict(playerId='00-0099999', name='Josh Allen', team='KC', date='2026-11-07', season=2026),
            dict(playerId='00-0033873', name='Josh Allen', team='NYJ', date='2026-11-10', season=2026),
            dict(playerId='00-0033873', name='Josh Allen', team='KC', date='2026-11-08', season=2026),
        ):
            data = dataset()
            data['rows'].append(extra)
            self.assertNotIn('Josh Allen', player_directory(data, event, NOW))
        data = dataset()
        data['rows'].append(dict(playerId='00-0033873', name='Josh Allen', team='NYJ', date='2026-11-14', season=2026))
        self.assertIn('Josh Allen', player_directory(data, event, NOW))
        raw = response()
        raw['bookmakers'][0]['markets'][0]['outcomes'][0]['description'] = 'J. Allen'
        quotes, _ = normalize_quotes(raw, event, provider_event(), player_directory(dataset(), event, NOW), NOW)
        self.assertEqual(len(quotes), 1)

    def test_missing_future_stale_and_wrong_season_metadata_fail_before_network(self):
        changes = [dict(currentSeason=2025), dict(currentSeason=True), dict(cutoff=None),
                   dict(retrievedAt=None), dict(cutoff='2026-11-15'), dict(cutoff='2026-10-23'),
                   dict(cutoff='2026-02-30'), dict(retrievedAt=iso(NOW + timedelta(seconds=1))),
                   dict(cutoff='2026-11-12', retrievedAt='2026-11-12T01:00:00Z')]
        event = schedule()['board']['events'][0]
        for change in changes:
            data = dataset()
            data.update(change)
            with self.subTest(change=change):
                self.assertEqual(player_directory(data, event, NOW), {})
                result, _ = run(schedule(), data, NOW, enabled=True, key='PRIVATE_KEY',
                                state_dir=self.state, provider=self.provider, initialize_state=True)
                self.assertEqual(result['schemaVersion'], 1)
                self.assertEqual(self.provider.calls, [])

    def test_post_cutoff_rows_are_ignored_and_old_selected_players_are_absent(self):
        event = schedule()['board']['events'][0]
        data = dataset()
        data['rows'].append(dict(playerId='00-0033873', name='Josh Allen', team='NYJ',
                                date='2026-11-13', season=2026))
        directory = player_directory(data, event, NOW)
        self.assertEqual(directory['Josh Allen']['team'], 'Buffalo Bills')
        self.assertEqual(directory['Josh Allen']['asOf'], '2026-11-08')
        data['rows'] = [dict(playerId='00-0033873', name='Josh Allen', team='BUF',
                            date='2026-10-09', season=2026)]
        self.assertEqual(player_directory(data, event, NOW), {})

    def test_stale_future_bad_line_bad_price_and_unknown_book_rejected(self):
        event = schedule()['board']['events'][0]
        directory = player_directory(dataset(), event, NOW)
        for stamp in (NOW - timedelta(hours=19), NOW + timedelta(minutes=1)):
            raw = response()
            raw['bookmakers'][0]['markets'][0]['last_update'] = iso(stamp)
            self.assertEqual(normalize_quotes(raw, event, provider_event(), directory, NOW)[0], [])
        for field, value in (('point', 10.25), ('point', float('nan')), ('price', float('inf')), ('price', 1), ('price', True)):
            raw = response()
            for outcome in raw['bookmakers'][0]['markets'][0]['outcomes']:
                outcome[field] = value
            self.assertEqual(normalize_quotes(raw, event, provider_event(), directory, NOW)[0], [])
        raw = response()
        raw['bookmakers'][0]['key'] = 'unknown'
        self.assertEqual(normalize_quotes(raw, event, provider_event(), directory, NOW)[0], [])

    def test_cache_cannot_smuggle_raw_fields_and_fixture_state_cannot_be_live(self):
        self.publish()
        cache = json.loads((self.state / 'quotes.json').read_text())
        cache['quotes'][0]['rawResponse'] = 'DO_NOT_EXPORT'
        with self.assertRaises(ValueError):
            cached_quotes(cache, player_directory(dataset(), cache['event'], NOW), NOW)
        ledger = json.loads((self.state / 'ledger.json').read_text())
        ledger['fixture'] = True
        (self.state / 'ledger.json').write_text(json.dumps(ledger))
        self.provider.calls.clear()
        with self.assertRaises(ValueError):
            self.publish(initialize_state=False)
        self.assertEqual(self.provider.calls, [])

    def test_authentication_is_header_only_and_redirects_disabled(self):
        captured = []
        class Response:
            headers = {'x-requests-last': '0'}
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, *args): return b'[]'
        class Opener:
            def open(self, request, timeout):
                captured.append(request)
                self.timeout = timeout
                return Response()
        with patch('urllib.request.build_opener', return_value=Opener()) as opener:
            Provider('PRIVATE_KEY').request()
            Provider('PRIVATE_KEY').request(EVENT_ID)
        for request in captured:
            self.assertNotIn('PRIVATE_KEY', request.full_url)
            self.assertNotIn('apiKey', request.full_url)
            self.assertEqual(request.get_header('X-api-key'), 'PRIVATE_KEY')
        self.assertEqual(len(opener.call_args.args), 1)
        with self.assertRaises(ValueError):
            opener.call_args.args[0]().redirect_request(None, None, 302, '', {}, 'https://other.test')


if __name__ == '__main__':
    unittest.main()

class BalancedMarketTests(unittest.TestCase):
    def test_balanced_profile_keeps_exact_four_credit_budget_and_normalizes_all_core_markets(self):
        from publish_quotes import requested_markets,COST,DAILY_CAP,MONTHLY_CAP,RESERVE,normalize_quotes,cached_quotes
        markets=requested_markets('balanced',NOW)
        self.assertEqual(len(markets),4);self.assertEqual(markets[:3],('h2h','spreads','totals'))
        self.assertEqual((COST,DAILY_CAP,MONTHLY_CAP,RESERVE),(4,4,60,50))
        event=schedule()['board']['events'][0]
        raw=provider_event();raw['bookmakers']=[{'key':'draftkings','markets':[
            {'key':'h2h','last_update':iso(NOW),'outcomes':[{'name':event['home'],'price':1.8},{'name':event['away'],'price':2.1}]},
            {'key':'spreads','last_update':iso(NOW),'outcomes':[{'name':event['home'],'point':-3.5,'price':1.91},{'name':event['away'],'point':3.5,'price':1.91}]},
            {'key':'totals','last_update':iso(NOW),'outcomes':[{'name':'Over','point':45.5,'price':1.91},{'name':'Under','point':45.5,'price':1.91}]},
        ]}]
        quotes,players=normalize_quotes(raw,event,provider_event(),{},NOW,markets)
        self.assertEqual(len(quotes),6);self.assertEqual(players,[])
        self.assertEqual(cached_quotes({'event':event,'quotes':quotes,'players':players,'markets':list(markets)}, {}, NOW),quotes)
        raw['bookmakers'][0]['markets'][1]['outcomes'][0]['name']='Dallas Cowboys'
        self.assertEqual(len(normalize_quotes(raw,event,provider_event(),{},NOW,markets)[0]),5)
