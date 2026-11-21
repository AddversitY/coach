import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/history.dart';
import 'package:odds_edge/domain/hit_rate.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/prop_consensus.dart';
import 'package:odds_edge/domain/prop_context.dart';
import 'package:odds_edge/domain/prop_distributions.dart';
import 'package:odds_edge/domain/prop_projection.dart';
import 'package:odds_edge/domain/prop_report.dart';
import 'package:odds_edge/domain/prop_specialist.dart';
import 'package:odds_edge/domain/prop_touchdown.dart';
import 'package:odds_edge/domain/unit_ratings.dart';

void main() {
  test('market curves stay on one side of the line', () {
    final over = gammaSideChance(
      mean: 64,
      sd: 28,
      line: 63.5,
      side: LineSide.over,
    );
    final under = gammaSideChance(
      mean: 64,
      sd: 28,
      line: 63.5,
      side: LineSide.under,
    );
    expect(over + under, closeTo(1, 1e-6));
    expect(over, greaterThan(0.4));
    expect(over, lessThan(0.7));
    final plain = sideChance(
      metric: 'receptions',
      mean: 4.2,
      sd: 2.1,
      line: 3.5,
      side: LineSide.over,
    );
    final inflated = zeroInflatedSideChance(
      mean: 4.2,
      sd: 2.1,
      line: 3.5,
      side: LineSide.over,
      zeroRate: 0,
    );
    expect(inflated, closeTo(plain, 0.02));
    final heavy = zeroInflatedSideChance(
      mean: 4.2,
      sd: 2.1,
      line: 0.5,
      side: LineSide.under,
      zeroRate: 0.4,
    );
    final light = zeroInflatedSideChance(
      mean: 4.2,
      sd: 2.1,
      line: 0.5,
      side: LineSide.under,
      zeroRate: 0,
    );
    expect(heavy, greaterThan(light));
  });

  test('consensus prior splits Pinnacle and drops an old outlier', () {
    final now = DateTime.utc(2026, 9, 20);
    final read = propConsensus([
      PropBookPrice(
        book: 'pinnacle',
        overDecimal: 1.92,
        underDecimal: 1.92,
        at: now,
      ),
      PropBookPrice(
        book: 'draftkings',
        overDecimal: 1.87,
        underDecimal: 1.95,
        at: now,
      ),
      PropBookPrice(
        book: 'oldbook',
        overDecimal: 1.40,
        underDecimal: 2.80,
        at: now.subtract(const Duration(hours: 5)),
      ),
    ]);
    expect(read.staleBooks, ['oldbook']);
    expect(read.pinnacle, isNotNull);
    expect(read.prior, isNotNull);
    expect(read.detail, isNot(contains('edge')));
    final noTime = propConsensus([
      PropBookPrice(book: 'pinnacle', overDecimal: 2.2, underDecimal: 1.7),
      PropBookPrice(
        book: 'fanduel',
        overDecimal: 1.8,
        underDecimal: 2.0,
        at: now,
      ),
    ]);
    expect(noTime.staleBooks, isEmpty);
    expect(noTime.prior, isNotNull);
  });

  test('a favorite gets more rush volume from the closing number', () {
    final home = ScriptPoint.fromBetting(teamSpread: -6.5, total: 47);
    final dog = ScriptPoint.fromBetting(teamSpread: 6.5, total: 47);
    expect(home, isNotNull);
    expect(dog, isNotNull);
    expect(home!.margin, 6.5);
    expect(home.implied, greaterThan(dog!.implied));
    final book = ScriptBook([
      HistoricalGame(
        season: 2024,
        week: 15,
        date: DateTime.utc(2024, 12, 15),
        home: 'NYG',
        away: 'BAL',
        homeScore: 14,
        awayScore: 35,
        spreadLine: -16.5,
        totalLine: 43,
      ),
    ]);
    expect(book.lookup(season: 2024, week: 15, team: 'BAL')!.margin, 16.5);
    expect(book.lookup(season: 2024, week: 15, team: 'NYG')!.margin, -16.5);
  });

  test('specialist pieces are kept only when both seasons improve', () {
    final players = _players();
    final history = _history();
    final usage = UsageBook.fromJson(_json('assets/prop-usage.json'));
    final index = UsageIndex.build(players, scores: history);
    final ratings = RatingBook.build(players);
    final spreads = PositionSpread(players);
    final scripts = ScriptBook(history);
    final events = specialistForecasts(
      rows: players,
      index: index,
      ratings: ratings,
      spreads: spreads,
      scripts: scripts,
      shares: usage,
    );
    final names = [
      'served',
      'gamma',
      'position',
      'inflated',
      'recency',
      'shares',
      'scriptMix',
      'scriptVolume',
    ];
    final boards = _score(events, names);
    _printBoards('piece', boards, names);
    final served2025 = boards['served']![2025]!;
    final served2026 = boards['served']![2026]!;
    // 2025 is the published population. 2026 in the current box scores
    // is a few games past the 3,948 in the earlier write-up.
    expect(served2025.n, 6924);
    expect(served2026.n, greaterThanOrEqualTo(3948));
    final winners = [
      for (final name in names.skip(1))
        if (_beats(boards[name]!, boards['served']!)) name,
    ];
    var adopted = <String>{...winners};
    if (winners.length > 1) {
      final tune = PropTune(
        gamma: winners.contains('gamma'),
        positionVariance: winners.contains('position'),
        zeroInflated: winners.contains('inflated'),
        recency: winners.contains('recency'),
        shares: winners.contains('shares'),
        scriptMix: winners.contains('scriptMix'),
        scriptVolume: winners.contains('scriptVolume'),
      );
      final stacked = specialistForecasts(
        rows: players,
        index: index,
        ratings: ratings,
        spreads: spreads,
        scripts: scripts,
        shares: usage,
        extra: {'stack': tune},
      );
      final stackBoards = _score(stacked, ['served', 'stack']);
      _printBoards('stack', stackBoards, ['served', 'stack']);
      if (!_beats(stackBoards['stack']!, stackBoards['served']!)) {
        adopted = {_best(boards, winners)};
      }
    }
    expect(gammaYardsAdopted, adopted.contains('gamma'));
    expect(positionVarianceAdopted, adopted.contains('position'));
    expect(zeroInflatedReceptionsAdopted, adopted.contains('inflated'));
    expect(recencyUsageAdopted, adopted.contains('recency'));
    expect(shareUsageAdopted, adopted.contains('shares'));
    expect(gameScriptMixAdopted, adopted.contains('scriptMix'));
    expect(gameScriptVolumeAdopted, adopted.contains('scriptVolume'));

    final touchdowns = anytimeForecasts(
      players,
      shares: usage,
      scripts: scripts,
    );
    final touchNames = [
      'record',
      'poisson',
      'inflated',
      'poissonZone',
      'inflatedZone',
      'poissonScript',
      'inflatedScript',
      'poissonBoth',
      'inflatedBoth',
    ];
    final touchBoards = _scoreAnytime(touchdowns);
    _printBoards('anytime', touchBoards, touchNames);
    final touchWinners = [
      for (final name in ['poisson', 'inflated'])
        if (_beats(touchBoards[name]!, touchBoards['record']!)) name,
    ];
    final touchAdopted = touchWinners.isEmpty
        ? null
        : _best(touchBoards, touchWinners);
    var zoneOn = false;
    var scriptOn = false;
    if (touchAdopted != null) {
      final zoneName = '${touchAdopted}Zone';
      final scriptName = '${touchAdopted}Script';
      final bothName = '${touchAdopted}Both';
      zoneOn = _beats(touchBoards[zoneName]!, touchBoards[touchAdopted]!);
      scriptOn = _beats(touchBoards[scriptName]!, touchBoards[touchAdopted]!);
      if (zoneOn && scriptOn) {
        final bothWins = _beats(
          touchBoards[bothName]!,
          touchBoards[touchAdopted]!,
        );
        if (!bothWins) {
          final keep = _best(touchBoards, [zoneName, scriptName]);
          zoneOn = keep == zoneName;
          scriptOn = keep == scriptName;
        }
      }
    }
    expect(anytimeModelAdopted, touchAdopted != null);
    expect(servedAnytimeModel, touchAdopted ?? 'record');
    expect(anytimeRedZoneAdopted, zoneOn);
    expect(anytimeScriptAdopted, scriptOn);

    final closes = _json('assets/prop-closes.json');
    final rawRows = closes['rows'];
    expect(rawRows, isA<List>());
    final closeRows = [
      for (final row in rawRows as List)
        if (row is Map) Map<String, dynamic>.from(row),
    ];
    expect(closeRows.where((row) => row['season'] == 2025), isEmpty);
    final closeBoards = {'ours': _Board(), 'prior': _Board()};
    var gap = 0.0;
    var gapN = 0;
    for (final row in closeRows) {
      if (row['season'] != 2026) continue;
      final metric = row['metric'];
      if (metric is! String || metric == 'anytime_td') continue;
      final line = (row['line'] as num).toDouble();
      final actual = (row['actual'] as num).toDouble();
      final prior = (row['prior'] as num).toDouble();
      if (actual == line || prior <= 0 || prior >= 1) continue;
      final hit = actual > line;
      final env = matchupEnvironment(
        book: ratings,
        playerGames: [
          for (final game in players)
            if (game.playerId == row['playerId'] &&
                (game.season < row['season'] ||
                    (game.season == row['season'] && game.week < row['week'])))
              game,
        ],
        metric: metric,
        opponent: '${row['opponent']}',
        beforeSeason: row['season'] as int,
        beforeWeek: row['week'] as int,
        recencyWeight: matchupRecencyWeight,
      );
      final chance = projectProp(
        index: index,
        playerId: '${row['playerId']}',
        metric: metric,
        line: line,
        side: LineSide.over,
        beforeSeason: row['season'] as int,
        beforeWeek: row['week'] as int,
        team: '${row['team']}',
        opponent: '${row['opponent']}',
        market: propReportMarketProxy,
        environment: env.known ? env : null,
        lognormalYards: true,
        tune: servedPropTune,
        spreads: spreads,
        scripts: scripts,
        shareBook: usage,
      )?.chance;
      if (chance == null) continue;
      _add(closeBoards['ours']!, chance, hit);
      _add(closeBoards['prior']!, prior, hit);
      gap += chance - prior;
      gapN++;
    }
    for (final board in closeBoards.values) {
      board.finish();
    }
    // ignore: avoid_print
    print(
      'closes 2026 n=${closeBoards['ours']!.n} '
      'our brier=${closeBoards['ours']!.brier.toStringAsFixed(4)} '
      'log=${closeBoards['ours']!.logLoss.toStringAsFixed(4)} '
      'close brier=${closeBoards['prior']!.brier.toStringAsFixed(4)} '
      'log=${closeBoards['prior']!.logLoss.toStringAsFixed(4)} '
      'mean chance minus close=${gapN == 0 ? 'unavailable' : (gap / gapN).toStringAsFixed(4)}',
    );
    // ignore: avoid_print
    print('closes 2025 unavailable');
    // ignore: avoid_print
    print('odds gap no-vig ${closes['oddsGap']?['noVig']}');
    // ignore: avoid_print
    print('bovada scored ${closes['bovada']?['scored']}');
    expect(closeBoards['ours']!.n, greaterThanOrEqualTo(100));
    expect(consensusPriorAdopted, isFalse);
  }, timeout: const Timeout(Duration(minutes: 20)));
}

