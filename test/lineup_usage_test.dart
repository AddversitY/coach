import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/hit_rate.dart';
import 'package:odds_edge/domain/lineup_usage.dart';
import 'package:odds_edge/domain/over_rate.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/prop_chance.dart';
import 'package:odds_edge/domain/prop_projection.dart';
import 'package:odds_edge/domain/prop_report.dart';
import 'package:odds_edge/domain/unit_ratings.dart';

void main() {
  test('an Out teammate moves the share, and a return pulls it back', () {
    final rows = <PlayerGame>[
      for (var week = 1; week <= 8; week++) ...[
        _game('a', 'Alex Wide', 'WR', week, targets: week == 8 ? 12 : 4),
        _game('b', 'Blake Wide', 'WR', week, targets: 8),
        _game('q', 'Quinn Passer', 'QB', week, attempts: 32),
      ],
    ];
    final out = LineupTape.build(rows, [
      [2025, 8, 'HOU', 'Blake Wide', 'WR'],
      [2025, 9, 'HOU', 'Blake Wide', 'WR'],
    ]);
    final boosted = out.move(
      playerId: 'a',
      metric: 'receiving_yards',
      team: 'HOU',
      season: 2025,
      week: 9,
    );
    expect(boosted.factor, greaterThan(1));
    expect(boosted.factor, lessThanOrEqualTo(1.35));
    expect(boosted.reason, contains('Blake Wide'));
    expect(boosted.reason, contains('listed Out'));
    expect(boosted.reason, contains('shrunk'));

    final back = LineupTape.build(rows, [
      [2025, 8, 'HOU', 'Blake Wide', 'WR'],
    ]).move(
      playerId: 'a',
      metric: 'receiving_yards',
      team: 'HOU',
      season: 2025,
      week: 9,
    );
    expect(back.factor, lessThan(1));
    expect(back.factor, greaterThanOrEqualTo(0.85));
    expect(back.reason, contains('not listed Out'));
    expect(back.reason, contains('no extra share'));
  });

  test('the shrunk lineup shift is scored on earlier weeks only', () {
    final decoded = jsonDecode(
      File('assets/nfl-player-stats.json').readAsStringSync().replaceFirst('\uFEFF', ''),
    ) as Map<String, dynamic>;
    final players = PlayerStatsDataset.fromJson(decoded).rows;
    final outs = jsonDecode(
      File('assets/nfl-outs.json').readAsStringSync().replaceFirst('\uFEFF', ''),
    ) as Map<String, dynamic>;
    final listed = [
      for (final row in outs['outs'] as List)
        List<dynamic>.from(row as List),
    ];
    final index = UsageIndex.build(players);
    final book = RatingBook.build(players);
    final forecasts = servedUnitForecasts(rows: players, index: index, book: book);
    final tape = LineupTape.build(players, listed);
    final served = {2025: _Board(), 2026: _Board()};
    final shifted = {2025: _Board(), 2026: _Board()};
    var moved = 0;
    for (final row in forecasts) {
      if (row.season != 2025 && row.season != 2026) continue;
      final move = tape.move(
        playerId: row.playerId,
        metric: row.metric,
        team: row.team,
        season: row.season,
        week: row.week,
      );
      if ((move.factor - 1).abs() > 0.005) moved++;
      served[row.season]!.add(_chance(row, 1), row.hit);
      shifted[row.season]!.add(_chance(row, move.factor), row.hit);
    }
    expect(served[2025]!.n, greaterThanOrEqualTo(1000));
    expect(served[2026]!.n, greaterThanOrEqualTo(1000));
    final beats = _better(shifted[2025]!, served[2025]!) &&
        _better(shifted[2026]!, served[2026]!);
    final lines = [
      for (final year in [2025, 2026])
        '$year served ${served[year]} shifted ${shifted[year]}',
      'moved $moved of ${forecasts.length}',
      'beats $beats adopted $lineupUsageAdopted',
    ];
    // ignore: avoid_print
    print(lines.join('\n'));
    expect(lineupUsageAdopted, beats, reason: lines.join('\n'));
  });
}

PlayerGame _game(
  String id,
  String name,
  String position,
  int week, {
  double targets = 0,
  double attempts = 0,
}) {
  return PlayerGame(
    playerId: id,
    name: name,
    position: position,
    team: 'HOU',
    opponent: 'IND',
    season: 2025,
    week: week,
    date: DateTime.utc(2025, 9, week),
    seasonType: 'REG',
    stats: {
      'targets': targets,
      'carries': 0,
      'attempts': attempts,
      'receiving_yards': targets * 8,
      'passing_yards': attempts * 7,
    },
  );
}

double _chance(ServedForecast row, double factor) {
  final raw = sideChance(
    metric: row.metric,
    mean: row.mean * factor,
    sd: row.sd,
    line: row.line,
    side: LineSide.over,
    lognormal: row.metric != 'receptions',
  );
  final shrunk =
      shrinkProjectedChance(
        projected: raw,
        observed: row.games,
        market: propReportMarketProxy,
      ) ??
      raw;
  return limitChanceGap(
    chance: shrunk,
    raw: raw,
    observed: row.games,
    market: propReportMarketProxy,
  );
}

class _Board {
  int n = 0;
  double brier = 0, logLoss = 0;

  void add(double chance, bool hit) {
    final p = chance.clamp(1e-4, 1 - 1e-4);
    final y = hit ? 1.0 : 0.0;
    n++;
    brier += (p - y) * (p - y);
    logLoss += -(y * math.log(p) + (1 - y) * math.log(1 - p));
  }

  double get meanBrier => n == 0 ? 1 : brier / n;
  double get meanLog => n == 0 ? 1 : logLoss / n;

  @override
  String toString() =>
      'n=$n brier=${meanBrier.toStringAsFixed(4)} log=${meanLog.toStringAsFixed(4)}';
}

bool _better(_Board left, _Board right) =>
    left.n >= 1000 &&
    right.n >= 1000 &&
    left.meanBrier < right.meanBrier &&
    left.meanLog < right.meanLog;

