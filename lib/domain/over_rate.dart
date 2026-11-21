import 'history.dart';
import 'hit_rate.dart';
import 'matchup.dart';
import 'player_stats.dart';
import 'prop_calibration.dart';
import 'prop_model.dart';
import 'prop_projection.dart';
import 'prop_report.dart';
import 'unit_ratings.dart';

/// One served prop chance from a week the forecast was not allowed to see.
class ServedForecast {
  const ServedForecast({
    required this.season,
    required this.week,
    required this.games,
    required this.metric,
    required this.playerId,
    required this.team,
    required this.position,
    required this.chance,
    required this.raw,
    required this.mean,
    required this.sd,
    required this.line,
    required this.hit,
  });

  final int season, week, games;
  final String metric, playerId, team, position;
  final double chance, raw, mean, sd, line;
  final bool hit;
}

/// Unit-only chances for 2025 and 2026, each using only earlier weeks.
///
/// This is the path the card serves before the over-rate map. The line is
/// last season's median.
List<ServedForecast> servedUnitForecasts({
  required List<PlayerGame> rows,
  required UsageIndex index,
  required RatingBook book,
}) {
  final events = <ServedForecast>[];
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
              market: propReportMarketProxy,
              environment: env.known ? env : null,
            );
            final chance = projection?.chance;
            final raw = projection?.rawChance;
            final mean = projection?.mean;
            final sd = projection?.sd;
            final played = projection?.games;
            if (chance == null ||
                raw == null ||
                mean == null ||
                sd == null ||
                played == null) {
              continue;
            }
            events.add(
              ServedForecast(
                season: season,
                week: week,
                games: played,
                metric: metric,
                playerId: game.playerId,
                team: game.team,
                position: game.position,
                chance: chance,
                raw: raw,
                mean: mean,
                sd: sd,
                line: line,
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

Object? _cachedRows;
PropCalibrator? _cachedMap;

/// Isotonic map, used only when that map is the adopted adjustment.
/// The identity for the lognormal card, and until 200 earlier forecasts exist.
PropCalibrator servedOverCalibrator(
  List<PlayerGame> rows, {
  List<HistoricalGame> scores = const [],
  MatchupContext? matchup,
}) {
  if (!overRateCalibrationAdopted || servedOverCalibration != 'isotonic') {
    return PropCalibrator.identity;
  }
  final cached = _cachedMap;
  if (cached != null && identical(_cachedRows, rows)) return cached;
  final index = usageIndexFor(rows, scores: scores, matchup: matchup);
  final forecasts = servedUnitForecasts(
    rows: rows,
    index: index,
    book: RatingBook.build(rows),
  );
  final map = fitPropCalibrator([
    for (final row in forecasts) (raw: row.chance, hit: row.hit),
  ]);
  _cachedRows = rows;
  _cachedMap = map;
  return map;
}
