import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/coach_briefing.dart';
import 'package:odds_edge/domain/line_movement.dart';

void main() {
  test('a late move is quoted and a single price stays unavailable', () {
    final book = LineMoveBook.fromJson({
      'adopted': true,
      'moves': [
        {
          'eventId': 'ev',
          'market': 'spreads',
          'book': 'median',
          'home': 'HOU',
          'away': 'IND',
          'homeName': 'Houston Texans',
          'awayName': 'Indianapolis Colts',
          'kickoff': '2026-11-22T18:00:00Z',
          'openLine': -2.5,
          'closeLine': -4.5,
          'openToClose': -2,
          'lateFrom': -3,
          'lateTo': -4.5,
          'lateMove': -1.5,
          'keyNumbers': [3],
          'pinnacleLine': -4.5,
          'retailLine': -3.5,
          'steam': null,
          'againstPublic': 'unavailable',
        },
      ],
    });
    expect(book.adopted, isFalse);
    expect(lineMovementAdopted, isFalse);
    final text = book.moves.single.sentence();
    expect(text, contains('moved from -3 to -4.5 in the last 3 hours'));
    expect(text, contains('That is the home spread.'));
    expect(text, contains('crossed 3'));
    expect(text, contains('Pinnacle is -4.5 and the other books are -3.5'));
    expect(text, contains('not a pick'));
    expect(text.toLowerCase(), isNot(contains('edge')));

    final one = LineMove.fromJson({
      'market': 'spreads',
      'book': 'draftkings',
      'openLine': -3,
      'closeLine': -3,
    });
    expect(one.measured, isFalse);
    expect(one.sentence(), contains('unavailable'));
    expect(
      book.sentenceFor(home: 'Houston Texans', away: 'Indianapolis Colts'),
      contains('last 3 hours'),
    );
  });

  test('a movement question says unavailable until a game is saved', () {
    final brief = interpretQuestion(
      question: 'How has the line moved?',
      evidence: null,
      players: null,
      ratings: null,
      moves: LineMoveBook.empty,
    );
    expect(brief, isNotNull);
    expect(brief!.title, 'Line movement');
    expect(brief.text, contains('unavailable'));
    expect(brief.text, contains('not a pick'));
    expect(brief.handlesQuestion, isTrue);
  });
}
