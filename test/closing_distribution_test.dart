import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/closing_distribution.dart';

/// The served game number changes only when this result says so.
void main() {
  test('closing-line spots are scored on earlier weeks only', () {
    final decoded = jsonDecode(
      File('assets/closing-lines.json').readAsStringSync().replaceFirst('\uFEFF', ''),
    ) as Map<String, dynamic>;
    final games = [
      for (final row in decoded['games'] as List)
        ClosingGame.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
    final report = scoreClosingLines(games);
    for (final year in [2024, 2025, 2026]) {
      final season = report.seasons[year]!;
      final rows = {
        'cover flat': season.coverFlat,
        'cover price': season.coverPrice,
        'cover spot': season.coverSpot,
        'cover context': season.coverContext,
        'cover empirical': season.coverEmpirical,
        'total flat': season.totalFlat,
        'total price': season.totalPrice,
        'total spot': season.totalSpot,
        'total context': season.totalContext,
        'moneyline curve': season.moneylineCurve,
        'moneyline price': season.moneylinePrice,
        'moneyline spot': season.moneylineSpot,
      };
      for (final entry in rows.entries) {
        final board = entry.value;
        // ignore: avoid_print
        print(
          '$year ${entry.key} n=${board.n} '
          'brier=${board.brier.toStringAsFixed(4)} '
          'log=${board.logLoss.toStringAsFixed(4)}',
        );
      }
    }
    expect(games.length, greaterThan(2000));
    expect(report.seasons[2025]!.coverFlat.n, greaterThanOrEqualTo(250));
    expect(report.seasons[2026]!.coverFlat.n, greaterThanOrEqualTo(100));
    expect(report.spotCoversBeatCurrent, closingSpotOnCoversAdopted);
    expect(report.spotTotalsBeatCurrent, closingSpotOnTotalsAdopted);
    expect(report.moneylineModelBeatsPrice, closingMoneylineAdopted);
    expect(closingSpotOnCoversAdopted, isFalse);
    expect(closingSpotOnTotalsAdopted, isFalse);
    expect(closingMoneylineAdopted, isFalse);
  });
}
