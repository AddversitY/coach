import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/coach/coach_evidence_visuals.dart';
import 'package:odds_edge/theme/coach_theme.dart';

void main() {
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
