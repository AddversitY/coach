import json
import unittest
from datetime import datetime, timezone

from book_props import (
    attach_identity,
    build_roster,
    consensus_adoption,
    coverage_document,
    match_player,
    parse_bovada,
    parse_fanduel_page,
    parse_kambi_event,
    select_main_lines,
    load_schedule_text,
)
from price_history import add_observations, empty_history, scrape_public_books


NOW = datetime(2026, 11, 21, 22, 0, tzinfo=timezone.utc)


class BookPropTests(unittest.TestCase):
    def test_kambi_main_line_is_scaled_and_the_even_price_wins(self):
        rows = parse_kambi_event({
            'events': [{
                'id': 7,
                'start': '2026-11-22T18:00:00Z',
                'awayName': 'IND Colts',
                'homeName': 'HOU Texans',
            }],
            'betOffers': [{
                'eventId': 7,
                'criterion': {'englishLabel': 'Total Passing Yards by the Player - Including Overtime'},
                'outcomes': [
                    {'englishLabel': 'Over', 'participant': 'C. J. Stroud', 'odds': 1400, 'line': 199500, 'status': 'OPEN'},
                    {'englishLabel': 'Under', 'participant': 'C. J. Stroud', 'odds': 2700, 'line': 199500, 'status': 'OPEN'},
                    {'englishLabel': 'Over', 'participant': 'C. J. Stroud', 'odds': 1910, 'line': 242500, 'status': 'OPEN'},
                    {'englishLabel': 'Under', 'participant': 'C. J. Stroud', 'odds': 1910, 'line': 242500, 'status': 'OPEN'},
                    {'englishLabel': 'Over', 'participant': 'C. J. Stroud', 'odds': 0, 'line': 300500, 'status': 'OPEN'},
                ],
            }],
        }, NOW)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]['line'], 242.5)
        self.assertEqual(rows[0]['decimal'], 1.91)
        self.assertEqual(rows[0]['market'], 'player_pass_yds')
        self.assertEqual({row['outcome'] for row in rows}, {'Over', 'Under'})

    def test_bovada_and_fanduel_keep_posted_props_only(self):
        bovada = parse_bovada([{
            'events': [{
                'id': '1',
                'type': 'GAMEEVENT',
                'description': 'Indianapolis Colts @ Houston Texans',
                'startTime': 1795370400000,
                'displayGroups': [{'markets': [{
                    'descriptionKey': 'Total Receptions O/U - Nico Collins',
                    'status': 'O',
                    'period': {'description': 'Game'},
                    'outcomes': [
                        {'description': 'Over', 'status': 'O', 'price': {'handicap': '5.5', 'decimal': '1.87'}},
                        {'description': 'Under', 'status': 'O', 'price': {'handicap': '5.5', 'decimal': '1.95'}},
                    ],
                }, {
                    'descriptionKey': 'Total Longest Reception O/U - Nico Collins',
                    'status': 'O',
                    'period': {'description': 'Game'},
                    'outcomes': [
                        {'description': 'Over', 'status': 'O', 'price': {'handicap': '22.5', 'decimal': '1.90'}},
                        {'description': 'Under', 'status': 'O', 'price': {'handicap': '22.5', 'decimal': '1.90'}},
                    ],
                }]}],
            }],
        }], NOW)
        self.assertEqual(len(bovada), 2)
        self.assertEqual(bovada[0]['market'], 'player_receptions')
        self.assertEqual(bovada[0]['player'], 'Nico Collins')

        fanduel = parse_fanduel_page({
            'attachments': {
                'events': {'9': {'name': 'Indianapolis Colts @ Houston Texans', 'openDate': '2026-11-22T18:00:00Z'}},
                'markets': {'1': {
                    'eventId': '9',
                    'marketName': 'Nico Collins - Alt Receiving Yds',
                    'runners': [{
                        'runnerName': 'Over',
                        'handicap': 80.5,
                        'winRunnerOdds': {'trueOdds': {'decimalOdds': {'decimalOdds': 2.4}}},
                    }],
                },                 '2': {
                    'eventId': '9',
                    'marketName': 'Nico Collins - Receiving Yds',
                    'runners': [
                        {'runnerName': 'Nico Collins Over', 'handicap': 74.5, 'winRunnerOdds': {'trueOdds': {'decimalOdds': {'decimalOdds': 1.87}}}},
                        {'runnerName': 'Nico Collins Under', 'handicap': 74.5, 'winRunnerOdds': {'trueOdds': {'decimalOdds': {'decimalOdds': 1.95}}}},
                    ],
                }},
            },
        }, NOW)
        self.assertEqual(len(fanduel), 2)
        self.assertEqual(fanduel[0]['line'], 74.5)
        self.assertEqual(fanduel[0]['player'], 'Nico Collins')
        combos = parse_fanduel_page({
            'attachments': {
                'events': {'9': {'name': 'Indianapolis Colts @ Houston Texans', 'openDate': '2026-11-22T18:00:00Z'}},
                'markets': {'3': {
                    'eventId': '9',
                    'marketName': 'Anytime Touchdown Scorer',
                    'runners': [
                        {'runnerName': 'Nico Collins', 'winRunnerOdds': {'trueOdds': {'decimalOdds': {'decimalOdds': 1.8}}}},
                        {'runnerName': 'Nico Collins or C.J. Stroud', 'winRunnerOdds': {'trueOdds': {'decimalOdds': {'decimalOdds': 1.4}}}},
                        {'runnerName': 'Houston Defense', 'winRunnerOdds': {'trueOdds': {'decimalOdds': {'decimalOdds': 3.2}}}},
                    ],
                }},
            },
        }, NOW)
        self.assertEqual([row['player'] for row in combos], ['Nico Collins'])
        self.assertEqual(parse_bovada({'events': []}, NOW), [])

    def test_player_id_uses_the_team_when_names_collide(self):
        roster = build_roster([
            {'playerId': '00-0034857', 'name': 'Josh Allen', 'team': 'BUF', 'season': 2026, 'week': 10},
            {'playerId': '00-0037001', 'name': 'Josh Allen', 'team': 'JAX', 'season': 2025, 'week': 1},
            {'playerId': '00-0039000', 'name': 'Josh Allen', 'team': 'JAX', 'season': 2026, 'week': 8},
        ])
        self.assertEqual(match_player('Josh Allen', ('BUF', 'HOU'), roster)['playerId'], '00-0034857')
        self.assertIsNone(match_player('Josh Allen', ('NYJ', 'NE'), roster))
        self.assertEqual(match_player('C.J. Stroud', ('HOU',), build_roster([
            {'playerId': '00-0039163', 'name': 'C.J. Stroud', 'team': 'HOU', 'season': 2026, 'week': 1},
        ]))['playerId'], '00-0039163')

    def test_schedule_match_and_private_store_keep_the_gsis_id(self):
        schedule = load_schedule_text(
            'game_id,season,game_type,week,gameday,gametime,away_team,home_team\n'
            '1,2026,REG,12,2026-11-22,13:00,IND,HOU\n'
        )
        roster = build_roster([
            {'playerId': '00-0039163', 'name': 'C.J. Stroud', 'team': 'HOU', 'season': 2026, 'week': 11},
        ])
        rows = attach_identity([{
            'book': 'bovada', 'source': 'bovada-public', 'eventId': 'book-1',
            'kickoff': '2026-11-22T18:00:00Z', 'away': 'Indianapolis Colts', 'home': 'Houston Texans',
            'at': '2026-11-21T22:00:00Z',
            'market': 'player_pass_yds', 'outcome': 'Over', 'player': 'C. J. Stroud',
            'line': 242.5, 'decimal': 1.91,
        }], roster, schedule)
        self.assertEqual(rows[0]['eventId'], 'nflverse:2026_12_IND_HOU')
        self.assertEqual(rows[0]['playerId'], '00-0039163')
        self.assertEqual(rows[0]['player'], 'C.J. Stroud')
        history = empty_history()
        private = empty_history()
        add_observations(private, rows)
        self.assertEqual(private['observations'][0]['playerId'], '00-0039163')
        self.assertEqual(private['closes'][0]['line'], 242.5)
        self.assertEqual(history['observations'], [])

    def test_consensus_stays_off_when_either_season_is_missing(self):
        missing = consensus_adoption({
            2025: None,
            2026: {'games': 10, 'modelBrier': 0.3, 'consensusBrier': 0.2, 'modelLogLoss': 0.8, 'consensusLogLoss': 0.6},
        })
        self.assertFalse(missing['adopted'])
        self.assertIn('2025', missing['detail'])
        self.assertEqual(consensus_adoption({2025: None, 2026: None})['reason'], 'unavailable')
        adopted = consensus_adoption({
            2025: {'games': 4, 'modelBrier': 0.3, 'consensusBrier': 0.2, 'modelLogLoss': 0.8, 'consensusLogLoss': 0.6},
            2026: {'games': 4, 'modelBrier': 0.3, 'consensusBrier': 0.2, 'modelLogLoss': 0.8, 'consensusLogLoss': 0.6},
        })
        self.assertTrue(adopted['adopted'])
        tied = consensus_adoption({
            2025: {'games': 4, 'modelBrier': 0.2, 'consensusBrier': 0.2, 'modelLogLoss': 0.6, 'consensusLogLoss': 0.6},
            2026: {'games': 4, 'modelBrier': 0.3, 'consensusBrier': 0.2, 'modelLogLoss': 0.8, 'consensusLogLoss': 0.6},
        })
        self.assertFalse(tied['adopted'])

    def test_public_history_does_not_keep_scraped_prices_or_secrets(self):
        secret = 'super-secret-value'

        def fetch(url, headers):
            return type('R', (), {'status': 403, 'body': json.dumps({'apiKey': secret})})()

        history = empty_history()
        private = empty_history()
        scrape_public_books(
            history, fetch=fetch, pause=lambda _seconds: None, private=private, now=NOW,
        )
        text = json.dumps({'public': history, 'private': private})
        self.assertNotIn(secret, text)
        self.assertEqual(history['observations'], [])
        self.assertEqual(private['observations'], [])
        self.assertTrue(any(row['source'] == 'bovada-public' for row in history['sources']))
        self.assertTrue(all(row['status'] == 'unavailable' for row in history['sources']))
        coverage = coverage_document(private)
        self.assertFalse(coverage['consensusAdopted'])
        self.assertNotIn(secret, json.dumps(coverage))

    def test_a_one_sided_price_is_not_turned_into_a_pair(self):
        self.assertEqual(select_main_lines([{
            'book': 'bovada', 'eventId': 'e', 'market': 'player_rush_yds', 'player': 'A',
            'outcome': 'Over', 'line': 40.5, 'decimal': 1.91,
        }]), [])


if __name__ == '__main__':
    unittest.main()
