import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/history.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/prop_calibration.dart';
import 'package:odds_edge/domain/over_rate.dart';
import 'package:odds_edge/domain/prop_chance.dart';
import 'package:odds_edge/domain/prop_model.dart';
import 'package:odds_edge/domain/prop_projection.dart';
import 'package:odds_edge/domain/prop_report.dart';
import 'package:odds_edge/domain/unit_ratings.dart';

/// Scores ways to pull the over rate down toward the rate players actually
/// clear. A method is adopted only when Brier and log loss both improve
/// on 2025 and on 2026, against the served unit-only chance.
void main() {
  test('over-rate calibrations are scored on earlier weeks only', () {
    final players = PlayerStatsDataset.fromJson(
      jsonDecode(
        File('assets/nfl-player-stats.json').readAsStringSync().replaceFirst('\uFEFF', ''),
      ) as Map<String, dynamic>,
    ).rows;
    final history = _history();
    final index = UsageIndex.build(players, scores: history);
    final book = RatingBook.build(players);
    final events = [
      for (final row in servedUnitForecasts(rows: players, index: index, book: book))
        _Event(
          season: row.season,
          week: row.week,
          served: row.chance,
          raw: row.raw,
          games: row.games,
          lognormal: () {
            final raw = row.metric == 'receptions'
                ? row.raw
                : _lognormalOver(mean: row.mean, sd: row.sd, line: row.line);
            return shrinkProjectedChance(
                  projected: raw,
                  observed: row.games,
                  market: propReportMarketProxy,
                ) ??
                row.chance;
          }(),
          hit: row.hit,
        ),
    ];
    expect(events.where((row) => row.season == 2026).length, greaterThanOrEqualTo(1000));
    final names = ['served', 'lognormal', 'platt', 'shift', 'isotonic'];
    final boards = {
      for (final name in names) name: {2025: _Board(), 2026: _Board()},
    };
    final prior = <_Event>[];
    final weeks = <String, List<_Event>>{};
    for (final event in events) {
      (weeks['${event.season}|${event.week}'] ??= []).add(event);
    }
    final keys = weeks.keys.toList()
      ..sort((a, b) {
        final left = a.split('|');
        final right = b.split('|');
        final season = int.parse(left[0]).compareTo(int.parse(right[0]));
        return season != 0
            ? season
            : int.parse(left[1]).compareTo(int.parse(right[1]));
      });
    for (final key in keys) {
      final platt = _fitPlatt(prior, slope: true);
      final shift = _fitPlatt(prior, slope: false);
      final isotonic = fitPropCalibrator([
        for (final row in prior) (raw: row.served, hit: row.hit),
      ]);
      for (final event in weeks[key]!) {
        double shown(double chance) => limitChanceGap(
          chance: chance,
          raw: event.raw,
          observed: event.games,
          market: propReportMarketProxy,
        );
        _add(boards['served']![event.season]!, shown(event.served), event.hit);
        _add(boards['lognormal']![event.season]!, shown(event.lognormal), event.hit);
        _add(
          boards['platt']![event.season]!,
          shown(platt.apply(event.served)),
          event.hit,
        );
        _add(
          boards['shift']![event.season]!,
          shown(shift.apply(event.served)),
          event.hit,
        );
        _add(
          boards['isotonic']![event.season]!,
          shown(isotonic.apply(event.served)),
          event.hit,
        );
      }
      prior.addAll(weeks[key]!);
    }
    for (final seasonBoards in boards.values) {
      for (final board in seasonBoards.values) {
        if (board.n == 0) continue;
        board.brier /= board.n;
        board.logLoss /= board.n;
        board.predicted /= board.n;
        board.actual /= board.n;
        board.overShare /= board.n;
      }
    }
    String? winner;
    var bestSum = double.infinity;
    for (final name in names.skip(1)) {
      final wins = [2025, 2026].every((season) {
        final model = boards[name]![season]!;
        final served = boards['served']![season]!;
        return model.n >= 1000 &&
            model.brier < served.brier &&
            model.logLoss < served.logLoss;
      });
      for (final season in [2025, 2026]) {
        final board = boards[name]![season]!;
        final served = boards['served']![season]!;
        // ignore: avoid_print
        print(
          '$name $season n=${board.n} brier=${board.brier.toStringAsFixed(4)} '
          'log=${board.logLoss.toStringAsFixed(4)} '
          'pred=${board.predicted.toStringAsFixed(3)} '
          'actual=${board.actual.toStringAsFixed(3)} '
          'overShare=${board.overShare.toStringAsFixed(3)} '
          'servedBrier=${served.brier.toStringAsFixed(4)} '
          'servedLog=${served.logLoss.toStringAsFixed(4)}',
        );
      }
      if (wins) {
        final sum = boards[name]![2025]!.brier + boards[name]![2026]!.brier;
        if (sum < bestSum) {
          bestSum = sum;
          winner = name;
        }
      }
    }
    expect(servedOverCalibration, winner ?? 'none');
    expect(overRateCalibrationAdopted, winner != null);
  });
}

