import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/hit_rate.dart';
import 'package:odds_edge/domain/history.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/play_units.dart';
import 'package:odds_edge/domain/prop_chance.dart';
import 'package:odds_edge/domain/prop_projection.dart';
import 'package:odds_edge/domain/prop_report.dart';
import 'package:odds_edge/domain/unit_ratings.dart';

/// Scores play-by-play rates as an extra multiplier on the served unit-only
/// prop chance. A rate is adopted only when Brier and log loss both improve
/// on 2025 and on 2026. The multiplier is fixed before the score: one step
/// moves the mean 15 percent, and it stays inside 0.85 to 1.15.
void main() {
  test('play-by-play unit rates are scored on earlier weeks only', () {
    final players = PlayerStatsDataset.fromJson(
      jsonDecode(
        File('assets/nfl-player-stats.json').readAsStringSync().replaceFirst('\uFEFF', ''),
      ) as Map<String, dynamic>,
    ).rows;
    final history = _history();
    final index = UsageIndex.build(players, scores: history);
    final book = RatingBook.build(players);
    final plays = PlayBook.fromJson(
      jsonDecode(File('assets/play-units.json').readAsStringSync()) as Map<String, dynamic>,
    );
    const features = ['epa', 'success', 'third', 'pressure', 'sack', 'proe', 'blend'];
    final boards = {
      for (final name in ['served', ...features])
        name: {2025: _Board(), 2026: _Board()},
    };
    for (final metric in propReportMetrics) {
      final games = <String, List<PlayerGame>>{};
      for (final game in players) {
        if (game.seasonType != 'REG' || game.stats[metric] == null) continue;
        (games[game.playerId] ??= []).add(game);
      }
      for (final ordered in games.values) {
        ordered.sort((a, b) {
          final season = a.season.compareTo(b.season);
          return season != 0 ? season : a.week.compareTo(b.week);
        });
        final bySeason = <int, List<PlayerGame>>{};
        for (final game in ordered) {
          (bySeason[game.season] ??= []).add(game);
        }
        final seasons = bySeason.keys.toList()..sort();
        for (var indexSeason = 1; indexSeason < seasons.length; indexSeason++) {
          final season = seasons[indexSeason];
          if (season != 2025 && season != 2026) continue;
          final previous = bySeason[seasons[indexSeason - 1]]!;
          if (previous.length < 4) continue;
          final values = [
            for (final game in previous) game.stats[metric]!.toDouble(),
          ]..sort();
          final line = values[values.length ~/ 2];
          if (line <= 0 || line < (propReportMinimumLine[metric] ?? 0)) continue;
          final seen = <PlayerGame>[
            for (final earlier in seasons.take(indexSeason)) ...bySeason[earlier]!,
          ];
          final weeks = <int, List<PlayerGame>>{};
          for (final game in bySeason[season]!) {
            (weeks[game.week] ??= []).add(game);
          }
          for (final week in (weeks.keys.toList()..sort())) {
            for (final game in weeks[week]!) {
              final value = game.stats[metric]!.toDouble();
              if (value == line) continue;
              final env = matchupEnvironment(
                book: book,
                playerGames: seen,
                metric: metric,
                opponent: game.opponent,
                beforeSeason: season,
                beforeWeek: week,
                recencyWeight: matchupRecencyWeight,
              );
              final projection = projectProp(
                index: index,
                playerId: game.playerId,
                metric: metric,
                line: line,
                side: LineSide.over,
                beforeSeason: season,
                beforeWeek: week,
                team: game.team,
                opponent: game.opponent,
                market: propReportMarketProxy,
                environment: env.known ? env : null,
              );
              final chance = projection?.chance;
              final mean = projection?.mean;
              final sd = projection?.sd;
              final played = projection?.games;
              if (chance == null || mean == null || sd == null || played == null) {
                continue;
              }
              final prior = plays.before(season: season, week: week);
              final hit = value > line;
              boards['served']![season]!.add(chance, hit);
              for (final feature in features) {
                final relative = playRelative(
                  feature,
                  prior.offense(game.opponent),
                  prior.defense(game.opponent),
                  prior.league,
                );
                final adjusted = sideChance(
                  metric: metric,
                  mean: mean * playMeanFactor(relative),
                  sd: sd,
                  line: line,
                  side: LineSide.over,
                );
                final shrunk = shrinkProjectedChance(
                  projected: adjusted,
                  observed: played,
                  market: propReportMarketProxy,
                );
                boards[feature]![season]!.add(shrunk ?? chance, hit);
              }
            }
            seen.addAll(weeks[week]!);
          }
        }
      }
    }
    for (final board in boards.values) {
      for (final season in board.values) {
        season.finish();
      }
    }
    String? winner;
    var best = double.infinity;
    for (final feature in features) {
      var wins = true;
      var sum = 0.0;
      for (final season in [2025, 2026]) {
        final model = boards[feature]![season]!;
        final served = boards['served']![season]!;
        // ignore: avoid_print
        print(
          '$feature $season n=${model.n} brier=${model.brier.toStringAsFixed(4)} '
          'log=${model.logLoss.toStringAsFixed(4)} pred=${model.pred.toStringAsFixed(3)} '
          'servedBrier=${served.brier.toStringAsFixed(4)} servedLog=${served.logLoss.toStringAsFixed(4)}',
        );
        sum += model.brier;
        if (model.n < 1000 ||
            model.brier >= served.brier ||
            model.logLoss >= served.logLoss) {
          wins = false;
        }
      }
      if (wins && sum < best) {
        best = sum;
        winner = feature;
      }
    }
    expect(playUnitOnPropsAdopted, winner != null);
    expect(servedPlayUnitFeature, winner ?? 'none');
  });
}

class _Board {
  int n = 0;
  double brier = 0, logLoss = 0, pred = 0, hits = 0;

  void add(double chance, bool hit) {
    final p = chance.clamp(1e-4, 1 - 1e-4);
    n++;
    brier += (p - (hit ? 1 : 0)) * (p - (hit ? 1 : 0));
    logLoss += -(hit ? math.log(p) : math.log(1 - p));
    pred += p;
  }

  void finish() {
    if (n == 0) return;
    brier /= n;
    logLoss /= n;
    pred /= n;
  }
}

List<HistoricalGame> _history() {
  final decoded = jsonDecode(
    File('assets/nfl-history.json').readAsStringSync().replaceFirst('\uFEFF', ''),
  ) as Map<String, dynamic>;
  return [
    for (final row in decoded['games'] as List)
      HistoricalGame.fromJson(Map<String, dynamic>.from(row as Map)),
  ];
}
