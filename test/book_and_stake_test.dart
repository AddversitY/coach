import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/book_link.dart';
import 'package:odds_edge/domain/stake_split.dart';

void main() {
  test('a book link must be https on that book host', () {
    expect(
      permittedBookLink('https://sportsbook.fanduel.com/addToBetslip?id=1', 'fanduel'),
      'https://sportsbook.fanduel.com/addToBetslip?id=1',
    );
    expect(
      permittedBookLink('http://sportsbook.fanduel.com/addToBetslip', 'fanduel'),
      isNull,
    );
    expect(
      permittedBookLink('https://evil.example/fanduel.com', 'fanduel'),
      isNull,
    );
    expect(
      permittedBookLink('https://user:pass@sportsbook.fanduel.com/x', 'fanduel'),
      isNull,
    );
    expect(
      permittedBookLink('https://sportsbook.fanduel.com/x?apiKey=secret', 'fanduel'),
      isNull,
    );
    expect(
      permittedBookLink('https://sportsbook.draftkings.com/x', 'fanduel'),
      isNull,
    );
  });

  test('a stake split uses the entered amount and is not saved', () {
    final split = hedgeSplit(
      total: 50,
      legs: [
        (label: 'Over', book: 'FanDuel', decimal: 1.91),
        (label: 'Under', book: 'DraftKings', decimal: 1.91),
      ],
    );
    final staked = split.legs.map((leg) => leg.stake).reduce((a, b) => a + b);
    expect(staked, closeTo(50, 1e-9));
    expect(split.legs.first.stake, closeTo(25, 1e-6));
    expect(
      split.result(wins: [true, false]),
      closeTo(split.legs.first.profitIfWins - split.legs.last.stake, 1e-6),
    );
  });
}
