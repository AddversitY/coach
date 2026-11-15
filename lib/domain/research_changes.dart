import 'eastern.dart';
import 'matchup.dart';
import 'nfl_teams.dart';
import 'player_stats.dart';
import 'prop_history.dart';

/// A descriptive comparison of two fixed, non-overlapping recorded windows.
/// This does not change a projection, probability or assessment.
class ResearchChange {
  ResearchChange({
    required this.metric,
    required this.label,
    required this.recentAverage,
    required this.previousAverage,
    required List<DateTime> recentDates,
    required List<DateTime> previousDates,
  }) : recentDates = List.unmodifiable(recentDates),
       previousDates = List.unmodifiable(previousDates);

  final String metric, label;
  final double recentAverage, previousAverage;
  final List<DateTime> recentDates, previousDates;

  DateTime get latestGame => recentDates.first;
  String get summary =>
      '$label averaged ${formatResearchAverage(recentAverage)} per game in the last ${recentDates.length} recorded games, '
      '${recentAverage > previousAverage ? 'up' : 'down'} from ${formatResearchAverage(previousAverage)} in the previous ${previousDates.length}.';
}

String formatResearchAverage(double value) {
  final rounded = value.toStringAsFixed(1);
  return rounded == '-0.0' ? '0.0' : rounded;
}

const _workload = {
  'passing_yards': ('attempts', 'Pass attempts'),
  'passing_tds': ('attempts', 'Pass attempts'),
  'rushing_yards': ('carries', 'Carries'),
  'rushing_tds': ('carries', 'Carries'),
  'receptions': ('targets', 'Targets'),
  'receiving_yards': ('targets', 'Targets'),
  'receiving_tds': ('targets', 'Targets'),
};

const _production = {
  'passing_yards': 'Passing yards',
  'passing_tds': 'Passing touchdowns',
  'rushing_yards': 'Rushing yards',
  'rushing_tds': 'Rushing touchdowns',
  'receptions': 'Receptions',
  'receiving_yards': 'Receiving yards',
  'receiving_tds': 'Receiving touchdowns',
};

/// Last three versus previous three games in one current team/season segment.
/// Missing values do not become zeroes or cause older games to fill a window.
/// The earlier of the event and actual Eastern research days is excluded,
/// matching the prop history boundary. Old or unverifiable evidence is quiet.
List<ResearchChange> recentResearchChanges({
  required PlayerStatsDataset data,
  required String playerId,
  required String market,
  required String team,
  required DateTime now,
  DateTime? eventAt,
  Set<String> eventTeams = const {},
}) {
  final metric = propStatMetrics[market];
  final workload = _workload[metric];
  if (metric == null || workload == null || playerId.isEmpty) return const [];
  final actualWall = easternWall(now);
  final actualDay = DateTime.utc(
    actualWall.year,
    actualWall.month,
    actualWall.day,
  );
  final season = data.metadata['currentSeason'];
  final currentSeason = actualDay.month <= 2
      ? actualDay.year - 1
      : actualDay.year;
  if (season is! int || season != currentSeason) return const [];
  final cutoff = parseEvidenceDay(data.metadata['cutoff']);
  final retrieved = parseEvidenceTimestamp(data.metadata['retrievedAt']);
  if (cutoff == null ||
      retrieved == null ||
      cutoff.isAfter(actualDay) ||
      retrieved.isAfter(now.toUtc()) ||
      actualDay.difference(cutoff).inDays > 21) {
    return const [];
  }
  final retrievedWall = easternWall(retrieved);
  if (cutoff.isAfter(
    DateTime.utc(retrievedWall.year, retrievedWall.month, retrievedWall.day),
  )) {
    return const [];
  }
  final researchWall = easternWall(
    eventAt != null && eventAt.isBefore(now) ? eventAt : now,
  );
  final through = DateTime.utc(
    researchWall.year,
    researchWall.month,
    researchWall.day,
  ).subtract(const Duration(days: 1));
  final limit = cutoff.isBefore(through) ? cutoff : through;
  final club = _club(team);
  if (club.isEmpty ||
      (eventTeams.isNotEmpty && !eventTeams.map(_club).contains(club))) {
    return const [];
  }
  final rows =
      data.rows
          .where(
            (game) =>
                game.playerId == playerId &&
                game.season == season &&
                !game.date.isAfter(limit),
          )
          .toList()
        ..sort((a, b) => b.date.compareTo(a.date));
  if (rows.isEmpty ||
      _club(rows.first.team) != club ||
      actualDay.difference(rows.first.date).inDays > 21) {
    return const [];
  }
  final segment = rows.first.seasonType;
  if (segment != 'REG' && segment != 'POST') return const [];
  // Do not reach over a trade or a season-type boundary to pad the samples.
  final games = <PlayerGame>[];
  for (final row in rows) {
    if (_club(row.team) != club || row.seasonType != segment) break;
    games.add(row);
    if (games.length == 6) break;
  }
  if (games.length != 6 ||
      games.map((game) => game.identity).toSet().length != 6 ||
      games.map((game) => game.date).toSet().length != 6) {
    return const [];
  }
  final changes = <ResearchChange>[];
  for (final entry in [workload, (metric, _production[metric]!)]) {
    final values = games.map((game) => game.stats[entry.$1]).toList();
    if (values.any((value) => value == null || !value.isFinite)) continue;
    if (entry.$1 == workload.$1 && values.any((value) => value! < 0)) {
      continue;
    }
    final observed = values.cast<num>();
    final recent = observed.take(3).reduce((a, b) => a + b) / 3;
    final previous = observed.skip(3).reduce((a, b) => a + b) / 3;
    if (formatResearchAverage(recent) == formatResearchAverage(previous)) {
      continue;
    }
    changes.add(
      ResearchChange(
        metric: entry.$1,
        label: entry.$2,
        recentAverage: recent,
        previousAverage: previous,
        recentDates: games.take(3).map((game) => game.date).toList(),
        previousDates: games.skip(3).map((game) => game.date).toList(),
      ),
    );
  }
  return List.unmodifiable(changes);
}

String _club(String raw) {
  final code =
      canonicalTeam(raw) ?? (raw.trim().toUpperCase() == 'LA' ? 'LAR' : null);
  return code == null ? '' : boxScoreTeam(code);
}
