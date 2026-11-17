import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/coach_conversation.dart';

import 'game_research_test.dart' show event, now;

void main() {
  test('focused follow-ups preserve the subject and do not carry a spread into a total or matchup', () {
    final c = CoachConversation()..remember(event, 'buf -3.5 spread at -110');
    expect(c.point, -3.5);
    expect(
      c.resolve('Show the opposing case', now).query,
      contains('spread line -3.5'),
    );
    final total = c.resolve('Compare the total', now);
    expect(total.clarification, isNull);
    expect(total.query, contains('game total'));
    expect(total.query, isNot(contains('-3.5')));
    final matchup = c.resolve('Show the matchup', now);
    expect(matchup.query, isNot(contains('spread line')));
    c.clear();
    expect(c.resolve('Compare the total', now).clarification, isNotNull);
  });
  test('under follow-up preserves player, market and exact explicit line', () {
    final c = CoachConversation()
      ..remember(
        event,
        'Recorded Quarterback passing yards over 245.5',
        player: 'Recorded Quarterback',
      );
    final r = c.resolve('What about the under?', now);
    expect(r.clarification, isNull);
    expect(r.game, isTrue);
    expect(r.query, contains('Recorded Quarterback passing yards under 245.5'));
    c.remember(event, r.query, player: 'Recorded Quarterback');
    expect(c.resolve('At DraftKings?', now).query, contains('under 245.5'));
    expect(c.resolve('At DraftKings?', now).query, contains('DraftKings'));
  });
  test(
    'market switches clear old line and missing line requires clarification',
    () {
      final c = CoachConversation()..remember(event, 'Bills spread line -3.5');
      final total = c.resolve('What about the total?', now);
      expect(total.query, contains('game total'));
      expect(total.query, isNot(contains('-3.5')));
      c.remember(event, total.query);
      expect(
        c.resolve('What about the under?', now).clarification,
        contains('Which game total line'),
      );
      expect(c.resolve('Under 45.5', now).query, contains('under 45.5'));
    },
  );
  test('no context, new chat, expired game and unknown subjects do not inherit a selection', () {
    final c = CoachConversation();
    expect(c.resolve('What about the under?', now).clarification, isNotNull);
    c.remember(event, 'Bills total over 45.5');
    expect(
      c.resolve('What about Unknown Person?', now).query,
      'What about Unknown Person?',
    );
    expect(
      c.resolve('What about the under?', event.startsAt).clarification,
      isNotNull,
    );
    c.clear();
    expect(c.resolve('Why?', now).clarification, isNotNull);
  });
  test('switching player clears previous line and never defaults a player for a new prop', () {
    final c = CoachConversation()
      ..remember(
        event,
        'Recorded Quarterback passing yards over 245.5',
        player: 'Recorded Quarterback',
      );
    c.remember(
      event,
      'Recorded Receiver receiving yards',
      player: 'Recorded Receiver',
    );
    expect(c.point, isNull);
    expect(c.resolve('Under?', now).clarification, isNotNull);
    c.remember(event, 'Bills moneyline');
    expect(
      c.resolve('What about passing yards?', now).clarification,
      contains('Which player'),
    );
  });
  test('team abbreviations retain their side and an unspecified side stays unspecified', () {
    final c = CoachConversation()..remember(event, 'BUF spread line 3.5');
    expect(
      c.resolve('Why?', now).query,
      startsWith('Buffalo Bills spread line 3.5'),
    );
    c.remember(event, 'Analyze ${event.away} at ${event.home}');
    final q = c.resolve('What about the spread?', now).query;
    expect(q, contains('${event.away} at ${event.home}'));
    final all = c.resolve('Compare the markets', now).query;
    expect(all, contains('Compare the markets'));
    expect(all, isNot(contains('spread line')));
  });
}