Map<String, Map<int, _Board>> _score(
  List<SpecialistGame> events,
  List<String> names,
) {
  final boards = {
    for (final name in names) name: {2025: _Board(), 2026: _Board()},
  };
  for (final event in events) {
    if (!event.chances.containsKey('served')) continue;
    for (final name in names) {
      final chance = event.chances[name];
      if (chance == null) continue;
      _add(boards[name]![event.season]!, chance, event.hit);
    }
  }
  for (final seasonBoards in boards.values) {
    for (final board in seasonBoards.values) {
      board.finish();
    }
  }
  return boards;
}

Map<String, Map<int, _Board>> _scoreAnytime(List<AnytimeForecast> events) {
  final names = [
    'record',
    'poisson',
    'inflated',
    'poissonZone',
    'inflatedZone',
    'poissonScript',
    'inflatedScript',
    'poissonBoth',
    'inflatedBoth',
  ];
  final boards = {
    for (final name in names) name: {2025: _Board(), 2026: _Board()},
  };
  for (final event in events) {
    final chances = {
      'record': event.record,
      'poisson': event.poisson,
      'inflated': event.inflated,
      'poissonZone': event.poissonZone,
      'inflatedZone': event.inflatedZone,
      'poissonScript': event.poissonScript,
      'inflatedScript': event.inflatedScript,
      'poissonBoth': event.poissonBoth,
      'inflatedBoth': event.inflatedBoth,
    };
    for (final entry in chances.entries) {
      _add(boards[entry.key]![event.season]!, entry.value, event.hit);
    }
  }
  for (final seasonBoards in boards.values) {
    for (final board in seasonBoards.values) {
      board.finish();
    }
  }
  return boards;
}

