import json
import unittest

from price_history import (
    REAL_CLOSE_GATE,
    add_observations,
    build_grade,
    decimal_from_american,
    empty_history,
    ingest_snapshot,
    median_or_close,
    parse_betmgm,
    parse_draftkings,
    parse_fanduel,
    parse_pinnacle,
    record_card,
    record_source,
    scrape_public_books,
)


class PriceHistoryTests(unittest.TestCase):
    def test_american_prices_convert_and_zero_is_rejected(self):
        self.assertEqual(decimal_from_american(-110), 1.909091)
        self.assertEqual(decimal_from_american(150), 2.5)
        self.assertIsNone(decimal_from_american(0))
        self.assertIsNone(decimal_from_american('nope'))

    def test_close_is_the_last_price_before_kickoff(self):
        history = empty_history()
        added = add_observations(history, [
            self.row('2026-11-22T12:00:00Z', 1.91, line=-3.5),
            self.row('2026-11-22T17:00:00Z', 1.87, line=-3.0),
            self.row('2026-11-22T18:30:00Z', 1.50, line=-1.0),
        ])
        self.assertEqual(added, 3)
        self.assertEqual(len(history['closes']), 1)
        self.assertEqual(history['closes'][0]['decimal'], 1.87)
        self.assertEqual(history['closes'][0]['line'], -3.0)
        self.assertEqual(add_observations(history, [self.row('2026-11-22T17:00:00Z', 1.87, line=-3.0)]), 0)

    def test_missing_kickoff_has_no_close(self):
        history = empty_history()
        add_observations(history, [self.row('2026-11-22T12:00:00Z', 1.91, kickoff=None)])
        self.assertEqual(history['closes'], [])

    def test_walk_forward_keeps_the_median_until_the_gate(self):
        self.assertEqual(median_or_close(64.5, 71.5, REAL_CLOSE_GATE - 1), 64.5)
        self.assertEqual(median_or_close(64.5, None, REAL_CLOSE_GATE), 64.5)
        self.assertEqual(median_or_close(64.5, 71.5, REAL_CLOSE_GATE), 71.5)

    def test_published_snapshot_is_stored_without_demo_rows(self):
        history = empty_history()
        added = ingest_snapshot(history, {
            'generatedAt': '2026-11-20T12:00:00Z',
            'board': {'events': [{
                'id': 'nflverse:2026_12_GB_LA',
                'away': 'Green Bay Packers',
                'home': 'Los Angeles Rams',
                'startsAt': '2026-11-23T01:20:00Z',
            }], 'quotes': []},
            'props': {'quotes': [
                {
                    'selection': {
                        'eventId': 'nflverse:2026_12_GB_LA',
                        'market': 'player_reception_yds',
                        'outcome': 'Over',
                        'participant': 'Puka Nacua',
                        'point': 76.5,
                    },
                    'bookId': 'draftkings',
                    'provider': 'the-odds-api',
                    'decimal': 1.87,
                    'collectedAt': '2026-11-20T12:00:00Z',
                    'status': 'open',
                    'demo': False,
                },
                {
                    'selection': {'eventId': 'nflverse:2026_12_GB_LA', 'market': 'h2h', 'outcome': 'Los Angeles Rams', 'point': None},
                    'bookId': 'sample', 'decimal': 1.5, 'collectedAt': '2026-11-20T12:00:00Z', 'demo': True,
                },
            ]},
        })
        self.assertEqual(added, 1)
        saved = history['observations'][0]
        self.assertEqual(saved['player'], 'Puka Nacua')
        self.assertEqual(saved['away'], 'GB')
        self.assertEqual(saved['home'], 'LAR')
        self.assertEqual(saved['line'], 76.5)
        self.assertEqual(history['closes'][0]['market'], 'player_reception_yds')

    def test_grade_needs_a_chance_and_a_later_close(self):
        history = empty_history()
        add_observations(history, [
            self.row('2026-11-22T12:00:00Z', 1.91, market='player_reception_yds', outcome='Over', player='Nico Collins', line=74.5),
            self.row('2026-11-22T17:00:00Z', 1.80, market='player_reception_yds', outcome='Over', player='Nico Collins', line=74.5),
        ])
        self.assertTrue(record_card(history, {
            'at': '2026-11-22T12:00:00Z',
            'eventId': 'nflverse:2026_11_IND_HOU',
            'market': 'player_reception_yds',
            'player': 'Nico Collins',
            'side': 'over',
            'outcome': 'Over',
            'line': 74.5,
            'decimal': 1.91,
            'book': 'draftkings',
            'chance': 0.54,
        }))
        self.assertFalse(record_card(history, {'at': '2026-11-22T12:00:00Z', 'chance': 2}))
        grade = build_grade(history, {('nflverse:2026_11_IND_HOU', 'player_reception_yds', 'Nico Collins', 'over'): 'hit'})
        market = grade['markets']['player_reception_yds']
        self.assertEqual(market['graded'], 1)
        self.assertEqual(market['hits'], 1)
        self.assertEqual(market['clvCount'], 1)
        self.assertAlmostEqual(market['clvSum'], (1 / 1.91) - (1 / 1.80), places=6)
        empty = build_grade(empty_history())
        self.assertEqual(empty['markets']['player_reception_yds']['graded'], 0)

    def test_scraper_records_unavailable_and_drops_secrets(self):
        secret = 'super-secret-value'
        calls = []

        def fetch(url, headers):
            calls.append(url)
            body = json.dumps({'apiKey': secret, 'detail': 'blocked'})
            return type('R', (), {'status': 403, 'body': body})()

        history = empty_history()
        scrape_public_books(history, fetch=fetch, pause=lambda seconds: None)
        text = json.dumps(history)
        self.assertNotIn(secret, text)
        self.assertTrue(all(row['status'] == 'unavailable' for row in history['sources']))
        self.assertEqual(history['observations'], [])
        self.assertGreaterEqual(len(calls), 4)

    def test_source_status_is_not_rewritten_when_nothing_changed(self):
        history = empty_history()
        self.assertTrue(record_source(history, 'draftkings-public', 'unavailable', 'HTTP 403'))
        self.assertFalse(record_source(history, 'draftkings-public', 'unavailable', 'HTTP 403'))

    def test_public_payloads_parse_without_inventing_a_price(self):
        draftkings = parse_draftkings({
            'eventGroup': {
                'events': [{
                    'eventId': 10,
                    'teamName1': 'Indianapolis Colts',
                    'teamName2': 'Houston Texans',
                    'startDate': '2026-11-22T18:00:00Z',
                }],
                'offerCategories': [{
                    'name': 'Receiving Props',
                    'offerSubcategoryDescriptors': [{
                        'offerSubcategory': {
                            'offers': [[{
                                'eventId': 10,
                                'label': 'Nico Collins Receiving Yards',
                                'outcomes': [
                                    {'label': 'Over', 'oddsAmerican': '-115', 'line': 74.5},
                                    {'label': 'Under', 'oddsAmerican': '-105', 'line': 74.5},
                                    {'label': 'Over', 'oddsAmerican': 0, 'line': 80.5},
                                ],
                            }]],
                        },
                    }],
                }],
            },
        })
        self.assertEqual(len(draftkings), 2)
        self.assertEqual(draftkings[0]['market'], 'player_reception_yds')
        self.assertEqual(draftkings[0]['home'], 'HOU')
        self.assertEqual(draftkings[0]['player'], 'Nico Collins Receiving Yards')

        fanduel = parse_fanduel({
            'attachments': {
                'events': {'9': {'name': 'Indianapolis Colts @ Houston Texans', 'openDate': '2026-11-22T18:00:00Z'}},
                'markets': {'1': {
                    'eventId': '9',
                    'marketName': 'Total Points',
                    'runners': [{
                        'runnerName': 'Over',
                        'handicap': 44.5,
                        'winRunnerOdds': {'trueOdds': {'decimalOdds': {'decimalOdds': 1.91}}},
                    }],
                }},
            },
        })
        self.assertEqual(fanduel[0]['market'], 'totals')
        self.assertEqual(fanduel[0]['decimal'], 1.91)

        betmgm = parse_betmgm({'fixtures': [{
            'id': 'g',
            'startDate': '2026-11-22T18:00:00Z',
            'games': [{'name': 'Moneyline', 'results': [{'name': 'Houston Texans', 'americanOdds': -180}]}],
        }]})
        self.assertEqual(betmgm[0]['market'], 'h2h')
        self.assertGreater(betmgm[0]['decimal'], 1)

        pinnacle = parse_pinnacle(
            [{'id': 3, 'startTime': '2026-11-22T18:00:00Z'}],
            [{'matchupId': 3, 'type': 'spread', 'prices': [{'designation': 'home', 'price': 1.95, 'points': -3.5}, {'designation': 'away', 'price': 0}]}],
        )
        self.assertEqual(len(pinnacle), 1)
        self.assertEqual(pinnacle[0]['line'], -3.5)
        self.assertEqual(parse_draftkings({'nope': True}), [])

    def row(self, at, decimal, line=-3.5, kickoff='2026-11-22T18:00:00Z', market='spreads', outcome='Houston Texans', player=''):
        return {
            'at': at,
            'source': 'the-odds-api',
            'book': 'draftkings',
            'eventId': 'nflverse:2026_11_IND_HOU',
            'kickoff': kickoff,
            'market': market,
            'outcome': outcome,
            'player': player,
            'line': line,
            'decimal': decimal,
            'status': 'open',
        }


if __name__ == '__main__':
    unittest.main()
