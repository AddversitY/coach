import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../domain/elo_ratings.dart';
import '../domain/history.dart';
import '../domain/matchup.dart';
import '../domain/player_stats.dart';
import '../domain/play_units.dart';
import '../domain/line_movement.dart';
import '../domain/accuracy_scorecard.dart';
import '../domain/price_history.dart';
import '../domain/recent_evidence.dart';
import '../domain/prop_context.dart';
import '../domain/trades.dart';

/// `compute` never replies while a widget test holds the root isolate.
bool get _decodeInline {
  if (kIsWeb) return false;
  return WidgetsBinding.instance.runtimeType.toString().contains('Test');
}

Future<PlayerStatsDataset> loadBundledNflPlayers() async {
  final json = await rootBundle.loadString('assets/nfl-player-stats.json');
  if (_decodeInline) return _decodeNflPlayers(json);
  return compute(_decodeNflPlayers, json);
}

PlayerStatsDataset _decodeNflPlayers(String json) =>
    PlayerStatsDataset.fromJson(
      Map<String, dynamic>.from(jsonDecode(json.replaceFirst('\uFEFF', ''))),
    );

Future<MatchupContext> loadBundledMatchup() async {
  final json = await rootBundle.loadString('assets/nfl-matchup.json');
  if (_decodeInline) return _decodeMatchup(json);
  return compute(_decodeMatchup, json);
}

MatchupContext _decodeMatchup(String json) => MatchupContext.fromJson(
  Map<String, dynamic>.from(jsonDecode(json.replaceFirst('\uFEFF', ''))),
);

Future<SelfGradeReport> loadBundledSelfGrade() async {
  final json = await rootBundle.loadString('assets/self-grade.json');
  final decoded = jsonDecode(json.replaceFirst('\uFEFF', ''));
  if (decoded is! Map) return SelfGradeReport.empty;
  return SelfGradeReport.fromJson(Map<String, dynamic>.from(decoded));
}

Future<BookPriceCoverage> loadBundledBookPrices() async {
  final json = await rootBundle.loadString('assets/book-price-coverage.json');
  final decoded = jsonDecode(json.replaceFirst('\uFEFF', ''));
  if (decoded is! Map) return BookPriceCoverage.empty;
  return BookPriceCoverage.fromJson(Map<String, dynamic>.from(decoded));
}

Future<AccuracyScorecard> loadBundledAccuracyScorecard() async {
  final json = await rootBundle.loadString('assets/accuracy-scorecard.json');
  final decoded = jsonDecode(json.replaceFirst('\uFEFF', ''));
  if (decoded is! Map) return AccuracyScorecard.empty;
  return AccuracyScorecard.fromJson(Map<String, dynamic>.from(decoded));
}

Future<LineMoveBook> loadBundledLineMoves() async {
  final json = await rootBundle.loadString('assets/line-moves.json');
  final decoded = jsonDecode(json.replaceFirst('\uFEFF', ''));
  if (decoded is! Map) return LineMoveBook.empty;
  return LineMoveBook.fromJson(Map<String, dynamic>.from(decoded));
}

Future<RecentEvidence> loadBundledRecentEvidence() async {
  final json = await rootBundle.loadString('assets/nfl-recent-evidence.json');
  if (_decodeInline) return _decodeRecent(json);
  return compute(_decodeRecent, json);
}

RecentEvidence _decodeRecent(String json) => RecentEvidence.fromJson(
  Map<String, dynamic>.from(jsonDecode(json.replaceFirst('\uFEFF', ''))),
);

Future<PlayBook> loadBundledPlayUnits() async {
  final json = await rootBundle.loadString('assets/play-units.json');
  if (_decodeInline) return _decodePlayUnits(json);
  return compute(_decodePlayUnits, json);
}

PlayBook _decodePlayUnits(String json) => PlayBook.fromJson(
  Map<String, dynamic>.from(jsonDecode(json.replaceFirst('\uFEFF', ''))),
);

/// Coach ratings (Elo). Extra context only; never part of a chance.
Future<EloRatings> loadBundledEloRatings() async {
  final json = await rootBundle.loadString('assets/elo-ratings.json');
  final decoded = jsonDecode(json.replaceFirst('\uFEFF', ''));
  if (decoded is! Map) return EloRatings.empty;
  final merged = Map<String, dynamic>.from(decoded);
  // Backups stepping in (tools/backup_watch.py). Missing or broken stays out.
  try {
    final watch = jsonDecode(
      (await rootBundle.loadString(
        'assets/backup-watch.json',
      )).replaceFirst('\uFEFF', ''),
    );
    if (watch is Map && watch['current'] is List) {
      merged['backupWatch'] = watch['current'];
    }
  } catch (_) {
    // No backup watch file: the ratings still load.
  }
  return EloRatings.fromJson(merged);
}

Future<TradeBook> loadBundledTrades() async {
  final json = await rootBundle.loadString('assets/nfl-trades.json');
  final decoded = jsonDecode(json.replaceFirst('\uFEFF', ''));
  if (decoded is! Map) return TradeBook.empty;
  return TradeBook.fromJson(Map<String, dynamic>.from(decoded));
}

Future<List<HistoricalGame>> loadBundledHistoryGames() async {
  final json = await rootBundle.loadString('assets/nfl-history.json');
  if (_decodeInline) return _decodeHistory(json);
  return compute(_decodeHistory, json);
}

Future<UsageBook> loadBundledPropUsage() async {
  final json = await rootBundle.loadString('assets/prop-usage.json');
  final decoded = jsonDecode(json.replaceFirst('\uFEFF', ''));
  if (decoded is! Map) return UsageBook.fromJson(const {});
  return UsageBook.fromJson(Map<String, dynamic>.from(decoded));
}

List<HistoricalGame> _decodeHistory(String json) {
  final decoded = jsonDecode(json.replaceFirst('\uFEFF', ''));
  if (decoded is! Map) return const [];
  final games = decoded['games'];
  if (games is! List) return const [];
  return [
    for (final row in games)
      if (row is Map) HistoricalGame.fromJson(Map<String, dynamic>.from(row)),
  ];
}
