import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/coach_line_v2.dart';
import 'package:odds_edge/domain/history.dart';
import 'package:odds_edge/domain/matchup.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/unit_ratings.dart';

/// Prints market versus unit-versus-unit game scores. Served spreads,
/// totals and moneylines change only when this file's winner says so.
void main() {
  test('unit matchup game lines are scored against the closing line', () {
    final players = PlayerStatsDataset.fromJson(
      jsonDecode(
        File('assets/nfl-player-stats.json')
            .readAsStringSync()
            .replaceFirst('\uFEFF', ''),
      ) as Map<String, dynamic>,
    ).rows;
    final history = _history();
    final book = RatingBook.build(players);
    final rows = _rows(history, book);
    final scored = _walk(rows);
    for (final season in [2025, 2026]) {
      for (final name in ['market', 'unit', 'unitForm']) {
        final board = scored[name]![season]!;
        // ignore: avoid_print
        print(
          '$name $season n=${board.n} '
          'coverBrier=${board.coverBrier.toStringAsFixed(4)} '
          'coverLog=${board.coverLog.toStringAsFixed(4)} '
          'mlBrier=${board.mlBrier.toStringAsFixed(4)} '
          'mlLog=${board.mlLog.toStringAsFixed(4)} '
          'totalBrier=${board.totalBrier.toStringAsFixed(4)} '
          'totalLog=${board.totalLog.toStringAsFixed(4)} '
          'mlN=${board.mlN} totalN=${board.totalN}',
        );
      }
    }
    bool beatsMarket(String name) {
      for (final season in [2025, 2026]) {
        final model = scored[name]![season]!;
        final market = scored['market']![season]!;
        final won =
            model.n >= 100 &&
            model.coverBrier < market.coverBrier &&
            model.coverLog < market.coverLog &&
            model.mlN >= 100 &&
            model.mlBrier < market.mlBrier &&
            model.mlLog < market.mlLog &&
            model.totalN >= 100 &&
            model.totalBrier < market.totalBrier &&
            model.totalLog < market.totalLog;
        if (!won) return false;
      }
      return true;
    }

    final won = beatsMarket('unit') || beatsMarket('unitForm');
    expect(
      gameUnitAdjustmentAdopted,
      won,
      reason: 'Served spreads, totals and moneylines follow this result.',
    );
  });
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

class _GameRow {
  _GameRow({
    required this.season,
    required this.week,
    required this.marginEdge,
    required this.formEdge,
    required this.totalEdge,
    required this.formTotal,
    required this.spread,
    required this.totalLine,
    required this.margin,
    required this.points,
  });

  final int season, week;
  final double marginEdge, formEdge, totalEdge, formTotal;
  final double spread;
  final double? totalLine;
  final double margin, points;
}

class _Board {
  int n = 0, mlN = 0, totalN = 0;
  double coverBrier = 0, coverLog = 0, mlBrier = 0, mlLog = 0;
  double totalBrier = 0, totalLog = 0;

  void cover(double p, bool hit) => _add(p, hit, cover: true);
  void moneyline(double p, bool hit) => _add(p, hit, moneyline: true);
  void total(double p, bool hit) => _add(p, hit, total: true);

  void _add(
    double probability,
    bool hit, {
    bool cover = false,
    bool moneyline = false,
    bool total = false,
  }) {
    final p = probability.clamp(1e-4, 1 - 1e-4);
    final y = hit ? 1.0 : 0.0;
    final brier = (p - y) * (p - y);
    final logLoss = -(hit ? math.log(p) : math.log(1 - p));
    if (cover) {
      n++;
      coverBrier += brier;
      coverLog += logLoss;
    } else if (moneyline) {
      mlN++;
      mlBrier += brier;
      mlLog += logLoss;
    } else if (total) {
      totalN++;
      totalBrier += brier;
      totalLog += logLoss;
    }
  }

  void finish() {
    if (n > 0) {
      coverBrier /= n;
      coverLog /= n;
    }
    if (mlN > 0) {
      mlBrier /= mlN;
      mlLog /= mlN;
    }
    if (totalN > 0) {
      totalBrier /= totalN;
      totalLog /= totalN;
    }
  }
}

List<_GameRow> _rows(List<HistoricalGame> history, RatingBook book) {
  final rows = <_GameRow>[];
  for (final game in history) {
    final spread = game.spreadLine;
    if (spread == null) continue;
    final home = boxScoreTeam(game.home);
    final away = boxScoreTeam(game.away);
    final snap = book.before(season: game.season, week: game.week);
    final edge = _edge(snap, home, away);
    if (edge == null) continue;
    rows.add(
      _GameRow(
        season: game.season,
        week: game.week,
        marginEdge: edge.$1,
        totalEdge: edge.$2,
        formEdge:
            _form(history, home, game.season, game.week, points: false) -
            _form(history, away, game.season, game.week, points: false),
        formTotal:
            _form(history, home, game.season, game.week, points: true) +
            _form(history, away, game.season, game.week, points: true),
        spread: spread,
        totalLine: game.totalLine,
        margin: (game.homeScore - game.awayScore).toDouble(),
        points: (game.homeScore + game.awayScore).toDouble(),
      ),
    );
  }
  rows.sort((a, b) {
    final season = a.season.compareTo(b.season);
    return season != 0 ? season : a.week.compareTo(b.week);
  });
  return rows;
}

(double, double)? _edge(UnitSnapshot snap, String home, String away) {
  double? side(String offense, String defense) {
    final passO = snap
        .lookup(offense, UnitKey.pass, offense: true)
        ?.versusLeague;
    final passD = snap
        .lookup(defense, UnitKey.pass, offense: false)
        ?.versusLeague;
    final runO = snap.lookup(offense, UnitKey.run, offense: true)?.versusLeague;
    final runD = snap
        .lookup(defense, UnitKey.run, offense: false)
        ?.versusLeague;
    if (passO == null || passD == null || runO == null || runD == null) {
      return null;
    }
    return passO + passD + runO + runD;
  }

  final homeSide = side(home, away);
  final awaySide = side(away, home);
  if (homeSide == null || awaySide == null) return null;
  return (homeSide - awaySide, homeSide + awaySide);
}

double _form(
  List<HistoricalGame> games,
  String team,
  int season,
  int week, {
  required bool points,
}) {
  final prior = [
    for (final game in games)
      if (game.season == season &&
          game.week < week &&
          game.spreadLine != null &&
          (points ? game.totalLine != null : true) &&
          (boxScoreTeam(game.home) == team || boxScoreTeam(game.away) == team))
        game,
  ]..sort((a, b) => a.week.compareTo(b.week));
  if (prior.length < 5) return 0;
  double residual(HistoricalGame game) {
    final home = boxScoreTeam(game.home) == team;
    final own = home ? game.homeScore : game.awayScore;
    final opp = home ? game.awayScore : game.homeScore;
    final expectedMargin = home ? game.spreadLine! : -game.spreadLine!;
    if (!points) return (own - opp) - expectedMargin;
    return own - (game.totalLine! + expectedMargin) / 2;
  }

  final values = [for (final game in prior) residual(game)];
  final recent = values.sublist(values.length - 3);
  double average(List<double> sample) =>
      sample.reduce((a, b) => a + b) / sample.length;
  return average(recent) - average(values);
}

Map<String, Map<int, _Board>> _walk(List<_GameRow> rows) {
  final seasons = [2025, 2026];
  final boards = {
    for (final name in ['market', 'unit', 'unitForm'])
      name: {for (final season in seasons) season: _Board()},
  };
  final weeks = <String, List<_GameRow>>{};
  for (final row in rows) {
    if (!seasons.contains(row.season)) continue;
    (weeks['${row.season}|${row.week}'] ??= []).add(row);
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
    final sample = weeks[key]!;
    final season = sample.first.season;
    final week = sample.first.week;
    final train = [
      for (final row in rows)
        if (row.season < season || (row.season == season && row.week < week))
          row,
    ];
    if (train.length < 80) continue;
    final marginUnit = _fit(
      train,
      (row) => row.marginEdge,
      (row) => 0,
      (row) => row.margin - row.spread,
    );
    final marginBoth = _fit(
      train,
      (row) => row.marginEdge,
      (row) => row.formEdge,
      (row) => row.margin - row.spread,
    );
    final totalUnit = _fit(
      train,
      (row) => row.totalEdge,
      (row) => 0,
      (row) => row.totalLine == null ? null : row.points - row.totalLine!,
    );
    final totalBoth = _fit(
      train,
      (row) => row.totalEdge,
      (row) => row.formTotal,
      (row) => row.totalLine == null ? null : row.points - row.totalLine!,
    );
    final marginSd = _sd([for (final row in train) row.margin])
        .clamp(8.0, 20.0);
    final coverSd = _sd([for (final row in train) row.margin - row.spread])
        .clamp(8.0, 20.0);
    final totalSd = _sd([
      for (final row in train)
        if (row.totalLine != null) row.points - row.totalLine!,
    ]).clamp(8.0, 20.0);
    for (final row in sample) {
      final coverPush = (row.margin - row.spread).abs() < 1e-6;
      final homeWon = row.margin > 0;
      final tie = row.margin == 0;
      final nudges = {
        'market': 0.0,
        'unit': marginUnit.predict(row.marginEdge, 0),
        'unitForm': marginBoth.predict(row.marginEdge, row.formEdge),
      };
      for (final name in nudges.keys) {
        final board = boards[name]![season]!;
        final nudge = nudges[name]!;
        if (!coverPush) {
          final p = name == 'market' ? 0.5 : normalCdf(nudge / coverSd);
          board.cover(p, row.margin > row.spread);
        }
        if (!tie) {
          final p = normalCdf((row.spread + nudge) / marginSd);
          board.moneyline(p, homeWon);
        }
        if (row.totalLine != null &&
            (row.points - row.totalLine!).abs() >= 1e-6) {
          final totalNudge = name == 'market'
              ? 0.0
              : name == 'unit'
              ? totalUnit.predict(row.totalEdge, 0)
              : totalBoth.predict(row.totalEdge, row.formTotal);
          final p = name == 'market' ? 0.5 : normalCdf(totalNudge / totalSd);
          board.total(p, row.points > row.totalLine!);
        }
      }
    }
  }
  for (final seasonBoards in boards.values) {
    for (final board in seasonBoards.values) {
      board.finish();
    }
  }
  return boards;
}

class _Fit {
  _Fit(
    this.b1,
    this.b2,
    this.meanY,
    this.mean1,
    this.mean2,
    this.sd1,
    this.sd2,
  );
  final double b1, b2, meanY, mean1, mean2, sd1, sd2;

  double predict(double x1, double x2) {
    final z1 = sd1 < 1e-6 ? 0.0 : (x1 - mean1) / sd1;
    final z2 = sd2 < 1e-6 ? 0.0 : (x2 - mean2) / sd2;
    return b1 * z1 + b2 * z2;
  }
}

_Fit _fit(
  List<_GameRow> train,
  double Function(_GameRow row) x1,
  double Function(_GameRow row) x2,
  double? Function(_GameRow row) y,
) {
  final rows = [
    for (final row in train)
      if (y(row) != null) (x1: x1(row), x2: x2(row), y: y(row)!),
  ];
  if (rows.length < 80) return _Fit(0, 0, 0, 0, 0, 1, 1);
  double avg(double Function(({double x1, double x2, double y}) row) pick) =>
      rows.map(pick).reduce((a, b) => a + b) / rows.length;
  final mean1 = avg((row) => row.x1);
  final mean2 = avg((row) => row.x2);
  final meanY = avg((row) => row.y);
  double sd(
    double Function(({double x1, double x2, double y}) row) pick,
    double mean,
  ) {
    var sum = 0.0;
    for (final row in rows) {
      final d = pick(row) - mean;
      sum += d * d;
    }
    return math.sqrt(sum / rows.length);
  }

  final sd1 = sd((row) => row.x1, mean1);
  final sd2 = sd((row) => row.x2, mean2);
  var s11 = 8.0, s22 = 8.0, s12 = 0.0, t1 = 0.0, t2 = 0.0;
  for (final row in rows) {
    final z1 = sd1 < 1e-6 ? 0.0 : (row.x1 - mean1) / sd1;
    final z2 = sd2 < 1e-6 ? 0.0 : (row.x2 - mean2) / sd2;
    final target = row.y;
    s11 += z1 * z1;
    s22 += z2 * z2;
    s12 += z1 * z2;
    t1 += z1 * target;
    t2 += z2 * target;
  }
  final det = s11 * s22 - s12 * s12;
  if (det.abs() < 1e-8) return _Fit(0, 0, meanY, mean1, mean2, sd1, sd2);
  return _Fit(
    (s22 * t1 - s12 * t2) / det,
    (s11 * t2 - s12 * t1) / det,
    meanY,
    mean1,
    mean2,
    sd1,
    sd2,
  );
}

double _sd(List<double> values) {
  if (values.length < 2) return 13;
  final mean = values.reduce((a, b) => a + b) / values.length;
  var sum = 0.0;
  for (final value in values) {
    final d = value - mean;
    sum += d * d;
  }
  return math.sqrt(sum / values.length);
}
