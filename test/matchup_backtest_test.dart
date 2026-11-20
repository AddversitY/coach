import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/hit_rate.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/prop_projection.dart';
import 'package:odds_edge/domain/prop_report.dart';
import 'package:odds_edge/domain/unit_ratings.dart';

void main() {
  test('matchup adjustment stays off unless the holdout is strictly better', () {
    final decoded = jsonDecode(
      File('assets/nfl-player-stats.json').readAsStringSync().replaceFirst('\uFEFF', ''),
    ) as Map<String, dynamic>;
    final rows = PlayerStatsDataset.fromJson(decoded).rows;
    final index = UsageIndex.build(rows);
    final book = RatingBook.build(rows);
    final base = _score(rows: rows, index: index, book: book, weight: null);
    final candidates = <double, Map<int, _Score>>{};
    for (final weight in [0.0, 0.25, 0.5]) {
      candidates[weight] = _score(
        rows: rows,
        index: index,
        book: book,
        weight: weight,
      );
    }
    var adopted = false;
    for (final weight in candidates.keys) {
      final tune = candidates[weight]![2025]!;
      final hold = candidates[weight]![2026]!;
      final wins = tune.n >= 1000 &&
          hold.n >= 1000 &&
          tune.brier < base[2025]!.brier &&
          tune.logLoss < base[2025]!.logLoss &&
          hold.brier < base[2026]!.brier &&
          hold.logLoss < base[2026]!.logLoss;
      if (wins) adopted = true;
    }
    // ignore: avoid_print
    print(
      'base 2025 n=${base[2025]!.n} brier=${base[2025]!.brier.toStringAsFixed(4)} '
      'log=${base[2025]!.logLoss.toStringAsFixed(4)} '
      '2026 n=${base[2026]!.n} brier=${base[2026]!.brier.toStringAsFixed(4)} '
      'log=${base[2026]!.logLoss.toStringAsFixed(4)}',
    );
    for (final weight in candidates.keys) {
      final tune = candidates[weight]![2025]!;
      final hold = candidates[weight]![2026]!;
      // ignore: avoid_print
      print(
        'weight $weight 2025 n=${tune.n} brier=${tune.brier.toStringAsFixed(4)} '
        'log=${tune.logLoss.toStringAsFixed(4)} '
        '2026 n=${hold.n} brier=${hold.brier.toStringAsFixed(4)} '
        'log=${hold.logLoss.toStringAsFixed(4)}',
      );
    }
    expect(base[2026]!.n, greaterThanOrEqualTo(1000));
    expect(adopted, matchupAdjustmentAdopted);
  });
}

class _Score {
  int n = 0;
  double brier = 0;
  double logLoss = 0;
}

Map<int, _Score> _score({
  required List<PlayerGame> rows,
  required UsageIndex index,
  required RatingBook book,
  required double? weight,
}) {
  final scores = <int, _Score>{2025: _Score(), 2026: _Score()};
  for (final metric in propReportMetrics) {
    final games = <String, List<PlayerGame>>{};
    for (final game in rows) {
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
        if (line < (propReportMinimumLine[metric] ?? 0)) continue;
        final history = <PlayerGame>[
          for (final earlier in seasons.take(indexSeason)) ...bySeason[earlier]!,
        ];
        final weeks = <int, List<PlayerGame>>{};
        for (final game in bySeason[season]!) {
          (weeks[game.week] ??= []).add(game);
        }
        for (final week in (weeks.keys.toList()..sort())) {
          for (final game in weeks[week]!) {
            if (game.stats[metric]!.toDouble() == line) continue;
            final env = weight == null
                ? null
                : matchupEnvironment(
                    book: book,
                    playerGames: history,
                    metric: metric,
                    opponent: game.opponent,
                    beforeSeason: season,
                    beforeWeek: week,
                    recencyWeight: weight,
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
              environment: env != null && env.known ? env : null,
            );
            final chance = projection?.chance;
            if (chance == null) continue;
            final hit = game.stats[metric]!.toDouble() > line;
            final board = scores[season]!;
            final p = chance.clamp(1e-4, 1 - 1e-4);
            board.n++;
            board.brier += (p - (hit ? 1 : 0)) * (p - (hit ? 1 : 0));
            board.logLoss += -(hit ? math.log(p) : math.log(1 - p));
          }
          history.addAll(weeks[week]!);
        }
      }
    }
  }
  for (final board in scores.values) {
    if (board.n == 0) continue;
    board.brier /= board.n;
    board.logLoss /= board.n;
  }
  return scores;
}
