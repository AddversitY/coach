import 'dart:convert';
import 'dart:io';

import 'package:odds_edge/domain/history.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/playing_time_eval.dart';
import 'package:odds_edge/domain/prop_context.dart';

/// Week-by-week score of the playing-time layer against the current card.
///
/// From the repository root:
/// `flutter test test/playing_time_test.dart --name walk-forward`
///
/// Prints Brier, log loss, and projection error for 2024, 2025, and 2026.
/// 2024 is context. The card changes only when 2025 and 2026 both improve.
void main() {
  final report = scorePlayingTime(
    players: _players(),
    scores: _history(),
    shares: UsageBook.fromJson(_json('assets/prop-usage.json')),
    outs: [
      for (final row in (_json('assets/nfl-outs.json')['outs'] as List))
        if (row is List) List<dynamic>.from(row),
    ],
  );
  stdout.writeln(report.text);
}

List<PlayerGame> _players() {
  return PlayerStatsDataset.fromJson(_json('assets/nfl-player-stats.json'))
      .rows;
}

List<HistoricalGame> _history() {
  final games = _json('assets/nfl-history.json')['games'];
  if (games is! List) return const [];
  return [
    for (final row in games)
      if (row is Map) HistoricalGame.fromJson(Map<String, dynamic>.from(row)),
  ];
}

Map<String, dynamic> _json(String path) {
  return jsonDecode(File(path).readAsStringSync().replaceFirst('\uFEFF', ''))
      as Map<String, dynamic>;
}