void _add(_Board board, double chance, bool hit) {
  final p = chance.clamp(1e-4, 1 - 1e-4);
  board.n++;
  final gap = p - (hit ? 1 : 0);
  board.brier += gap * gap;
  board.logLoss += -(hit ? math.log(p) : math.log(1 - p));
  board.predicted += p;
  if (hit) board.actual += 1;
  if (p > 0.5) board.overShare += 1;
}

class _Board {
  int n = 0;
  double brier = 0;
  double logLoss = 0;
  double predicted = 0;
  double actual = 0;
  double overShare = 0;
}

class _Event {
  _Event({
    required this.season,
    required this.week,
    required this.served,
    required this.raw,
    required this.games,
    required this.lognormal,
    required this.hit,
  });

  final int season, week, games;
  final double served, raw, lognormal;
  final bool hit;
}

class _Platt {
  const _Platt(this.a, this.b);
  final double a, b;

  double apply(double chance) {
    final p = chance.clamp(1e-4, 1 - 1e-4);
    final logit = math.log(p / (1 - p));
    final z = (a + b * logit).clamp(-20.0, 20.0);
    return (1 / (1 + math.exp(-z))).clamp(1e-4, 1 - 1e-4);
  }
}

/// Ridge keeps a near 0 and, when [slope] is on, b near 1.
/// Fewer than 200 earlier cards returns the identity.
_Platt _fitPlatt(List<_Event> rows, {required bool slope}) {
  if (rows.length < calibrationMinSamples) return const _Platt(0, 1);
  var a = 0.0;
  var b = 1.0;
  const ridge = 8.0;
  for (var iter = 0; iter < 25; iter++) {
    var g0 = 0.0, g1 = 0.0, h00 = 0.0, h01 = 0.0, h11 = 0.0;
    for (final row in rows) {
      final p = row.served.clamp(1e-4, 1 - 1e-4);
      final x = math.log(p / (1 - p));
      final z = (a + (slope ? b : 1) * x).clamp(-20.0, 20.0);
      final s = 1 / (1 + math.exp(-z));
      final y = row.hit ? 1.0 : 0.0;
      final residual = y - s;
      final weight = s * (1 - s);
      g0 += residual;
      h00 += weight;
      if (slope) {
        g1 += residual * x;
        h01 += weight * x;
        h11 += weight * x * x;
      }
    }
    g0 -= ridge * a;
    h00 += ridge;
    if (!slope) {
      final step = g0 / h00;
      a += step;
      if (step.abs() < 1e-6) break;
      continue;
    }
    g1 -= ridge * (b - 1);
    h11 += ridge;
    final det = h00 * h11 - h01 * h01;
    if (det.abs() < 1e-8) break;
    final da = (h11 * g0 - h01 * g1) / det;
    final db = (h00 * g1 - h01 * g0) / det;
    a += da;
    b += db;
    if (da.abs() < 1e-6 && db.abs() < 1e-6) break;
  }
  return _Platt(a, slope ? b : 1);
}

double _lognormalOver({
  required double mean,
  required double sd,
  required double line,
}) {
  final center = mean <= 0.5 ? 0.5 : mean;
  final width = sd <= 0 ? 1.0 : sd;
  final sigma2 = math.log(1 + (width * width) / (center * center));
  final mu = math.log(center) - sigma2 / 2;
  final sigma = math.sqrt(sigma2);
  final whole = line == line.roundToDouble();
  final boundary = whole ? line + 0.5 : line;
  if (boundary <= 0) return 1 - 1e-4;
  final z = (math.log(boundary) - mu) / sigma;
  return (1 - normalCdf(z)).clamp(1e-4, 1 - 1e-4);
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
