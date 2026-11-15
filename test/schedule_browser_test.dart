import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/odds.dart';
import 'package:odds_edge/theme/edge_theme.dart';
import 'package:odds_edge/ui/schedule_browser.dart';

void main() {
  final now = DateTime.utc(2026, 11, 14, 12);
  final events = [
    SportEvent(
      'past',
      'Chicago Bears',
      'Green Bay Packers',
      now.subtract(const Duration(hours: 1)),
    ),
    SportEvent(
      'early',
      'Buffalo Bills',
      'Kansas City Chiefs',
      DateTime.utc(2026, 11, 15, 18),
    ),
    // Monday in UTC is still Sunday in the NFL's Eastern calendar.
    SportEvent(
      'late',
      'Philadelphia Eagles',
      'Dallas Cowboys',
      DateTime.utc(2026, 11, 16, 1, 20),
    ),
    SportEvent(
      'monday',
      'New England Patriots',
      'New York Jets',
      DateTime.utc(2026, 11, 16, 18),
    ),
  ];

  Widget frame({
    List<SportEvent>? rows,
    bool ready = true,
    double scale = 1,
    ValueChanged<String>? onOpen,
  }) => MaterialApp(
    theme: edgeTheme(),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ScheduleBrowser(
              events: rows ?? events,
              now: now,
              sourceReady: ready,
              onOpenGame: onOpen,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'Eastern game-day filtering excludes expired games and opens the correct fixture',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? opened;
      await tester.pumpWidget(frame(onOpen: (id) => opened = id));
      expect(find.text('Sunday, Nov 15'), findsOneWidget);
      expect(find.text('Monday, Nov 16'), findsOneWidget);
      expect(find.byKey(const ValueKey('schedule-game-past')), findsNothing);
      expect(find.text('3 upcoming games · all times ET'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('schedule-day-2026-11-16')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('schedule-game-late')), findsNothing);
      expect(
        find.byKey(const ValueKey('schedule-game-monday')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('schedule-game-monday')));
      expect(opened, 'monday');
      await tester.tap(find.byKey(const Key('schedule-day-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('schedule-game-late')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('schedule uses two columns on desktop and one on a phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(frame());
    final early = find.byKey(const ValueKey('schedule-game-early'));
    final late = find.byKey(const ValueKey('schedule-game-late'));
    expect(tester.getTopLeft(early).dy, tester.getTopLeft(late).dy);
    expect(
      tester.getTopLeft(late).dx,
      greaterThan(tester.getTopLeft(early).dx),
    );
    await tester.binding.setSurfaceSize(const Size(390, 1600));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(late).dy,
      greaterThan(tester.getTopLeft(early).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'phone schedule supports enlarged text and truthful empty states',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(frame(scale: 1.8));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(frame(ready: false));
      expect(find.text('Schedule not loaded'), findsOneWidget);
      expect(find.textContaining('upcoming games ·'), findsNothing);
      await tester.pumpWidget(frame(rows: [events.first]));
      expect(find.text('No upcoming games'), findsOneWidget);
      expect(find.byKey(const ValueKey('schedule-game-past')), findsNothing);
    },
  );

  testWidgets('an expired selected day returns to the available schedule', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(frame());
    await tester.tap(find.byKey(const ValueKey('schedule-day-2026-11-16')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      frame(rows: events.where((event) => event.id != 'monday').toList()),
    );
    expect(find.byKey(const ValueKey('schedule-game-early')), findsOneWidget);
    expect(find.text('2 upcoming games · all times ET'), findsOneWidget);
  });
}