bool _beats(Map<int, _Board> model, Map<int, _Board> base) {
  return [2025, 2026].every((season) {
    final left = model[season]!;
    final right = base[season]!;
    return left.n >= 1000 &&
        left.n == right.n &&
        left.brier < right.brier &&
        left.logLoss < right.logLoss;
  });
}

String _best(Map<String, Map<int, _Board>> boards, List<String> names) {
  String best = names.first;
  var bestBrier = double.infinity;
  var bestLog = double.infinity;
  for (final name in names) {
    final brier = boards[name]![2025]!.brier + boards[name]![2026]!.brier;
    final logLoss = boards[name]![2025]!.logLoss + boards[name]![2026]!.logLoss;
    if (brier < bestBrier - 1e-12 ||
        ((brier - bestBrier).abs() <= 1e-12 && logLoss < bestLog)) {
      best = name;
      bestBrier = brier;
      bestLog = logLoss;
    }
  }
  return best;
}

void _printBoards(
  String label,
  Map<String, Map<int, _Board>> boards,
  List<String> names,
) {
  for (final name in names) {
    for (final season in [2025, 2026]) {
      final board = boards[name]![season]!;
      // ignore: avoid_print
      print(
        '$label $name $season n=${board.n} '
        'brier=${board.brier.toStringAsFixed(4)} '
        'log=${board.logLoss.toStringAsFixed(4)} '
        'chance=${board.n == 0 ? 'unavailable' : board.predicted.toStringAsFixed(3)} '
        'actual=${board.n == 0 ? 'unavailable' : board.actual.toStringAsFixed(3)}',
      );
    }
  }
}

void _add(_Board board, double chance, bool hit) {
  final p = chance.clamp(1e-6, 1 - 1e-6);
  board.n++;
  final gap = p - (hit ? 1 : 0);
  board.brier += gap * gap;
  board.logLoss += -(hit ? math.log(p) : math.log(1 - p));
  board.predicted += p;
  if (hit) board.actual += 1;
}

class _Board {
  int n = 0;
  double brier = 0;
  double logLoss = 0;
  double predicted = 0;
  double actual = 0;

  void finish() {
    if (n == 0) return;
    brier /= n;
    logLoss /= n;
    predicted /= n;
    actual /= n;
  }
}

List<PlayerGame> _players() {
  final json = _json('assets/nfl-player-stats.json');
  return PlayerStatsDataset.fromJson(json).rows;
}

List<HistoricalGame> _history() {
  final games = _json('assets/nfl-history.json')['games'];
  if (games is! List) return const [];
  return [
    for (final row in games)
      if (row is Map) HistoricalGame.fromJson(Map<String, dynamic>.from(row)),
  ];
}

Map<String, dynamic> _json(String path) {
  return jsonDecode(File(path).readAsStringSync().replaceFirst('\uFEFF', ''))
      as Map<String, dynamic>;
}
