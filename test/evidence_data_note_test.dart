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
  Finder sourceScroll() => find
      .descendant(
        of: find.byKey(const Key('evidence-source-list')),
        matching: find.byType(Scrollable),
      )
      .first;
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

  test(
    'per-source provenance keeps differing coverage and null dates independent',
    () {
      final raw = contextJson()
        ..['cutoff'] = '2026-11-14'
        ..['retrievedAt'] = '2026-11-15T10:00:00Z'
        ..['provenance'] = {
          'snaps': {
            'sourceUrl': 'https://example.com/new-snaps.csv',
            'cutoff': '2026-11-09',
            'retrievedAt': '2026-11-14T10:00:00Z',
            'season': 2026,
            'throughWeek': 9,
            'status': 'fresh',
            'rowCount': 2500,
          },
          'injuries': {
            'sourceUrl': 'https://example.com/new-injuries.csv',
            'cutoff': null,
            'retrievedAt': '2026-11-13T10:00:00Z',
            'season': 2025,
            'throughWeek': 18,
            'status': 'undated',
          },
        };
      final context = MatchupContext.fromJson(raw);
      expect(context.snapEvidence.cutoff, DateTime.utc(2026, 11, 9));
      expect(context.snapEvidence.retrievedAt, DateTime.utc(2026, 11, 14, 10));
      expect(
        context.snapEvidence.sourceUrl,
        'https://example.com/new-snaps.csv',
      );
      expect(context.snapEvidence.rowCount, 2500);
      expect(context.injuryEvidence.cutoff, isNull);
      expect(
        context.injuryEvidence.retrievedAt,
        DateTime.utc(2026, 11, 13, 10),
      );
      expect(context.injuryEvidence.season, 2025);
      expect(context.injuryEvidence.throughWeek, 18);
      expect(context.injuryEvidence.status, 'undated');
      expect(context.injuryEvidence.refreshFailed, isFalse);
    },
  );

  test('present malformed source metadata stays unknown instead of using legacy dates', () {
    final raw = contextJson()
      ..['cutoff'] = '2026-11-14'
      ..['retrievedAt'] = '2026-11-15T10:00:00Z'
      ..['provenance'] = {
        'snaps': {
          'cutoff': '2026-02-31',
          'retrievedAt': '2026-11-15T12:00:00',
          'sourceUrl': 'javascript:alert(1)',
          'season': 9000,
          'throughWeek': 999,
          'status': 'live',
          'rowCount': -1,
          'sha256': 'not-a-hash',
        },
        'injuries': null,
      };
    final context = MatchupContext.fromJson(raw);
    for (final source in [context.snapEvidence, context.injuryEvidence]) {
      expect(source.cutoff, isNull);
      expect(source.retrievedAt, isNull);
      expect(source.sourceUrl, isNull);
      expect(source.season, isNull);
      expect(source.throughWeek, isNull);
      expect(source.status, isNull);
      expect(source.rowCount, isNull);
      expect(source.sha256, isNull);
    }
    raw['provenance'] = {'snaps': {}};
    final legacyInjuries = MatchupContext.fromJson(raw).injuryEvidence;
    expect(legacyInjuries.cutoff, DateTime.utc(2026, 11, 14));
    expect(legacyInjuries.throughWeek, 10);
  });

  Future<void> openNote(
    WidgetTester tester, {
    Map<String, dynamic>? boxScores,
    MatchupContext? matchup,
    InjuryReport? injuries,
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: edgeTheme(),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: EvidenceDataNote(
              now: now,
              boxScores: boxScores,
              matchup: matchup,
              injuries: injuries,
            ),
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
        scrollable: sourceScroll(),
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

  testWidgets(
    'retained injury evidence keeps its old dates and shows the failed refresh',
    (tester) async {
      final raw = contextJson()
        ..['provenance'] = {
          'snaps': {
            'season': 2026,
            'throughWeek': 9,
            'cutoff': '2026-11-09',
            'retrievedAt': '2026-11-15T10:00:00Z',
            'status': 'fresh',
          },
          'injuries': {
            'season': 2026,
            'throughWeek': 8,
            'cutoff': '2026-10-30',
            'retrievedAt': '2026-10-31T10:00:00Z',
            'status': 'retained',
            'lastAttemptAt': '2026-11-15T11:00:00Z',
            'error': 'source_unavailable',
          },
        };
      final context = MatchupContext.fromJson(raw);
      expect(context.injuryEvidence.refreshFailed, isTrue);
      expect(
        context.injuryEvidence.retrievedAt,
        DateTime.utc(2026, 10, 31, 10),
      );
      await openNote(tester, matchup: context, textScale: 1.8);
      expect(find.textContaining('refresh incomplete'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('recorded through Week 9'),
        200,
        scrollable: sourceScroll(),
      );
      expect(
        find.textContaining('6 days before the research date'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.textContaining('Previous records retained'),
        200,
        scrollable: sourceScroll(),
      );
      expect(
        find.textContaining('16 days before the research date'),
        findsOneWidget,
      );
      expect(find.textContaining('Retrieved Oct 31'), findsOneWidget);
      expect(find.textContaining('Last attempt Nov 15'), findsOneWidget);
      expect(tester.takeException(), isNull);
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
      scrollable: sourceScroll(),
    );
    expect(find.textContaining('at least 24 hours old'), findsOneWidget);
    expect(find.textContaining('Box-score cutoff unknown'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
