import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/coach_session.dart';
import 'package:odds_edge/domain/odds.dart';

import 'game_research_test.dart' show event, now, fixtureData;

void main() {
  final board = OddsBoard(events: [event], quotes: const [], fetchedAt: now);
  OddsQuote quote({double line = 245.5, DateTime? at}) => OddsQuote(
    selection: Selection(
      eventId: event.id,
      market: 'player_pass_yds',
      participant: 'Recorded Quarterback',
      outcome: 'Over',
      point: line,
    ),
    bookId: 'book',
    book: 'Book',
    provider: 'fixture',
    decimal: 2.1,
    sourceAt: at ?? now,
    collectedAt: at ?? now,
  );
  final data = fixtureData();
  CoachAnswer ask(
    CoachSession session,
    String q, {
    List<OddsQuote>? quotes,
    Map<String, String> ids = const {'Recorded Quarterback': 'qb-1'},
    DateTime? at,
  }) => session.respond(
    q,
    board: board,
    prices: OddsBoard(
      events: [event],
      quotes: quotes ?? [quote(), quote(line: 255.5)],
      fetchedAt: now,
    ),
    data: data,
    playerIds: ids,
    now: at ?? now,
  );

  test('follow-ups retain exact player, stat and line, but new subjects clear line', () {
    final session = CoachSession();
    final first = ask(
      session,
      'Compare Recorded Quarterback passing yards over 245.5',
    );
    expect(first.player!.id, 'qb-1');
    expect(first.quotes, hasLength(1));
    final challenge = ask(session, 'What argues against it?');
    expect(challenge.intent, CoachIntent.challenge);
    expect(challenge.line, 245.5);
    expect(challenge.text, contains('don’t establish'));
    final other = ask(session, 'Show Recorded Receiver receiving yards');
    expect(other.player!.id, 'wr-1');
    expect(other.line, isNull);
  });
  test('unknown subject never silently becomes the previous player', () {
    final session = CoachSession();
    ask(session, 'Show Recorded Quarterback');
    final missing = ask(session, 'What about Unknown Person?');
    expect(missing.intent, CoachIntent.clarify);
    expect(missing.player, isNull);
  });
  test('saved prices require exact identity and expire at kickoff', () {
    expect(
      ask(CoachSession(), 'Recorded Quarterback prices', ids: {}).quotes,
      isEmpty,
    );
    expect(
      ask(
        CoachSession(),
        'Recorded Quarterback prices',
        quotes: [quote(at: now.subtract(const Duration(hours: 19)))],
      ).quotes,
      isEmpty,
    );
    expect(
      ask(
        CoachSession(),
        'Recorded Quarterback prices',
        at: event.startsAt,
      ).quotes,
      isEmpty,
    );
  });
  test('current injury requests disclose missing inputs; model payload has no invented quote or baseline', () {
    final a = ask(CoachSession(), 'Is Recorded Quarterback injured?');
    expect(a.text, contains('don’t have verified current'));
    final payload = a.modelPayload('Is he injured?', now);
    expect(payload.containsKey('selection'), false);
    expect(payload.containsKey('assumptions'), false);
    expect(payload.containsKey('quote'), false);
  });
}
