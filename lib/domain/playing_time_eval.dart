import 'dart:math' as math;

import 'history.dart';
import 'hit_rate.dart';
import 'player_stats.dart';
import 'playing_time.dart';
import 'prop_chance.dart';
import 'prop_context.dart';
import 'prop_projection.dart';
import 'prop_specialist.dart';
import 'unit_ratings.dart';

/// Fixed scales for projection error, chosen as round game-to-game spreads
/// before the 2025 and 2026 scores. They are not fit to those scores.
/// Each prop counts once, the same way Brier does.
const playingTimeErrorScale = <String, double>{
  'passing_yards': 70,
  'rushing_yards': 25,
  'receiving_yards': 30,
  'receptions': 2,
};

const _metrics = <String>[
  'passing_yards',
  'rushing_yards',
  'receiving_yards',
  'receptions',
];

const _minimumLine = <String, double>{
  'passing_yards': 100,
  'rushing_yards': 10,
  'receiving_yards': 10,
  'receptions': 1,
};

const _seasons = <int>[2024, 2025, 2026];

/// The chance on the card: recency-weighted usage, the lognormal curve,
/// the unit matchup, the 32-game shrink, and the gap cap. Playing time is
/// not part of this tune. The market anchor is a fair 50 percent because
/// this repo has no two-sided 2025 prop prices.
const _baseline = PropTune(recency: true);

/// One season of the current projection and the playing-time projection,
/// on the same player-games. A week uses only earlier weeks.
class PlayingTimeSeasonScore {
  PlayingTimeSeasonScore(this.season);

  final int season;
  int n = 0;
  double brier = 0;
  double logLoss = 0;
  double scaledError = 0;
  int moved = 0;
  int routeBasis = 0;
  int snapBasis = 0;
  int unavailableBasis = 0;
  int routeUnavailable = 0;
  final mae = <String, double>{for (final metric in _metrics) metric: 0};
  final counted = <String, int>{for (final metric in _metrics) metric: 0};

  void add({
    required String metric,
    required double chance,
    required double mean,
    required double actual,
    required bool hit,
    required bool movedGame,
    required PlayingTimeBasis basis,
    required bool routeUnavailable,
  }) {
    final p = chance.clamp(1e-6, 1 - 1e-6);
    n++;
    final gap = p - (hit ? 1 : 0);
    brier += gap * gap;
    logLoss += -(hit ? math.log(p) : math.log(1 - p));
    final scale = playingTimeErrorScale[metric] ?? 1;
    scaledError += (mean - actual).abs() / scale;
    mae[metric] = (mae[metric] ?? 0) + (mean - actual).abs();
    counted[metric] = (counted[metric] ?? 0) + 1;
    if (movedGame) moved++;
    switch (basis) {
      case PlayingTimeBasis.route:
        routeBasis++;
      case PlayingTimeBasis.snap:
        snapBasis++;
      case PlayingTimeBasis.unavailable:
        unavailableBasis++;
    }
    if (routeUnavailable) this.routeUnavailable++;
  }

  void finish() {
    if (n == 0) return;
    brier /= n;
    logLoss /= n;
    scaledError /= n;
    for (final metric in _metrics) {
      final count = counted[metric] ?? 0;
      if (count == 0) continue;
      mae[metric] = (mae[metric] ?? 0) / count;
    }
  }
}

class PlayingTimeReport {
  PlayingTimeReport({
    required this.current,
    required this.playingTime,
    required this.sameChance,
  });

  final Map<int, PlayingTimeSeasonScore> current;
  final Map<int, PlayingTimeSeasonScore> playingTime;

  /// Games whose replay of the current chance matched [projectProp].
  final int sameChance;

  bool seasonBeats(int season) {
    final left = playingTime[season];
    final right = current[season];
    if (left == null || right == null) return false;
    return left.n >= 1000 &&
        left.n == right.n &&
        left.brier < right.brier &&
        left.logLoss < right.logLoss &&
        left.scaledError < right.scaledError;
  }

  /// 2024 is reported and is not the adoption test.
  bool get beatsCurrent => seasonBeats(2025) && seasonBeats(2026);

  String get text {
    final lines = <String>[
      'Playing-time walk-forward. A week uses only earlier weeks. '
          'The Out list for the scored week is the pregame report. '
          'The line is last season\'s median. The anchor is 50%. '
          '2024 is context. Adoption is 2025 and 2026.',
      'Projection error is the mean of |projection - actual| / scale. '
          'Scales: passing 70, rushing 25, receiving 30, receptions 2.',
      'Lower Brier, log loss, and projection error is closer.',
    ];
    for (final season in _seasons) {
      lines.add(_line('current', current[season], usage: false));
      lines.add(_line('playing time', playingTime[season], usage: true));
      for (final metric in _metrics) {
        lines.add(_mae(season, metric));
      }
    }
    lines.add(
      'beats both seasons: $beatsCurrent. '
      'Card uses playing time: $playingTimeAdopted. '
      'Chance replays checked: $sameChance.',
    );
    return lines.join('\n');
  }

