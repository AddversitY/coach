import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/history.dart';
import 'package:odds_edge/domain/hit_rate.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/prop_chance.dart';
import 'package:odds_edge/domain/prop_context.dart';
import 'package:odds_edge/domain/prop_projection.dart';
import 'package:odds_edge/domain/prop_specialist.dart';
import 'package:odds_edge/domain/unit_ratings.dart';

/// Writes the served prop chance for each saved close.
///
/// Run with EXPORT_SCORECARD=1. The ordinary suite skips the file write.
/// The chance is the one the card serves when a real no-vig price exists:
/// the lognormal projection with recency weighting, pooled slightly toward
/// that price. A player the projection cannot score is left out.
void main() {
  test('export served prop chances', () {
    if (Platform.environment['EXPORT_SCORECARD'] != '1') return;
    final players = PlayerStatsDataset.fromJson(_json('assets/nfl-player-stats.json')).rows;
    final byPlayer = <String, List<PlayerGame>>{};
    for (final game in players) {
      (byPlayer[game.playerId] ??= []).add(game);
    }
    final history = [
      for (final row in _json('assets/nfl-history.json')['games'] as List)
        if (row is Map) HistoricalGame.fromJson(Map<String, dynamic>.from(row)),
    ];
    final usage = UsageBook.fromJson(_json('assets/prop-usage.json'));
    final index = UsageIndex.build(players, scores: history);
    final ratings = RatingBook.build(players);
    final spreads = PositionSpread(players);
    final scripts = ScriptBook(history);
    final rows = [
      for (final row in _json('assets/prop-closes.json')['rows'] as List)
        Map<String, dynamic>.from(row as Map),
    ];
    final chances = <Map<String, Object?>>[];
    for (final row in rows) {
      if (row['season'] != 2026 || row['metric'] == 'anytime_td') continue;
      final metric = row['metric'];
      final line = row['line'];
      final close = row['prior'];
      if (metric is! String || line is! num || close is! num) continue;
      if (close <= 0 || close >= 1) continue;
      final season = row['season'] as int;
      final week = row['week'] as int;
      final id = '${row['playerId']}';
      final env = matchupEnvironment(
        book: ratings,
        playerGames: byPlayer[id] ?? const [],
        metric: metric,
        opponent: '${row['opponent']}',
        beforeSeason: season,
        beforeWeek: week,
        recencyWeight: matchupRecencyWeight,
      );
      final served = projectProp(
        index: index,
        playerId: id,
        metric: metric,
        line: line.toDouble(),
        side: LineSide.over,
        beforeSeason: season,
        beforeWeek: week,
        team: '${row['team']}',
        opponent: '${row['opponent']}',
        market: close.toDouble(),
        environment: env.known ? env : null,
        lognormalYards: true,
        tune: servedPropTune,
        spreads: spreads,
        scripts: scripts,
        shareBook: usage,
        marketWeight: propModelWeight,
      );
      final chance = served?.chance;
      if (chance == null || chance <= 0 || chance >= 1) continue;
      chances.add({
        'season': season,
        'week': week,
        'playerId': id,
        'metric': metric,
        'line': line.toDouble(),
        'coach': double.parse(chance.toStringAsFixed(6)),
      });
    }
    File('assets/prop-served-chances.json').writeAsStringSync(
      '${jsonEncode({
        'schema': 'coach-prop-served-chances-v1',
        'notice': 'Served prop chance at the saved no-vig close. A missing player is omitted. This is not a pick.',
        'rows': chances,
      })}\n',
    );
    expect(chances, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 20)));
}

Map<String, dynamic> _json(String path) {
  return jsonDecode(File(path).readAsStringSync().replaceFirst('\uFEFF', ''))
      as Map<String, dynamic>;
}
