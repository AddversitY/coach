import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../domain/history.dart';
import '../domain/matchup.dart';
import '../domain/player_stats.dart';
import '../domain/play_units.dart';
import '../domain/recent_evidence.dart';

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

Future<List<HistoricalGame>> loadBundledHistoryGames() async {
  final json = await rootBundle.loadString('assets/nfl-history.json');
  if (_decodeInline) return _decodeHistory(json);
  return compute(_decodeHistory, json);
}

List<HistoricalGame> _decodeHistory(String json) {
  final decoded = jsonDecode(json.replaceFirst('\uFEFF', ''));
  if (decoded is! Map) return const [];
  final games = decoded['games'];
  if (games is! List) return const [];
  return [
    for (final row in games)
      if (row is Map)
        HistoricalGame.fromJson(Map<String, dynamic>.from(row)),
  ];
}
