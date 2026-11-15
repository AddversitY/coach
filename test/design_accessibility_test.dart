import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/theme/edge_theme.dart';
import 'package:odds_edge/ui/snapshot_source_bar.dart';
import 'package:odds_edge/ui/value_check.dart';

void main() {
  testWidgets('source details remains a labeled button with a 48px tap area', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: edgeTheme(),
          home: Scaffold(
            body: SnapshotSourceBar(
              published: false,
              loading: false,
              snapshot: null,
              error: null,
              now: DateTime.utc(2026, 11, 15),
              onSwitch: () {},
              onRefresh: () {},
            ),
          ),
        ),
      );
      final source = find.byKey(const Key('snapshot-source-details'));
      expect(tester.getSize(source).height, greaterThanOrEqualTo(48));
      final data = tester.getSemantics(source).getSemanticsData();
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.label, contains('About this data'));
      await tester.tap(source);
      await tester.pumpAndSettle();
      expect(find.text('About this preview'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'segments expose selection, meet 48px targets and expand with text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final semantics = tester.ensureSemantics();
      var index = 0;
      Widget frame(double scale) => MaterialApp(
        theme: edgeTheme(),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Padding(
                padding: const EdgeInsets.all(16),
                child: EdgeSegments(
                  labels: const ['Value', 'Recent', 'Pass'],
                  index: index,
                  onChanged: (next) => setState(() => index = next),
                ),
              ),
            ),
          ),
        ),
      );
      try {
        await tester.pumpWidget(frame(1));
        final value = find.byKey(const ValueKey('edge-segment-Value'));
        final recent = find.byKey(const ValueKey('edge-segment-Recent'));
        final normalHeight = tester.getSize(recent).height;
        expect(normalHeight, greaterThanOrEqualTo(48));
        expect(
          tester
              .getSemantics(value)
              .getSemanticsData()
              .flagsCollection
              .isSelected
              .toBoolOrNull(),
          isTrue,
        );
        await tester.tap(recent);
        await tester.pumpAndSettle();
        final data = tester.getSemantics(recent).getSemanticsData();
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.flagsCollection.isSelected.toBoolOrNull(), isTrue);
        expect(data.label, 'Recent');
        expect(
          tester
              .getSemantics(value)
              .getSemanticsData()
              .flagsCollection
              .isSelected
              .toBoolOrNull(),
          isFalse,
        );
        await tester.pumpWidget(frame(1.8));
        await tester.pumpAndSettle();
        expect(tester.getSize(recent).height, greaterThan(normalHeight));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
  double contrast(Color a, Color b) {
    final x = a.computeLuminance(), y = b.computeLuminance();
    return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
  }

  test(
    'interface and assessment text meet AA contrast on every reading surface',
    () {
      for (final ink in [
        EdgeColors.text,
        EdgeColors.textSecondary,
        EdgeColors.textTertiary,
        EdgeColors.accent,
        EdgeColors.good,
        EdgeColors.warn,
        EdgeColors.bad,
      ]) {
        for (final surface in [
          EdgeColors.background,
          EdgeColors.surface,
          EdgeColors.surfaceHigh,
        ]) {
          expect(
            contrast(ink, surface),
            greaterThanOrEqualTo(4.5),
            reason: '$ink on $surface',
          );
        }
      }
      expect(
        contrast(EdgeColors.onAccent, EdgeColors.accent),
        greaterThanOrEqualTo(4.5),
      );
    },
  );
}
