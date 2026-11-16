import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/coach/coach_workspace.dart';
import 'package:odds_edge/data/published_snapshot.dart';
import 'package:odds_edge/domain/assistant.dart';
import 'package:odds_edge/domain/odds.dart';
import 'package:odds_edge/theme/coach_theme.dart';
import 'package:odds_edge/main.dart' as app;

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
  }) => MaterialApp(
    theme: coachTheme(),
    home: CoachWorkspace(
      snapshotLoader: loader ?? () async => snapshot(),
      playerLoader: () async => fixtureData(),
      clock: () => now,
      ask: ask,
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
}
