import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/history.dart';
import 'package:odds_edge/domain/hit_rate.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/price_history.dart';
import 'package:odds_edge/domain/prop_projection.dart';
import 'package:odds_edge/domain/prop_report.dart';
import 'package:odds_edge/domain/unit_ratings.dart';

/// Prints the priced-path comparison. The served choice is set from this
/// output in docs/MATCHUPS.md. The test fails if a recorded winner is not
/// the one the app serves.
void main() {
  test('priced matchup paths are scored against closing game lines', () {
    final players = PlayerStatsDataset.fromJson(
      jsonDecode(
        File('assets/nfl-player-stats.json')
            .readAsStringSync()
            .replaceFirst('\uFEFF', ''),
      ) as Map<String, dynamic>,
    ).rows;
    final history = _history();
    final index = UsageIndex.build(players, scores: history);
    final book = RatingBook.build(players);
    final lines = _lines(history);
    final prices = _prices();
    final modes = <String, Map<int, _Board>>{
      for (final mode in ['stacked', 'sensitivity', 'unit', 'noprice'])
        mode: _score(
          rows: players,
          index: index,
          book: book,
          lines: lines,
          prices: prices,
          mode: mode,
        ),
    };
    for (final metric in propCloseMarkets.values) {
      // ignore: avoid_print
      print(
        'close-gate $metric saved=${prices.closesFor(metric)} need=$savedCloseGate',
      );
    }
    for (final mode in modes.keys) {
      for (final season in [2025, 2026]) {
        final board = modes[mode]![season]!;
        // ignore: avoid_print
        print(
          '$mode $season n=${board.n} brier=${board.brier.toStringAsFixed(4)} '
          'log=${board.logLoss.toStringAsFixed(4)} '
          'predOver=${board.predictedOver.toStringAsFixed(3)} '
          'actualOver=${board.actualOver.toStringAsFixed(3)} '
          'meanOverLine=${board.meanRatio.toStringAsFixed(3)} '
          'rawOverShare=${board.rawOver.toStringAsFixed(3)}',
        );
      }
    }
    final stacked2025 = modes['stacked']![2025]!;
    final stacked2026 = modes['stacked']![2026]!;
    final unit2025 = modes['unit']![2025]!;
    final unit2026 = modes['unit']![2026]!;
    final plain2025 = modes['noprice']![2025]!;
    final plain2026 = modes['noprice']![2026]!;
    expect(stacked2026.n, greaterThanOrEqualTo(1000));
    bool better(_Board left, _Board right) =>
        left.n >= 1000 &&
        left.brier < right.brier &&
        left.logLoss < right.logLoss;
    final plainWins =
        better(plain2025, stacked2025) &&
        better(plain2026, stacked2026) &&
        better(plain2025, unit2025) &&
        better(plain2026, unit2026);
    expect(
      pricedPathDropsStackedScales,
      plainWins,
      reason: 'The served priced path has to match this fair-line result.',
    );
  });
}

Map<String, ({double spread, double total})> _lines(
  List<HistoricalGame> games,
) {
  final lines = <String, ({double spread, double total})>{};
  for (final game in games) {
    final spread = game.spreadLine;
    final total = game.totalLine;
    if (spread == null || total == null) continue;
    lines['${game.season}|${game.week}|${game.home}'] = (
      spread: -spread,
      total: total,
    );
    lines['${game.season}|${game.week}|${game.away}'] = (
      spread: spread,
      total: total,
    );
  }
  return lines;
}

PriceHistory _prices() {
  final file = File('assets/price-history.json');
  if (!file.existsSync()) return const PriceHistory(observations: [], closes: []);
  final decoded = jsonDecode(file.readAsStringSync().replaceFirst('\uFEFF', ''));
  if (decoded is! Map) return const PriceHistory(observations: [], closes: []);
  return PriceHistory.fromJson(Map<String, dynamic>.from(decoded));
}

List<HistoricalGame> _history() {
  final decoded = jsonDecode(
    File('assets/nfl-history.json')
        .readAsStringSync()
        .replaceFirst('\uFEFF', ''),
  ) as Map<String, dynamic>;
  return [
    for (final row in decoded['games'] as List)
      HistoricalGame.fromJson(Map<String, dynamic>.from(row as Map)),
  ];
}

class _Board {
  int n = 0;
  double brier = 0;
  double logLoss = 0;
  double predictedOver = 0;
  double actualOver = 0;
  double meanRatio = 0;
  double rawOver = 0;
}

Map<int, _Board> _score({
  required List<PlayerGame> rows,
  required UsageIndex index,
  required RatingBook book,
  required Map<String, ({double spread, double total})> lines,
  required PriceHistory prices,
  required String mode,
}) {
  final scores = <int, _Board>{2025: _Board(), 2026: _Board()};
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
        final median = values[values.length ~/ 2];
        final marketKey = propCloseMarkets[metric];
        final closes = marketKey == null ? 0 : prices.closesFor(marketKey);
        if (median < (propReportMinimumLine[metric] ?? 0)) continue;
        final history = <PlayerGame>[
          for (final earlier in seasons.take(indexSeason))
            ...bySeason[earlier]!,
        ];
        final weeks = <int, List<PlayerGame>>{};
        for (final game in bySeason[season]!) {
          (weeks[game.week] ??= []).add(game);
        }
        for (final week in (weeks.keys.toList()..sort())) {
          for (final game in weeks[week]!) {
            final stored = marketKey == null
                ? null
                : prices.closeLine(
                    market: marketKey,
                    season: season,
                    week: week,
                    team: game.team,
                    player: game.name,
                  );
            final line = walkForwardTestLine(
              median: median,
              close: stored,
              closesForMarket: closes,
            );
            final value = game.stats[metric]!.toDouble();
            if (value == line) continue;
            final closing = lines['${game.season}|${game.week}|${game.team}'];
            if (closing == null && mode != 'noprice') continue;
            final env = mode == 'stacked'
                ? null
                : matchupEnvironment(
                    book: book,
                    playerGames: history,
                    metric: metric,
                    opponent: game.opponent,
                    beforeSeason: season,
                    beforeWeek: week,
                    recencyWeight: matchupRecencyWeight,
                  ).copyWith(priceUnit: mode == 'unit');
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
              teamSpread: mode == 'noprice' ? null : closing?.spread,
              total: mode == 'noprice' ? null : closing?.total,
              market: propReportMarketProxy,
              environment: env != null && env.known ? env : null,
            );
            final chance = projection?.chance;
            final raw = projection?.rawChance;
            final mean = projection?.mean;
            if (chance == null || raw == null || mean == null || line <= 0) {
              continue;
            }
            final hit = value > line;
            final board = scores[season]!;
            final p = chance.clamp(1e-4, 1 - 1e-4);
            board.n++;
            board.brier += (p - (hit ? 1 : 0)) * (p - (hit ? 1 : 0));
            board.logLoss += -(hit ? math.log(p) : math.log(1 - p));
            board.predictedOver += p;
            if (hit) board.actualOver += 1;
            board.meanRatio += mean / line;
            if (raw > 0.5) board.rawOver += 1;
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
    board.predictedOver /= board.n;
    board.actualOver /= board.n;
    board.meanRatio /= board.n;
    board.rawOver /= board.n;
  }
  return scores;
}
