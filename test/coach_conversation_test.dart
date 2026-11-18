import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/coach_conversation.dart';

import 'game_research_test.dart' show event, now;

void main() {
  test(
    'team under shorthand retains the missing total for a numeric reply',
    () {
      final c = CoachConversation()..remember(event, 'Bills under this week');
      expect(c.market, 'game total');
      expect(c.side, 'under');
      expect(c.point, isNull);
      c.noteClarification('Which line?');
      final completed = c.resolve('45.5', now);
      expect(completed.game, true);
      expect(completed.query, contains('game total under 45.5'));
      expect(completed.query, contains(' on 2026-'));
    },
  );

  test(
    'clarification replies supply only the missing line, side, market or team',
    () {
      final c = CoachConversation()
        ..remember(
          event,
          'Recorded Quarterback passing yards under',
          player: 'Recorded Quarterback',
        );
      c.noteClarification('Which line?');
      final line = c.resolve('245.5', now);
      expect(line.game, true);
      expect(
        line.query,
        contains('Recorded Quarterback passing yards under 245.5'),
      );
      expect(line.query, contains(' on 2026-'));

      c.remember(event, 'Game total 45.5');
      c.noteClarification('Over or under?');
      expect(c.resolve('Under', now).query, contains('game total under 45.5'));

      c.remember(
        event,
        'Recorded Quarterback under 65.5',
        player: 'Recorded Quarterback',
      );
      c.noteClarification('Which stat?');
      expect(
        c.resolve('Passing yards', now).query,
        contains('Recorded Quarterback passing yards under 65.5'),
      );

      c.remember(event, 'Spread line -3.5');
      c.noteClarification('Which team?');
      expect(
        c.resolve('Chiefs', now).query,
        startsWith('Kansas City Chiefs spread line -3.5'),
      );

      c.noteClarification(
        'No recorded player matches that name.',
        resetSubject: true,
      );
      expect(
        c.resolve('Why?', now).clarification,
        'No recorded player matches that name.',
      );
      expect(
        c.resolve('Under 65.5', now).clarification,
        contains('Which upcoming game'),
      );
    },
  );
  test('unsupported periods cannot become full-game follow-ups', () {
    final c = CoachConversation()..remember(event, 'Bills spread -3.5');
    for (final question in [
      'Bills first-half spread -3.5',
      'Bills team total under 45.5',
      'Bills regulation-only moneyline',
      'Bills live spread -3.5',
    ]) {
      final result = c.resolve(question, now);
      expect(result.game, false);
      expect(result.clarification, isNotNull);
      expect(c.resolve('Why?', now).clarification, result.clarification);
      expect(c.point, isNull);
    }
    expect(
      c.resolve('Compare the total', now).clarification,
      contains('Which upcoming game'),
    );
    expect(
      CoachConversation.unsupportedScope('Bills live injury updates'),
      isNull,
    );
  });
  test('a date and American odds never create a missing spread in follow-up memory', () {
    final c = CoachConversation()
      ..remember(event, 'Bills spread on 2026-11-22 at -110');
    expect(c.market, 'spread');
    expect(c.point, isNull);
    final follow = c.resolve('Show the opposing case', now);
    expect(follow.query, isNot(contains('spread line -11')));
    expect(follow.query, isNot(contains('spread line -22')));
    c.remember(event, 'Bills spread -3.5');
    c.remember(event, 'Chiefs spread on 2026-11-22 at -110');
    expect(c.point, isNull);
    expect(
      c.resolve('Show the opposing case', now).query,
      isNot(contains('-3.5')),
    );
  });
  test('common shorthand preserves market identity and excludes American prices and dates', () {
    expect(CoachConversation.marketIn('Bills -3.5 at -110'), 'spread');
    expect(CoachConversation.marketIn('Chiefs +3.5'), 'spread');
    expect(CoachConversation.marketIn('Bills ML -150'), 'moneyline');
    expect(CoachConversation.marketIn('Bills under 45.5'), 'game total');
    expect(
      CoachConversation.marketIn('Recorded Receiver rec yds over 65.5'),
      'receiving yards',
    );
    expect(
      CoachConversation.marketIn('Recorded Quarterback pass yds under 245.5'),
      'passing yards',
    );
    expect(
      CoachConversation.marketIn('Recorded Runner rush yds over 68.5'),
      'rushing yards',
    );
    expect(CoachConversation.marketIn('Bills on 2026-11-22 at -110'), isNull);
    final c = CoachConversation()..remember(event, 'Bills -3.5 at -110');
    expect(
      c.resolve('Show the opposing case', now).query,
      contains('spread line -3.5'),
    );
  });
  test('bare team questions open visual game research without treating injury questions as team-only prompts', () {
    for (final q in [
      'Bills',
      'BUF',
      'Tell me about the Buffalo Bills',
      'Show me the Bills',
    ]) {
      expect(CoachConversation.isTeamPrompt(q), isTrue);
    }
    for (final q in [
      'Bills injuries',
      'Show unknown team',
      'Bills weather',
      'Bills games last season',
    ]) {
      expect(CoachConversation.isTeamPrompt(q), isFalse);
    }
  });
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
