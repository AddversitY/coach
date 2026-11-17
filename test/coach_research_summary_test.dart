import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/coach/coach_research_summary.dart';
import 'package:odds_edge/theme/coach_theme.dart';

Map<String, dynamic> researchSummaryFixture() => {
  'summary': {
    'version': 'research-summary-v1',
    'primary': true,
    'action': 'pass',
    'hasEdge': false,
    'headline': 'Pass for now — key inputs need review',
    'text': 'Spread and total have comparable evidence. No single winner is forced.',
    'leadingMarkets': ['spreads', 'totals'],
    'reasons': ['Multiple books cover identical selections.'],
    'blockers': ['Refresh the saved prices.'],
    'followUps': [
      {
        'label': 'Inspect spread',
        'query': 'Analyze Buffalo Bills spread on 2026-11-19',
      },
    ],
    'notice': 'Coverage checks are not win probabilities.',
  },
  'options': [
    for (final market in ['spreads', 'totals', 'h2h', 'props'])
      {
        'market': market,
        'label': const {
          'spreads': 'Spread',
          'totals': 'Game total',
          'h2h': 'Moneyline',
          'props': 'Player props',
        }[market],
        'researchState': 'refresh_prices',
        'coverage': {'present': 3, 'total': 5},
        'books': 4,
        'equivalentSelections': 2,
        'criteria': [
          for (final key in ['paired', 'books', 'history', 'fresh', 'context'])
            {
              'id': key,
              'label': key,
              'state': ['fresh', 'context'].contains(key)
                  ? 'review'
                  : 'present',
            },
        ],
      },
  ],
};
void main() {
  testWidgets(
    'a phone shows all market checks and pass reasons without implying probability',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? query;
      await tester.pumpWidget(
        MaterialApp(
          theme: coachTheme(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: CoachResearchSummary(
                  comparison: researchSummaryFixture(),
                  onFollow: (value) => query = value,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('PASS / RESEARCH ONLY'), findsOneWidget);
      for (final label in [
        'Spread',
        'Game total',
        'Moneyline',
        'Player props',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(
        find.text('3/5 coverage checks observed · 4 matching books'),
        findsNWidgets(4),
      );
      expect(find.textContaining('%'), findsNothing);
      await tester.ensureVisible(find.text('Inspect spread'));
      await tester.tap(find.text('Inspect spread'));
      await tester.pumpAndSettle();
      expect(query, 'Analyze Buffalo Bills spread on 2026-11-19');
      expect(tester.takeException(), isNull);
    },
  );
}
