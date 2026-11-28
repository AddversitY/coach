import 'package:odds_edge/domain/price_history.dart';
import 'package:odds_edge/domain/prop_line_shop.dart';
import 'package:flutter_test/flutter_test.dart';

SavedBookPrice row(
  String book,
  String outcome,
  double decimal, {
  double line = 241.5,
}) {
  return SavedBookPrice(
    book: book,
    market: 'player_pass_yds',
    outcome: outcome,
    player: 'Brock Purdy',
    decimal: decimal,
    line: line,
    eventId: 'nflverse:2026_13_SF_SEA',
    at: '2026-11-28T18:00:00Z',
  );
}

const record = PropConsensusRecord(scored: 0);

const flagged =
    'Best price vs other books: DraftKings, Brock Purdy Over 241.5 at +120 (decimal 2.2), consensus fair chance 48.1% from 3 books, price saved 2026-11-28T18:00:00Z. This is a comparison, not a pick. Prop-consensus closing-line record: 0 scored bets. 200 scored bets, with the low end of the range above zero, are needed before this is a signal.';

void main() {
  final prices = [
    row('fanduel', 'Over', 1.91),
    row('fanduel', 'Under', 1.91),
    row('bovada', 'Over', 1.91),
    row('bovada', 'Under', 1.91),
    row('draftkings', 'Over', 2.2),
    row('draftkings', 'Under', 1.74),
  ];

  test('a price that pays 3% more than the consensus is named', () {
    expect(
      bestPriceVsOtherBooksSentence(
        prices: prices,
        question: 'Brock Purdy passing yards over 241.5',
        record: record,
        knownNames: const ['Brock Purdy'],
      ),
      flagged,
    );
  });

  test('fewer than 3 books on one line stays unavailable', () {
    final text = bestPriceVsOtherBooksSentence(
      prices: prices.where((row) => row.book != 'draftkings').toList(),
      question: 'Brock Purdy passing yards',
      record: record,
      knownNames: const ['Brock Purdy'],
    );
    expect(text, contains('Fewer than 3 books'));
    expect(text, contains('A different line is not treated as the same chance'));
    expect(text, contains('a comparison, not a pick'));
  });

  test('an even market and a missing price stay a comparison', () {
    final even = [
      row('fanduel', 'Over', 1.91),
      row('fanduel', 'Under', 1.91),
      row('bovada', 'Over', 1.91),
      row('bovada', 'Under', 1.91),
      row('betrivers', 'Over', 1.91),
      row('betrivers', 'Under', 1.91),
    ];
    expect(
      bestPriceVsOtherBooksSentence(prices: even, question: 'Brock Purdy passing yards', record: record, knownNames: const ['Brock Purdy']),
      contains('50.0% from 3 books'),
    );
    expect(
      bestPriceVsOtherBooksSentence(prices: const [], question: 'Brock Purdy passing yards', record: record),
      contains('No saved price for this prop'),
    );
    expect(asksPropComparison('How good is Coach at receiving yards props?'), isFalse);
    expect(asksPropComparison('best prop prices'), isTrue);
  });

  test('the empty log is a real zero, and a missing log stays unavailable', () {
    expect(recordSentence(record), contains('0 scored bets'));
    expect(recordSentence(null), contains('unavailable'));
    expect(
      PropConsensusRecord.fromJson({
        'summary': {
          'passes': false,
          'clv': {'n': 0, 'mean': null, 'low': null, 'high': null},
        },
      }).scored,
      0,
    );
  });
}
