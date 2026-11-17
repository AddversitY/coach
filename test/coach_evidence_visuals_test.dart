import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/coach/coach_evidence_visuals.dart';
import 'package:odds_edge/theme/coach_theme.dart';

void main() {
  testWidgets(
    'spread and total modes keep their own lines, including equality, and switching teams clears an unrelated spread',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final scoring = [
        {'date': '2026-11-08', 'label': '11-08', 'value': 24, 'secondary': 17},
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: coachTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: CoachEvidenceVisuals(
                data: {
                  'focus': 'team',
                  'teamMetric': 'margin',
                  'selectedTeam': 'Bills',
                  'teams': [
                    for (final team in ['Bills', 'Chiefs'])
                      {
                        'name': team,
                        'code': team,
                        'samples': scoring,
                        'series': [
                          {
                            'metric': 'scoring',
                            'label': 'Points scored & allowed',
                            'samples': scoring,
                          },
                          {
                            'metric': 'margin',
                            'label': 'Winning / losing margin',
                            'line': team == 'Bills' ? 3.5 : null,
                            'lineSource': 'Margin needed',
                            'samples': [
                              {
                                'date': '2026-11-08',
                                'label': '11-08',
                                'value': 7,
                              },
                            ],
                          },
                          {
                            'metric': 'total',
                            'label': 'Combined game score',
                            'line': 41.0,
                            'lineSource': 'Comparison total',
                            'samples': [
                              {
                                'date': '2026-11-08',
                                'label': '11-08',
                                'value': 41,
                              },
                            ],
                          },
                        ],
                      },
                  ],
                },
              ),
            ),
          ),
        ),
      );
      expect(find.text('Average margin'), findsOneWidget);
      expect(find.text('3.5'), findsOneWidget);
      expect(find.text('1 / 0 / 0'), findsOneWidget);
      await tester.tap(find.text('Chiefs'));
      await tester.pumpAndSettle();
      expect(find.text('3.5'), findsNothing);
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Combined game score').last);
      await tester.pumpAndSettle();
      expect(find.text('Average total'), findsOneWidget);
      expect(find.text('0 / 0 / 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'production keeps workload units separate and price observations retain both timestamps on a phone',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final stats = [
        for (var i = 0; i < 6; i++)
          {
            'date': '2026-11-${(i + 1).toString().padLeft(2, '0')}',
            'label': 'W${i + 1}',
            'value': i == 5 ? null : i + 2,
          },
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: coachTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: CoachEvidenceVisuals(
                data: {
                  'focus': 'player',
                  'players': [
                    {
                      'name': 'Receiver',
                      'metric': 'receiving_yards',
                      'line': 65.5,
                      'series': [
                        {
                          'metric': 'receiving_yards',
                          'label': 'Receiving yards',
                          'samples': stats,
                        },
                        {
                          'metric': 'targets',
                          'label': 'Targets',
                          'samples': stats,
                        },
                      ],
                    },
                  ],
                  'priceComparison': {
                    'checkedAt': '2026-11-17T12:00:00Z',
                    'selection': {
                      'eventId': 'g',
                      'market': 'player_reception_yds',
                      'participant': 'Receiver',
                      'outcome': 'Over',
                      'point': 65.5,
                      'period': 'full_game',
                      'rules': 'player_prop_unverified',
                    },
                    'offers': [
                      {
                        'book': 'Book A',
                        'decimal': 2.1,
                        'sourceAt': '2026-11-17T11:00:00Z',
                        'collectedAt': '2026-11-17T11:01:00Z',
                      },
                      {
                        'book': 'Book B',
                        'decimal': 1.91,
                        'sourceAt': '2026-11-17T11:02:00Z',
                        'collectedAt': '2026-11-17T11:03:00Z',
                      },
                    ],
                  },
                },
              ),
            ),
          ),
        ),
      );
      expect(find.text('Workload · Targets'), findsOneWidget);
      expect(find.text('Recent 3 · 2/3 recorded'), findsOneWidget);
      expect(find.text('Previous 3 · 3/3 recorded'), findsOneWidget);
      await tester.ensureVisible(find.text('Exact-selection prices'));
      await tester.pumpAndSettle();
      expect(find.text('Book A'), findsOneWidget);
      expect(find.text('+110'), findsOneWidget);
      expect(find.textContaining('Observed '), findsNWidgets(2));
      expect(find.textContaining('Saved '), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'negative production uses a diverging axis and remains inspectable',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: coachTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: CoachEvidenceVisuals(
                data: {
                  'focus': 'player',
                  'players': [
                    {
                      'name': 'Runner',
                      'metric': 'rushing_yards',
                      'series': [
                        {
                          'metric': 'rushing_yards',
                          'label': 'Rushing yards',
                          'samples': [
                            {'date': '2026-11-08', 'label': 'W10', 'value': -3},
                            {'date': '2026-11-12', 'label': 'W11', 'value': 20},
                          ],
                        },
                      ],
                    },
                  ],
                },
              ),
            ),
          ),
        ),
      );
      expect(find.text('-3'), findsWidgets);
      await tester.tap(find.text('View recorded values'));
      await tester.pumpAndSettle();
      expect(find.text('2026-11-08 · -3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  final samples = [
    {'date': '2026-11-01', 'label': 'W9', 'value': 0},
    {'date': '2026-11-08', 'label': 'W10', 'value': 80},
    {'date': '2026-11-12', 'label': 'W11', 'value': null},
  ];
  testWidgets(
    'phone prop chart keeps missing results separate and changing metric removes the old line',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: coachTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: CoachEvidenceVisuals(
                data: {
                  'focus': 'player',
                  'cutoff': '2026-11-12',
                  'players': [
                    {
                      'name': 'Recorded Receiver',
                      'metric': 'receiving_yards',
                      'line': 65.5,
                      'lineSource': 'Requested line',
                      'series': [
                        {
                          'metric': 'receiving_yards',
                          'label': 'Receiving yards',
                          'samples': samples,
                        },
                        {
                          'metric': 'receptions',
                          'label': 'Receptions',
                          'samples': [
                            {'date': '2026-11-08', 'label': 'W10', 'value': 5},
                          ],
                        },
                      ],
                    },
                  ],
                },
              ),
            ),
          ),
        ),
      );
      expect(find.text('Recorded Receiver'), findsOneWidget);
      expect(find.text('1 / 1 / 0'), findsOneWidget);
      expect(find.text('40.0'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Receptions').last);
      await tester.pumpAndSettle();
      expect(find.text('65.5'), findsNothing);
      expect(find.text('5.0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'team chart switches teams and fits large text without treating ties as losses',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: coachTheme(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: CoachEvidenceVisuals(
                  data: {
                    'focus': 'team',
                    'selectedTeam': 'Buffalo Bills',
                    'cutoff': '2026-11-12',
                    'teams': [
                      {
                        'name': 'Buffalo Bills',
                        'code': 'BUF',
                        'samples': [
                          {
                            'date': '2026-11-01',
                            'label': '11-01',
                            'opponent': 'Other',
                            'value': 24,
                            'secondary': 17,
                          },
                          {
                            'date': '2026-11-08',
                            'label': '11-08',
                            'opponent': 'Other',
                            'value': 20,
                            'secondary': 20,
                          },
                        ],
                      },
                      {
                        'name': 'Kansas City Chiefs',
                        'code': 'KC',
                        'samples': [],
                      },
                    ],
                  },
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('1W · 0L · 1T'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('KC'));
      await tester.pumpAndSettle();
      expect(find.text('Kansas City Chiefs'), findsOneWidget);
      expect(
        find.text('No recorded results available for this chart.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
