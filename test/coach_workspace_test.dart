import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/coach/coach_workspace.dart';
import 'package:odds_edge/data/published_snapshot.dart';
import 'package:odds_edge/domain/assistant.dart';
import 'package:odds_edge/domain/coach_telemetry.dart';
import 'package:odds_edge/domain/odds.dart';
import 'package:odds_edge/theme/coach_theme.dart';
import 'package:odds_edge/main.dart' as app;

import 'game_outlook_test.dart' show gameOutlookFixture;
import 'game_research_test.dart'
    show event, now, fixtureData, dataWith, recorded;

void main() {
  testWidgets('public app entry point opens Coach without the legacy shell', (
    tester,
  ) async {
    await tester.pumpWidget(const app.OddsEdgeApp());
    expect(find.byType(CoachWorkspace), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  final board = OddsBoard(events: [event], quotes: const [], fetchedAt: now);
  PublishedSnapshot snapshot() => PublishedSnapshot(
    board: board,
    props: board,
    generatedAt: now,
    scheduleAt: now,
    oddsMessage: 'No saved prices',
  );
  Widget frame({
    Future<AssistantReply> Function(Map<String, dynamic>)? ask,
    Future<PublishedSnapshot> Function()? loader,
    Future<CoachTelemetry> Function()? telemetryLoader,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>)? gameLoader,
    Future<Map<String, dynamic>> Function()? evaluationLoader,
  }) => MaterialApp(
    theme: coachTheme(),
    home: CoachWorkspace(
      snapshotLoader: loader ?? () async => snapshot(),
      playerLoader: () async => fixtureData(),
      clock: () => now,
      ask: ask,
      telemetryLoader: telemetryLoader,
      gameAnalysisLoader: gameLoader,
      evaluationLoader: evaluationLoader,
    ),
  );
  Future<void> send(WidgetTester tester, String q) async {
    await tester.enterText(find.byKey(const Key('coach-composer')), q);
    await tester.tap(find.byKey(const Key('coach-send')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'phone has one conversation with contextual follow-ups and no navigation pages',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(frame());
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Research'), findsNothing);
      expect(
        find.textContaining('open-ended AI not connected'),
        findsOneWidget,
      );
      await send(tester, 'Show Recorded Quarterback passing yards');
      expect(
        find.textContaining('Recorded Quarterback · Pass yards'),
        findsOneWidget,
      );
      await send(tester, 'What changed?');
      expect(find.textContaining('Pass attempts averaged'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('coach-new-chat')));
      await tester.pumpAndSettle();
      expect(find.text('Read the game.\nQuestion the line.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'a long response opens at its beginning instead of the last player',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: coachTheme(),
          home: CoachWorkspace(
            snapshotLoader: () async => snapshot(),
            clock: () => now,
            playerLoader: () async => dataWith([
              for (var i = 0; i < 14; i++)
                recorded(id: 'qb-$i', name: 'Quarterback $i'),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Explore Buffalo Bills at Kansas City Chiefs');
      expect(find.text('Quarterback 0').hitTestable(), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Buffalo Bills at Kansas City Chiefs')).dy,
        lessThan(400),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('AI uses retrieved evidence and fails back truthfully', (
    tester,
  ) async {
    Map<String, dynamic>? request;
    await tester.pumpWidget(
      frame(
        ask: (p) async {
          request = p;
          return AssistantReply.unavailable;
        },
      ),
    );
    await tester.pumpAndSettle();
    await send(tester, 'Recorded Quarterback prices');
    expect(request!['question'], 'Recorded Quarterback prices');
    expect(request!['playerEvidence'], isNotEmpty);
    expect(
      find.textContaining('AI interpretation is unavailable'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('enlarged text, failure and retry remain usable', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    bool fail = true;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
        child: frame(
          loader: () async {
            if (fail) throw StateError('offline');
            return snapshot();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry loading data'), findsOneWidget);
    expect(tester.takeException(), isNull);
    fail = false;
    await tester.ensureVisible(find.text('Retry loading data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry loading data'));
    await tester.pumpAndSettle();
    await send(tester, 'Brief me');
    expect(find.text('Let’s start with a game'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'phone runs explicit stress research and keeps push lines unsupported',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: coachTheme(),
          home: CoachWorkspace(
            snapshotLoader: () async => snapshot(),
            analysisHistoryLoader: () async => [],
            validationLoader: () async => {'hasEdge': false, 'adopted': false},
            clock: () => now,
            playerLoader: () async => dataWith([
              for (var i = 0; i < 7; i++)
                recorded(
                  week: i + 3,
                  date: '2026-11-${(i + 1).toString().padLeft(2, '0')}',
                  stats: {'passing_yards': 220 + i * 10, 'attempts': 30 + i},
                ),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await send(
        tester,
        'Stress test Recorded Quarterback over 245.5 passing yards',
      );
      await tester.pumpAndSettle();
      expect(find.text('Stress-test results'), findsOneWidget);
      expect(
        find.textContaining('9 assumption scenarios tested'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await send(
        tester,
        'Stress test Recorded Quarterback over 245 passing yards',
      );
      expect(find.text('Let’s make the inputs explicit'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'phone brings attributed reporter news to Coach without requiring a game',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Map<String, dynamic>? request;
      final report = CoachTelemetry(
        checkedAt: now,
        observations: [
          TelemetryObservation(
            id: 'headline',
            kind: 'news',
            eventId: 'nfl',
            source: 'ESPN NFL RSS',
            observedAt: now,
            value: {
              'title': 'A dated NFL report',
              'author': 'Test Reporter',
              'publishedAt': now.toIso8601String(),
              'url': 'https://www.espn.com/nfl/story/_/id/123/test',
            },
          ),
        ],
        sources: const [
          {'id': 'beat_writers', 'state': 'attributed_headlines'},
        ],
      );
      await tester.pumpWidget(
        frame(
          telemetryLoader: () async => report,
          ask: (payload) async {
            request = payload;
            return const AssistantReply(
              available: true,
              answer: 'An attributed report is available; participation remains unconfirmed.',
              cited: ['team_evidence'],
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Latest reporter news');
      expect(find.text('From the reporters'), findsOneWidget);
      expect(find.text('A dated NFL report'), findsOneWidget);
      expect(find.textContaining('Test Reporter'), findsOneWidget);
      expect(find.text('Read source'), findsOneWidget);
      expect(request!['question'], 'Latest reporter news');
      expect((request!['context'] as Map)['eventId'], isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'phone analyzes the whole game across markets and retains the selected book',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? requestedBook;
      await tester.pumpWidget(
        frame(
          gameLoader: (payload) async {
            requestedBook = (payload['context'] as Map)['bookId'] as String?;
            return gameOutlookFixture(event, now, bookId: requestedBook);
          },
          evaluationLoader: () async => {
            'capturedGames': 0,
            'gradedGames': 0,
            'pendingGames': 0,
            'unresolved': 0,
            'markets': [],
            'notice': 'No settled forecasts yet.',
            'historical': {
              'evaluationGames': 409,
              'markets': {
                'moneyline': {
                  'games': 407,
                  'incumbentBrier': .238,
                  'brier': .226,
                  'marketBrier': .213,
                },
              },
            },
            'models': [
              {'role': 'shadow', 'gradedGames': 0, 'pendingGames': 1},
            ],
          },
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Analyze Bills');
      for (final label in [
        'Spread',
        'Game total',
        'Moneyline',
        'Player props',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Player workload outlook'), findsOneWidget);
      expect(find.text('Resolve the lineup questions first'), findsOneWidget);
      await tester.ensureVisible(find.text('Lineup & workload'));
      await tester.tap(find.text('Lineup & workload'));
      await tester.pumpAndSettle();
      expect(
        find.text('Listed quarterback · Listed Quarterback'),
        findsOneWidget,
      );
      expect(find.textContaining('Recorded team share 20%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('DraftKings'));
      await tester.tap(find.text('DraftKings'));
      await tester.pumpAndSettle();
      expect(requestedBook, 'draftkings');
      await send(tester, 'Bills moneyline');
      expect(find.text('Player workload outlook'), findsNWidgets(3));
      await send(tester, 'Coach performance');
      expect(find.text('Coach’s forecast record'), findsOneWidget);
      expect(find.text('No settled forecasts yet.'), findsOneWidget);
      expect(
        find.textContaining('Background challenger: 0 graded'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Research progress'));
      await tester.tap(find.text('Research progress'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Current 0.238 / Candidate 0.226 / Market 0.213'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
