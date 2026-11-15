import 'eastern.dart';
import 'matchup.dart';
import 'nfl_teams.dart';
import 'odds.dart';
import 'player_stats.dart';

class ResearchMetric {
  const ResearchMetric(this.key, this.label, this.shortLabel, this.market);
  final String key, label, shortLabel, market;
}

const passingResearch = ResearchMetric(
  'passing_yards',
  'Passing yards',
  'Pass yards',
  'player_pass_yds',
);
const rushingResearch = ResearchMetric(
  'rushing_yards',
  'Rushing yards',
  'Rush yards',
  'player_rush_yds',
);
const receivingResearch = ResearchMetric(
  'receiving_yards',
  'Receiving yards',
  'Rec. yards',
  'player_reception_yds',
);
const receptionsResearch = ResearchMetric(
  'receptions',
  'Receptions',
  'Receptions',
  'player_receptions',
);

List<ResearchMetric> researchMetrics(String position) => switch (position) {
  'QB' => const [passingResearch, rushingResearch],
  'RB' => const [rushingResearch, receivingResearch, receptionsResearch],
  'WR' ||
  'TE' => const [receivingResearch, receptionsResearch, rushingResearch],
  _ => const [],
};

String researchClub(String raw) {
  final code =
      canonicalTeam(raw) ?? (raw.trim().toUpperCase() == 'LA' ? 'LAR' : null);
  return code == null ? '' : boxScoreTeam(code);
}

class GameResearchPlayer {
  GameResearchPlayer({required this.latest, required List<PlayerGame> games})
    : games = List.unmodifiable(games);
  final PlayerGame latest;
  final List<PlayerGame> games;
  String get id => latest.playerId;
  String get name => latest.name;
  String get position => latest.position;
  String get team => latest.team;
  List<ResearchMetric> get metrics => researchMetrics(position);
}

class GameResearchSnapshot {
  const GameResearchSnapshot({
    required this.players,
    this.through,
    this.coverage,
    this.stale = false,
    this.notice,
  });
  final List<GameResearchPlayer> players;
  final DateTime? through, coverage;
  final bool stale;
  final String? notice;
}

DateTime _day(DateTime instant) {
  final wall = easternWall(instant);
  return DateTime.utc(wall.year, wall.month, wall.day);
}

/// Recorded participants, never a roster prediction. A player's newest allowed
/// identity determines the club; old clubs are not revived to fill a game list.
GameResearchSnapshot buildGameResearch({
  required PlayerStatsDataset data,
  required SportEvent event,
  required DateTime now,
}) {
  final today = _day(now);
  final eventDay = _day(event.startsAt);
  final researchDay = eventDay.isBefore(today) ? eventDay : today;
  final beforeDay = researchDay.subtract(const Duration(days: 1));
  final cutoff = parseEvidenceDay(data.metadata['cutoff']);
  final retrieved = parseEvidenceTimestamp(data.metadata['retrievedAt']);
  final season = data.metadata['currentSeason'];
  final eventSeason = eventDay.month <= 2 ? eventDay.year - 1 : eventDay.year;
  if (cutoff == null ||
      retrieved == null ||
      season is! int ||
      cutoff.isAfter(today) ||
      retrieved.isAfter(now.toUtc()) ||
      cutoff.isAfter(_day(retrieved))) {
    return const GameResearchSnapshot(
      players: [],
      notice: 'Player evidence dates could not be verified.',
    );
  }
  if (season != eventSeason) {
    return GameResearchSnapshot(
      players: const [],
      coverage: cutoff,
      notice: 'No player records for this game’s season are included yet.',
    );
  }
  final through = cutoff.isBefore(beforeDay) ? cutoff : beforeDay;
  final teams = {researchClub(event.away), researchClub(event.home)}
    ..remove('');
  if (teams.length != 2) {
    return GameResearchSnapshot(
      players: const [],
      through: through,
      coverage: cutoff,
      notice: 'This matchup could not be matched to the stored NFL teams.',
    );
  }
  final byPlayer = <String, List<PlayerGame>>{};
  for (final row in data.rows) {
    if (row.season == season && !row.date.isAfter(through)) {
      (byPlayer[row.playerId] ??= []).add(row);
    }
  }
  final players = <GameResearchPlayer>[];
  for (final rows in byPlayer.values) {
    rows.sort((a, b) {
      final date = b.date.compareTo(a.date);
      return date == 0 ? b.week.compareTo(a.week) : date;
    });
    final latest = rows.first;
    final club = researchClub(latest.team);
    if (!teams.contains(club) ||
        researchMetrics(latest.position).isEmpty ||
        today.difference(latest.date).inDays > 35 ||
        rows.where((row) => row.date == latest.date).length != 1) {
      continue;
    }
    final segment = <PlayerGame>[];
    for (final row in rows) {
      if (researchClub(row.team) != club ||
          row.seasonType != latest.seasonType) {
        break;
      }
      segment.add(row);
    }
    players.add(GameResearchPlayer(latest: latest, games: segment));
  }
  const positions = ['QB', 'RB', 'WR', 'TE'];
  players.sort((a, b) {
    final position = positions
        .indexOf(a.position)
        .compareTo(positions.indexOf(b.position));
    return position == 0 ? a.name.compareTo(b.name) : position;
  });
  final stale = today.difference(cutoff).inDays > 21;
  return GameResearchSnapshot(
    players: List.unmodifiable(players),
    through: through,
    coverage: cutoff,
    stale: stale,
    notice: stale
        ? 'Player evidence is older than 21 days. These are historical records.'
        : null,
  );
}

double? researchAverage(Iterable<PlayerGame> games, String metric) {
  final values = games
      .map((game) => game.stats[metric])
      .whereType<num>()
      .where((value) => value.isFinite)
      .toList();
  return values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
}
