import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/coach_books.dart';
import 'package:odds_edge/domain/coach_conversation.dart';

import 'game_research_test.dart' show event, now;

void main() {
  test('specific, multiple and all-book requests replace the prior filter', () {
    expect(CoachBooks.parse('At FanDuel', previous: ['betmgm']), ['fanduel']);
    expect(
      CoachBooks.parse('Compare DraftKings and FanDuel', previous: ['betmgm']),
      ['draftkings', 'fanduel'],
    );
    expect(CoachBooks.parse('Compare all books', previous: ['betmgm']), isNull);
    expect(CoachBooks.parse('Why?', previous: ['fanduel', 'draftkings']), [
      'draftkings',
      'fanduel',
    ]);
    expect(() => CoachBooks.normalize(['made_up']), throwsFormatException);
    expect(
      () => CoachBooks.normalize(['fanduel', 'fanduel']),
      throwsFormatException,
    );
  });
  test('book-only follow-ups retain selection and event, without preserving an old book in the query', () {
    final c = CoachConversation()
      ..remember(event, 'Bills spread -3.5 at BetMGM', book: 'betmgm');
    final pair = c.resolve('Compare DraftKings and FanDuel', now);
    expect(pair.game, true);
    expect(pair.query, contains('spread line -3.5'));
    expect(pair.query, contains('DraftKings and FanDuel'));
    expect(pair.query, isNot(contains('BetMGM')));
    expect(c.resolve('All books', now).query, contains('All books'));
    expect(CoachBooks.isPreferenceOnly('Bills spread -3.5 at FanDuel'), false);
  });
}