  String _line(
    String name,
    PlayingTimeSeasonScore? score, {
    required bool usage,
  }) {
    if (score == null || score.n == 0) {
      return '$name unavailable';
    }
    final base =
        '${score.season} $name n=${score.n} '
        'brier=${score.brier.toStringAsFixed(6)} '
        'log=${score.logLoss.toStringAsFixed(6)} '
        'projection error=${score.scaledError.toStringAsFixed(6)}';
    if (!usage) return base;
    return '$base '
        'moved=${score.moved} '
        'route=${score.routeBasis} snap=${score.snapBasis} '
        'playing time unavailable=${score.unavailableBasis} '
        'route share unavailable=${score.routeUnavailable}';
  }

  String _mae(int season, String metric) {
    final left = current[season];
    final right = playingTime[season];
    final leftN = left?.counted[metric] ?? 0;
    final rightN = right?.counted[metric] ?? 0;
    if (left == null || right == null || leftN == 0 || rightN == 0) {
      return '$season $metric mean absolute error unavailable';
    }
    return '$season $metric mean absolute error '
        'current=${left.mae[metric]!.toStringAsFixed(4)} '
        'playing time=${right.mae[metric]!.toStringAsFixed(4)} '
        'n=$leftN';
  }
}

/// Scores the current card and the playing-time layer on the same games.
PlayingTimeReport scorePlayingTime({
  required List<PlayerGame> players,
  required List<HistoricalGame> scores,
  required UsageBook shares,
  required List<List<dynamic>> outs,
}) {
  if (!_sameTune(servedPropTune, _baseline)) {
    throw StateError(
      'The card tune changed. Score playing time against that tune.',
    );
  }
  final index = UsageIndex.build(players, scores: scores);
  final ratings = RatingBook.build(players);
  final book = PlayingTimeBook.build(
    games: players,
    shares: shares,
    outs: outs,
  );
  final current = {
    for (final season in _seasons) season: PlayingTimeSeasonScore(season),
  };
  final playing = {
    for (final season in _seasons) season: PlayingTimeSeasonScore(season),
  };
  var sameChance = 0;
  for (final metric in _metrics) {
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
        if (!_seasons.contains(season)) continue;
        final previous = bySeason[seasons[indexSeason - 1]]!;
        if (previous.length < 4) continue;
        final values = [
          for (final game in previous) game.stats[metric]!.toDouble(),
        ]..sort();
        final line = values[values.length ~/ 2];
        if (line <= 0 || line < (_minimumLine[metric] ?? 0)) continue;
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
            final actual = game.stats[metric]!.toDouble();
            if (actual == line) continue;
            final env = matchupEnvironment(
              book: ratings,
              playerGames: history,
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
              market: 0.5,
              environment: env.known ? env : null,
              lognormalYards: true,
              tune: servedPropTune,
            );
            final mean = projection?.mean;
            final sd = projection?.sd;
            final played = projection?.games;
            final chance = projection?.chance;
            if (mean == null ||
                sd == null ||
                played == null ||
                chance == null) {
              continue;
            }
            final replay = _shown(
              metric: metric,
              mean: mean,
              sd: sd,
              line: line,
              games: played,
            );
            if (replay == null || (replay - chance).abs() > 1e-6) {
              throw StateError(
                'The replayed chance does not match the card for $metric.',
              );
            }
            sameChance++;
            final move = book.move(
              playerId: game.playerId,
              metric: metric,
              team: game.team,
              position: game.position,
              season: season,
              week: week,
            );
            final adjusted = _shown(
              metric: metric,
              mean: mean * move.factor,
              sd: sd,
              line: line,
              games: played,
            );
            if (adjusted == null) continue;
            final hit = actual > line;
            current[season]!.add(
              metric: metric,
              chance: chance,
              mean: mean,
              actual: actual,
              hit: hit,
              movedGame: false,
              basis: PlayingTimeBasis.unavailable,
              routeUnavailable: false,
            );
            playing[season]!.add(
              metric: metric,
              chance: adjusted,
              mean: mean * move.factor,
              actual: actual,
              hit: hit,
              movedGame: (move.factor - 1).abs() >= 0.01,
              basis: move.basis,
              routeUnavailable: move.routeUnavailable,
            );
          }
          history.addAll(weeks[week]!);
        }
      }
    }
  }
  for (final score in [...current.values, ...playing.values]) {
    score.finish();
  }
  return PlayingTimeReport(
    current: current,
    playingTime: playing,
    sameChance: sameChance,
  );
}

bool _sameTune(PropTune left, PropTune right) =>
    left.recency == right.recency &&
    left.shares == right.shares &&
    left.scriptMix == right.scriptMix &&
    left.scriptVolume == right.scriptVolume &&
    left.positionVariance == right.positionVariance &&
    left.gamma == right.gamma &&
    left.zeroInflated == right.zeroInflated;

double? _shown({
  required String metric,
  required double mean,
  required double sd,
  required double line,
  required int games,
}) {
  final raw = sideChance(
    metric: metric,
    mean: mean,
    sd: sd,
    line: line,
    side: LineSide.over,
    lognormal: metric != 'receptions',
  );
  final shrunk = shrinkProjectedChance(
    projected: raw,
    observed: games,
    market: 0.5,
  );
  if (shrunk == null) return null;
  return limitChanceGap(chance: shrunk, raw: raw, observed: games, market: 0.5);
}
