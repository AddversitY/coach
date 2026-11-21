import 'player_stats.dart';
import 'prop_context.dart';
import 'prop_projection.dart';
import 'prop_report.dart';
import 'unit_ratings.dart';
import 'hit_rate.dart';

/// November 21, 2026. Each switch is on only when that piece, by itself,
/// beat the served lognormal chance on Brier and log loss in both 2025
/// and 2026. The walk-forward is in test/prop_specialist_test.dart.
/// The numbers are in docs/PROP_SPECIALIST.md. This is not a betting edge.
const gammaYardsAdopted = false;
const positionVarianceAdopted = false;
const zeroInflatedReceptionsAdopted = false;
const recencyUsageAdopted = true;
const shareUsageAdopted = false;
const gameScriptMixAdopted = false;
const gameScriptVolumeAdopted = false;

/// Consensus is a prior only when it beat the 50 percent anchor in both
/// seasons. A season with no two-sided closes stays off.
const consensusPriorAdopted = false;

/// The tune the card passes into [projectProp]. All-off is the lognormal
/// chance already on the card.
const servedPropTune = PropTune(
  recency: recencyUsageAdopted,
  shares: shareUsageAdopted,
  scriptMix: gameScriptMixAdopted,
  scriptVolume: gameScriptVolumeAdopted,
  positionVariance: positionVarianceAdopted,
  gamma: gammaYardsAdopted,
  zeroInflated: zeroInflatedReceptionsAdopted,
);

class SpecialistGame {
  const SpecialistGame({
    required this.season,
    required this.chances,
    required this.hit,
  });

  final int season;
  final Map<String, double> chances;
  final bool hit;
}

/// One walk through 2025 and 2026. [extra] names additional tunes.
/// The served chance is the lognormal curve, the unit matchup, the
/// 32-game shrink, and the 10/15-point gap. Last season's median is the line.
List<SpecialistGame> specialistForecasts({
  required List<PlayerGame> rows,
  required UsageIndex index,
  required RatingBook ratings,
  PositionSpread? spreads,
  ScriptBook? scripts,
  UsageBook? shares,
  Map<String, PropTune> extra = const {},
}) {
  final tunes = <String, PropTune>{
    'gamma': const PropTune(gamma: true),
    'position': const PropTune(positionVariance: true),
    'inflated': const PropTune(zeroInflated: true),
    'recency': const PropTune(recency: true),
    'shares': const PropTune(shares: true),
    'scriptMix': const PropTune(scriptMix: true),
    'scriptVolume': const PropTune(scriptVolume: true),
    ...extra,
  };
  final events = <SpecialistGame>[];
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
        if (line <= 0 || line < (propReportMinimumLine[metric] ?? 0)) continue;
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
            final value = game.stats[metric]!.toDouble();
            if (value == line) continue;
            final env = matchupEnvironment(
              book: ratings,
              playerGames: history,
              metric: metric,
              opponent: game.opponent,
              beforeSeason: season,
              beforeWeek: week,
              recencyWeight: matchupRecencyWeight,
            );
            final chances = <String, double>{};
            final served = _chance(
              index: index,
              game: game,
              metric: metric,
              line: line,
              season: season,
              week: week,
              environment: env.known ? env : null,
            );
            if (served == null) continue;
            chances['served'] = served;
            for (final entry in tunes.entries) {
              final chance = _chance(
                index: index,
                game: game,
                metric: metric,
                line: line,
                season: season,
                week: week,
                environment: env.known ? env : null,
                tune: entry.value,
                spreads: spreads,
                scripts: scripts,
                shares: shares,
              );
              if (chance != null) chances[entry.key] = chance;
            }
            events.add(
              SpecialistGame(
                season: season,
                chances: chances,
                hit: value > line,
              ),
            );
          }
          history.addAll(weeks[week]!);
        }
      }
    }
  }
  return events;
}

double? _chance({
  required UsageIndex index,
  required PlayerGame game,
  required String metric,
  required double line,
  required int season,
  required int week,
  required MatchupEnvironment? environment,
  PropTune tune = const PropTune(),
  PositionSpread? spreads,
  ScriptBook? scripts,
  UsageBook? shares,
}) {
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
    environment: environment,
    lognormalYards: true,
    tune: tune,
    spreads: spreads,
    scripts: scripts,
    shareBook: shares,
  );
  return projection?.chance;
}
