import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/injury_report.dart';
import 'package:odds_edge/domain/matchup.dart';
import 'package:odds_edge/theme/edge_theme.dart';
import 'package:odds_edge/ui/evidence_data_note.dart';

void main() {
  final now = DateTime.utc(2026, 11, 15, 12);
  Map<String, dynamic> contextJson() => {
    'season': 2026,
    'sourceName': 'nflverse',
    'snapSource': 'https://example.com/snaps.csv',
    'injurySource': 'https://example.com/injuries.csv',
    'snaps': [
      {'week': 8},
      {'week': 9},
      {'week': 999},
    ],
    'injuries': [
      {'week': 10},
    ],
  };

  test('actual stored context preserves independent provenance without inventing dates', () {
    final raw = jsonDecode(
      File('assets/nfl-matchup.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final context = MatchupContext.fromJson(raw);
    expect(context.sourceName, 'nflverse');
    expect(context.reportedSeason, raw['season']);
    expect(context.snapThroughWeek, inInclusiveRange(1, 23));
    expect(context.injuryThroughWeek, inInclusiveRange(1, 23));
    expect(context.cutoff, parseEvidenceDay(raw['cutoff']));
    expect(context.retrievedAt, parseEvidenceTimestamp(raw['retrievedAt']));
    expect(context.snapSource, startsWith('https://github.com/nflverse/'));
  });

  test('missing or malformed provenance never falls back to a current date or inferred season', () {
    final raw = contextJson()
      ..remove('season')
      ..['cutoff'] = '2026-02-31'
      ..['retrievedAt'] = '2026-11-13T15:00:00'
      ..['snapSource'] = 'javascript:alert(1)';
    final context = MatchupContext.fromJson(raw);
    expect(
      context.season,
      2026,
      reason: 'Legacy calculation fallback stays compatible.',
    );
    expect(context.reportedSeason, isNull);
    expect(context.cutoff, isNull);
    expect(context.retrievedAt, isNull);
    expect(context.snapSource, isNull);
    expect(
      context.snapThroughWeek,
      9,
      reason: 'Invalid week 999 does not become coverage.',
    );
    expect(parseEvidenceDay('2026-11-09'), DateTime.utc(2026, 11, 9));
    expect(
      parseEvidenceTimestamp('2026-11-13T15:00:00-05:00'),
      DateTime.utc(2026, 11, 13, 20),
    );
    expect(parseEvidenceTimestamp('2026-02-31T15:00:00Z'), isNull);
    expect(parseEvidenceTimestamp('2026-11-13T25:00:00Z'), isNull);
  });

  Future<void> openNote(
    WidgetTester tester, {
    Map<String, dynamic>? boxScores,
    MatchupContext? matchup,
    InjuryReport? injuries,
  }) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: edgeTheme(),
        home: Scaffold(
          body: EvidenceDataNote(
            now: now,
            boxScores: boxScores,
            matchup: matchup,
            injuries: injuries,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('evidence-data-details')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'disclosure separates historical coverage, retrieval and stored context dates',
    (tester) async {
      await openNote(
        tester,
        boxScores: {
          'cutoff': '2026-10-01',
          'retrievedAt': '2026-11-15T10:00:00Z',
        },
        matchup: MatchupContext.fromJson(contextJson()),
      );
      expect(
        find.textContaining('45 days before the research date'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Retrieval time is separate from coverage'),
        findsOneWidget,
      );
      expect(find.textContaining('recorded through Week 9'), findsOneWidget);
      expect(
        find.textContaining('freshly checked schedule does not refresh'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('Stored injury context'),
        150,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.textContaining('recorded through Week 10'), findsOneWidget);
      expect(find.textContaining('Cutoff date unknown'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'future cutoff and retrieval metadata do not claim fresh evidence',
    (tester) async {
      await openNote(
        tester,
        boxScores: {
          'cutoff': '2026-11-16',
          'retrievedAt': '2026-11-16T10:00:00Z',
        },
      );
      expect(find.textContaining('after the research date'), findsOneWidget);
      expect(find.textContaining('freshness is unverified'), findsOneWidget);
      expect(
        find.textContaining('Box-score cutoff is after this research date'),
        findsOneWidget,
      );
    },
  );

  testWidgets('old availability is distinct from stored injury coverage', (
    tester,
  ) async {
    await openNote(
      tester,
      boxScores: const {},
      injuries: InjuryReport(
        fetchedAt: now.subtract(const Duration(hours: 25)),
        live: true,
        entries: const [],
        changes: const [],
        sources: const [],
        notice: '',
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Current availability'),
      150,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.textContaining('at least 24 hours old'), findsOneWidget);
    expect(find.textContaining('Box-score cutoff unknown'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
