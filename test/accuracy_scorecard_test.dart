import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/coach/accuracy_scorecard_screen.dart';
import 'package:odds_edge/coach/coach_workspace.dart';
import 'package:odds_edge/data/nfl_assets.dart';
import 'package:odds_edge/data/published_snapshot.dart';
import 'package:odds_edge/domain/accuracy_scorecard.dart';
import 'package:odds_edge/domain/coach_briefing.dart';
import 'package:odds_edge/domain/odds.dart';
import 'package:odds_edge/theme/coach_theme.dart';

import 'game_research_test.dart' show event, fixtureData, now;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const scored = {
    'status': 'scored',
    'picks': 18,
    'coachCloser': 8,
    'bookCloser': 10,
    'same': 0,
    'coachBrier': 0.253,
    'bookBrier': 0.251,
    'coachLogLoss': 0.700,
    'bookLogLoss': 0.696,
    'sentence':
        'This season the books were slightly more accurate: 0.251 vs 0.253 (lower is better). 18 lines. Coach was closer on 8 and the books on 10. This compares chances with the closing price. It is not a pick.',
  };

  AccuracyScorecard card() => AccuracyScorecard.fromJson({
    'season': 2026,
    'notice': 'This is not a pick.',
    'weeks': [
      {
        'season': 2026,
        'week': 1,
        'status': 'unavailable',
        'picks': 0,
        'coachBrier': null,
        'bookBrier': null,
        'sentence':
            'Week 1 is unavailable. No closing prices were saved for that week.',
      },
      {'season': 2026, 'week': 2, ...scored, 'sentence': scored['sentence']},
    ],
    'seasonToDate': scored,
  });

  test('a week with no saved close stays unavailable and invents no number', () {
    final report = card();
    final week = report.week(1)!;
    expect(week.status, 'unavailable');
    expect(week.coachBrier, isNull);
    expect(week.bookBrier, isNull);
    expect(week.sentence, contains('unavailable'));
    expect(report.answer('How accurate was Coach in week 1?'), week.sentence);
    expect(report.answer('How accurate has Coach been?'), contains('0.251 vs 0.253'));
    expect(report.answer('How accurate has Coach been?'), contains('lower is better'));
    expect(report.answer('How accurate has Coach been?'), contains('not a pick'));
    expect(report.answer('How accurate has Coach been this week?'), contains('0.251 vs 0.253'));
  });

  test('the chat answers accuracy from the scorecard, not a guessed record', () {
    final brief = interpretQuestion(
      question: 'How accurate has Coach been?',
      evidence: null,
      players: null,
      ratings: null,
      scorecard: card(),
    );
    expect(brief, isNotNull);
    expect(brief!.title, 'Accuracy');
    expect(brief.text, contains('0.251 vs 0.253'));
    expect(brief.text, isNot(contains('unit')));
    expect(brief.text, isNot(contains('bankroll')));
    expect(asksForAccuracy('How good is Coach at receiving yards props?'), isFalse);
    final grade = interpretQuestion(
      question: 'How good is Coach at receiving yards props?',
      evidence: null,
      players: null,
      ratings: null,
      scorecard: card(),
    );
    expect(grade!.title, 'Report card');
  });

  testWidgets('the scorecard screen reads the saved sentences', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: coachTheme(),
        home: AccuracyScorecardScreen(scorecard: card()),
      ),
    );
    expect(find.textContaining('0.251 vs 0.253'), findsWidgets);
    expect(find.textContaining('Week 1 is unavailable'), findsOneWidget);
    expect(find.text('18 lines. Coach closer 8. Books closer 10.'), findsWidgets);
  });

  testWidgets('the chat header opens the scorecard without leaving the desk', (
    tester,
  ) async {
    final board = OddsBoard(events: [event], quotes: const [], fetchedAt: now);
    await tester.pumpWidget(
      MaterialApp(
        theme: coachTheme(),
        home: CoachWorkspace(
          snapshotLoader: () async => PublishedSnapshot(
            board: board,
            props: board,
            generatedAt: now,
            scheduleAt: now,
            oddsMessage: 'No saved prices',
          ),
          playerLoader: () async => fixtureData(),
          clock: () => now,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('coach-workspace')), findsOneWidget);
    await tester.tap(find.byKey(const Key('coach-scorecard')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Accuracy'), findsWidgets);
    expect(find.byType(AccuracyScorecardScreen), findsOneWidget);
  });

  test('the bundled file does not invent a score for an empty week', () async {
    final report = await loadBundledAccuracyScorecard();
    expect(report.weeks, isNotEmpty);
    for (final week in report.weeks) {
      expect(week.sentence, isNotEmpty);
      if (!week.scored) {
        expect(week.coachBrier, isNull);
        expect(week.bookBrier, isNull);
        expect(week.sentence.toLowerCase(), contains('unavailable'));
      } else {
        expect(week.picks, greaterThan(0));
        expect(week.sentence, contains('lower is better'));
        expect(week.sentence.toLowerCase(), isNot(contains('unit')));
        expect(week.sentence.toLowerCase(), isNot(contains('bankroll')));
      }
    }
    expect(report.seasonToDate.sentence.toLowerCase(), isNot(contains('edge')));
  });
}
