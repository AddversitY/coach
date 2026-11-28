"""The prop-consensus comparison: same line, at least 3 books, graded after kickoff."""

import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

import edge_log
import prop_consensus

AT = '2026-11-28T18:00:00Z'
KICK = '2026-11-29T18:00:00Z'
EVENT = 'nflverse:2026_13_SF_SEA'
RECORD = {'scored': 0, 'mean': None, 'low': None, 'high': None, 'passes': False}
FLAGGED = (
    'Best price vs other books: DraftKings, Brock Purdy Over 241.5 at +120 (decimal 2.2), '
    'consensus fair chance 48.1% from 3 books, price saved 2026-11-28T18:00:00Z. '
    'This is a comparison, not a pick. Prop-consensus closing-line record: 0 scored bets. '
    '200 scored bets, with the low end of the range above zero, are needed before this is a signal.'
)


def row(book, outcome, decimal, line=241.5, at=AT, kickoff=KICK, player='Brock Purdy'):
    return {
        'book': book, 'eventId': EVENT, 'market': 'player_pass_yds', 'outcome': outcome,
        'player': player, 'decimal': decimal, 'line': line, 'at': at, 'kickoff': kickoff,
    }


def slate():
    return [
        row('fanduel', 'Over', 1.91), row('fanduel', 'Under', 1.91),
        row('bovada', 'Over', 1.91), row('bovada', 'Under', 1.91),
        row('draftkings', 'Over', 2.2), row('draftkings', 'Under', 1.74),
    ]


class PropConsensusTests(unittest.TestCase):
    def test_flag_sentence_matches_the_three_book_example(self):
        self.assertEqual(prop_consensus.format_consensus(slate(), record=RECORD), FLAGGED)

    def test_thin_book_and_a_different_line_stay_unavailable(self):
        thin = [item for item in slate() if item['book'] != 'draftkings']
        text = prop_consensus.format_consensus(thin, player='Brock Purdy', record=RECORD)
        self.assertIn('Fewer than 3 books have a two-sided price on the same line', text)
        moved = [
            row('fanduel', 'Over', 1.91), row('fanduel', 'Under', 1.91),
            row('bovada', 'Over', 1.91), row('bovada', 'Under', 1.91),
            row('draftkings', 'Over', 2.2, line=250.5), row('draftkings', 'Under', 1.74, line=250.5),
        ]
        self.assertIn('Fewer than 3 books', prop_consensus.format_consensus(moved, record=RECORD))

    def test_even_market_is_not_flagged_and_anytime_has_no_consensus(self):
        even = [
            row('fanduel', 'Over', 1.91), row('fanduel', 'Under', 1.91),
            row('bovada', 'Over', 1.91), row('bovada', 'Under', 1.91),
            row('betrivers', 'Over', 1.91), row('betrivers', 'Under', 1.91),
        ]
        text = prop_consensus.format_consensus(even, record=RECORD)
        self.assertIn('no saved price pays 3% more than a fair payout', text)
        self.assertIn('50.0%', text)
        self.assertIn('Anytime touchdown is one-sided', prop_consensus.format_consensus(slate(), market='player_anytime_td', record=RECORD))
        self.assertIn('No saved price for this prop', prop_consensus.format_consensus([], record=RECORD))

    def test_first_sighting_is_kept_and_scored_against_the_book_consensus_close(self):
        now = datetime(2026, 11, 28, 18, tzinfo=timezone.utc)
        log = {'alerts': []}
        added = prop_consensus.update_log(log, edge_log.normalize(slate()), [], now)
        self.assertEqual(added, 1)
        self.assertFalse(log['adopted'])
        self.assertEqual(log['signal'], 'prop-consensus')
        self.assertEqual(log['alerts'][0]['angle'], 'prop-consensus')
        again = prop_consensus.update_log(log, edge_log.normalize(slate()), [], now)
        self.assertEqual(again, 0)
        close_at = '2026-11-29T17:00:00Z'
        closes = []
        for book in ('fanduel', 'bovada', 'betrivers'):
            closes += [row(book, 'Over', 1.91, at=close_at), row(book, 'Under', 1.91, at=close_at)]
        later = datetime(2026, 11, 30, 18, tzinfo=timezone.utc)
        prop_consensus.update_log(log, edge_log.normalize(slate()), edge_log.normalize(closes), later)
        self.assertEqual(log['summary']['clv']['n'], 1)
        self.assertEqual(log['alerts'][0]['clv'], 0.1)
        self.assertEqual(log['alerts'][0]['clvReference'], 'book consensus')
        self.assertFalse(log['passes'])

    def test_a_bad_price_file_does_not_wipe_the_log(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'prop-consensus.json'
            log.write_text(json.dumps({'alerts': [{'keep': True}]}))
            bad = Path(folder) / 'bad.json'
            bad.write_text('not json')
            self.assertEqual(prop_consensus.main(['--book-prices', str(bad), '--log', str(log)]), 0)
            self.assertIn('keep', log.read_text())


if __name__ == '__main__':
    unittest.main()
