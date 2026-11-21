import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/history.dart';
import 'package:odds_edge/domain/hit_rate.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/prop_chance.dart';
import 'package:odds_edge/domain/prop_context.dart';
import 'package:odds_edge/domain/prop_projection.dart';
import 'package:odds_edge/domain/prop_specialist.dart';
import 'package:odds_edge/domain/unit_ratings.dart';

/// Does the model add anything on top of the closing no-vig price?
///
/// Each row is a real 2026 prop with a two-sided close. The pooled chance is
/// logit(close) + w * (logit(model) - logit(close)). The weight is fit on the
/// other week only, so week 2 is scored with a weight from week 3 and back.
void main() {
  test('market blend against real prop closes', () {
    final players = PlayerStatsDataset.fromJson(
      _json('assets/nfl-player-stats.json'),
    ).rows;
    final history = _history();
    final usage = UsageBook.fromJson(_json('assets/prop-usage.json'));
    final index = UsageIndex.build(players, scores: history);
    final ratings = RatingBook.build(players);
    final spreads = PositionSpread(players);
    final scripts = ScriptBook(history);
    final rows = [
      for (final row in _json('assets/prop-closes.json')['rows'] as List)
        Map<String, dynamic>.from(row as Map),
    ];

    final samples = <_Sample>[];
    for (final row in rows) {
      if (row['season'] != 2026) continue;
      final metric = row['metric'];
      if (metric is! String || metric == 'anytime_td') continue;
      final line = (row['line'] as num).toDouble();
      final actual = (row['actual'] as num).toDouble();
      final close = (row['prior'] as num).toDouble();
      if (actual == line || close <= 0 || close >= 1) continue;
      final season = row['season'] as int;
      final week = row['week'] as int;
      final id = '${row['playerId']}';
      final env = matchupEnvironment(
        book: ratings,
        playerGames: [
          for (final game in players)
            if (game.playerId == id &&
                (game.season < season ||
                    (game.season == season && game.week < week)))
              game,
        ],
        metric: metric,
        opponent: '${row['opponent']}',
        beforeSeason: season,
        beforeWeek: week,
        recencyWeight: matchupRecencyWeight,
      );
      PropProjection? run(double market, {double? weight}) => projectProp(
        index: index,
        playerId: id,
        metric: metric,
        line: line,
        side: LineSide.over,
        beforeSeason: season,
        beforeWeek: week,
        team: '${row['team']}',
        opponent: '${row['opponent']}',
        market: market,
        environment: env.known ? env : null,
        lognormalYards: true,
        tune: servedPropTune,
        spreads: spreads,
        scripts: scripts,
        shareBook: usage,
        marketWeight: weight,
      );
      final served = run(close);
      final pooledServed = run(close, weight: propModelWeight)?.chance;
      final raw = served?.adjustedChance;
      if (served?.chance == null || raw == null || pooledServed == null) {
        continue;
      }
      samples.add(
        _Sample(
          week: week,
          metric: metric,
          close: close,
          raw: raw,
          served: served!.chance!,
          pooledServed: pooledServed,
          hit: actual > line,
        ),
      );
    }
    expect(samples.length, greaterThanOrEqualTo(100));

    final weights = [for (var i = 0; i <= 20; i++) i / 20];
    double pool(_Sample s, double w) =>
        _sigmoid(_logit(s.close) + w * (_logit(s.raw) - _logit(s.close)));
    double fit(Iterable<_Sample> train) {
      var best = 0.0;
      var bestLoss = double.infinity;
      for (final w in weights) {
        var loss = 0.0;
        for (final s in train) {
          loss += _logLoss(pool(s, w), s.hit);
        }
        if (loss < bestLoss) {
          bestLoss = loss;
          best = w;
        }
      }
      return best;
    }

    final weeks = samples.map((s) => s.week).toSet().toList()..sort();
    final fitted = <int, double>{
      for (final week in weeks) week: fit(samples.where((s) => s.week != week)),
    };
    final boards = <String, _Board>{
      'close': _Board(),
      'served': _Board(),
      'raw': _Board(),
      'pooledCrossWeek': _Board(),
      'servedNow': _Board(),
    };
    final lossGap = <double>[];
    for (final s in samples) {
      final pooled = pool(s, fitted[s.week]!);
      boards['close']!.add(s.close, s.hit);
      boards['served']!.add(s.served, s.hit);
      boards['raw']!.add(s.raw, s.hit);
      boards['pooledCrossWeek']!.add(pooled, s.hit);
      boards['servedNow']!.add(s.pooledServed, s.hit);
      lossGap.add(_logLoss(pooled, s.hit) - _logLoss(s.close, s.hit));
    }
    final overall = fit(samples);
    for (final w in [0.05, 0.1, 0.2]) {
      final b = _Board();
      final gaps = <double>[];
      for (final s in samples) {
        b.add(pool(s, w), s.hit);
        gaps.add(_logLoss(pool(s, w), s.hit) - _logLoss(s.served, s.hit));
      }
      // ignore: avoid_print
      print('fixed w=$w $b pooled minus served ${_meanSe(gaps)}');
    }
    // ignore: avoid_print
    print('n=${samples.length} weeks=$weeks fitted=$fitted inSample=$overall');
    for (final entry in boards.entries) {
      // ignore: avoid_print
      print('${entry.key}: ${entry.value}');
    }
    final mean = lossGap.reduce((a, b) => a + b) / lossGap.length;
    var variance = 0.0;
    for (final g in lossGap) {
      variance += (g - mean) * (g - mean);
    }
    final se = math.sqrt(variance / (lossGap.length - 1) / lossGap.length);
    // ignore: avoid_print
    print(
      'pooled minus close log loss ${mean.toStringAsFixed(5)} '
      '± ${se.toStringAsFixed(5)} (1 se)',
    );
    // The served card must not score worse than the old 32-game shrink,
    // and must sit within a small margin of the close itself.
    final now = boards['servedNow']!;
    expect(now.log / now.n, lessThan(boards['served']!.log / now.n));
    expect(now.log / now.n, lessThan(boards['close']!.log / now.n + 0.002));
    for (final metric in samples.map((s) => s.metric).toSet()) {
      final some = samples.where((s) => s.metric == metric).toList();
      final w = fit(some);
      final c = _Board();
      final p = _Board();
      for (final s in some) {
        c.add(s.close, s.hit);
        p.add(pool(s, w), s.hit);
      }
      // ignore: avoid_print
      print('$metric n=${some.length} inSampleW=$w close=$c pooled=$p');
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}

class _Sample {
  _Sample({
    required this.week,
    required this.metric,
    required this.close,
    required this.raw,
    required this.served,
    required this.pooledServed,
    required this.hit,
  });
  final int week;
  final String metric;
  final double close;
  final double raw;
  final double served;
  final double pooledServed;
  final bool hit;
}

class _Board {
  int n = 0;
  double brier = 0;
  double log = 0;
  void add(double chance, bool hit) {
    final p = chance.clamp(1e-6, 1 - 1e-6);
    n++;
    final gap = p - (hit ? 1 : 0);
    brier += gap * gap;
    log += _logLoss(p, hit);
  }

  @override
  String toString() =>
      'n=$n brier=${(brier / n).toStringAsFixed(4)} '
      'log=${(log / n).toStringAsFixed(4)}';
}

String _meanSe(List<double> xs) {
  final mean = xs.reduce((a, b) => a + b) / xs.length;
  var v = 0.0;
  for (final x in xs) {
    v += (x - mean) * (x - mean);
  }
  final se = math.sqrt(v / (xs.length - 1) / xs.length);
  return '${mean.toStringAsFixed(5)} ± ${se.toStringAsFixed(5)}';
}

double _logLoss(double chance, bool hit) {
  final p = chance.clamp(1e-6, 1 - 1e-6);
  return hit ? -math.log(p) : -math.log(1 - p);
}

double _logit(double p) {
  final q = p.clamp(1e-4, 1 - 1e-4);
  return math.log(q / (1 - q));
}

double _sigmoid(double x) => 1 / (1 + math.exp(-x));

List<HistoricalGame> _history() {
  final games = _json('assets/nfl-history.json')['games'];
  if (games is! List) return const [];
  return [
    for (final row in games)
      if (row is Map) HistoricalGame.fromJson(Map<String, dynamic>.from(row)),
  ];
}

Map<String, dynamic> _json(String path) {
  return jsonDecode(File(path).readAsStringSync().replaceFirst('﻿', ''))
      as Map<String, dynamic>;
}
