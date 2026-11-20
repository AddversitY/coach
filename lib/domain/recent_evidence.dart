import 'player_stats.dart';

/// A completed game from the nflverse schedule, including the head coaches
/// the schedule names. [spreadLine] is the home team's expected margin:
/// positive means the home club was favored.
class RecentGame {
  const RecentGame({
    required this.id,
    required this.season,
    required this.week,
    required this.date,
    required this.home,
    required this.away,
    required this.homeScore,
    required this.awayScore,
    this.spreadLine,
    this.totalLine,
    this.homeCoach,
    this.awayCoach,
    this.homeRest,
    this.awayRest,
  });

  final String id, home, away;
  final int season, week, homeScore, awayScore;
  final DateTime date;
  final double? spreadLine, totalLine;
  final String? homeCoach, awayCoach;
  final int? homeRest, awayRest;

  bool involves(String a, String b) {
    final clubs = {home, away};
    return clubs.contains(a) && clubs.contains(b);
  }

  factory RecentGame.fromJson(Map<String, dynamic> json) => RecentGame(
    id: json['id'] as String,
    season: json['season'] as int,
    week: json['week'] as int,
    date: DateTime.parse(json['date'] as String),
    home: json['home'] as String,
    away: json['away'] as String,
    homeScore: json['homeScore'] as int,
    awayScore: json['awayScore'] as int,
    spreadLine: (json['spreadLine'] as num?)?.toDouble(),
    totalLine: (json['totalLine'] as num?)?.toDouble(),
    homeCoach: json['homeCoach'] as String?,
    awayCoach: json['awayCoach'] as String?,
    homeRest: json['homeRest'] as int?,
    awayRest: json['awayRest'] as int?,
  );
}

/// One club's box score from nflverse team weekly stats.
class TeamWeek {
  const TeamWeek({
    required this.gameId,
    required this.season,
    required this.week,
    required this.date,
    required this.team,
    required this.opponent,
    this.attempts,
    this.carries,
    this.passingYards,
    this.rushingYards,
    this.sackYardsLost,
    this.passingInterceptions,
    this.fumblesLost,
    this.passingEpa,
    this.rushingEpa,
    this.defInterceptions,
  });

  final String gameId, team, opponent;
  final int season, week;
  final DateTime date;
  final double? attempts, carries, passingYards, rushingYards, sackYardsLost;
  final double? passingInterceptions, fumblesLost, passingEpa, rushingEpa;
  final double? defInterceptions;

  /// Passing yards plus the file's sack-yard figure plus rushing yards.
  /// In the 2026 file, sack yards are negative, and this sum matches the
  /// official team total. Null when any piece is missing.
  double? get netYards {
    final pass = passingYards, sack = sackYardsLost, rush = rushingYards;
    if (pass == null || sack == null || rush == null) return null;
    return pass + sack + rush;
  }

  int? get giveaways {
    final interceptions = passingInterceptions, fumbles = fumblesLost;
    if (interceptions == null || fumbles == null) return null;
    return interceptions.round() + fumbles.round();
  }

  factory TeamWeek.fromJson(Map<String, dynamic> json) => TeamWeek(
    gameId: json['gameId'] as String,
    season: json['season'] as int,
    week: json['week'] as int,
    date: DateTime.parse(json['date'] as String),
    team: json['team'] as String,
    opponent: json['opponent'] as String,
    attempts: (json['attempts'] as num?)?.toDouble(),
    carries: (json['carries'] as num?)?.toDouble(),
    passingYards: (json['passingYards'] as num?)?.toDouble(),
    rushingYards: (json['rushingYards'] as num?)?.toDouble(),
    sackYardsLost: (json['sackYardsLost'] as num?)?.toDouble(),
    passingInterceptions: (json['passingInterceptions'] as num?)?.toDouble(),
    fumblesLost: (json['fumblesLost'] as num?)?.toDouble(),
    passingEpa: (json['passingEpa'] as num?)?.toDouble(),
    rushingEpa: (json['rushingEpa'] as num?)?.toDouble(),
    defInterceptions: (json['defInterceptions'] as num?)?.toDouble(),
  );
}

class InjuryNote {
  const InjuryNote({
    required this.week,
    required this.team,
    required this.player,
    required this.position,
    required this.status,
    this.practice = '',
    this.injury = '',
  });

  final int week;
  final String team, player, position, status, practice, injury;
  bool get listedOut => status == 'Out' || status == 'Doubtful';

  factory InjuryNote.fromJson(Map<String, dynamic> json) => InjuryNote(
    week: json['week'] as int,
    team: json['team'] as String,
    player: json['player'] as String,
    position: (json['position'] as String?) ?? '',
    status: (json['status'] as String?) ?? '',
    practice: (json['practice'] as String?) ?? '',
    injury: (json['injury'] as String?) ?? '',
  );
}

class RecentEvidence {
  const RecentEvidence({
    required this.games,
    required this.teamWeeks,
    required this.players,
    required this.injuries,
    required this.sources,
    required this.notice,
    this.mainBundleCutoff,
  });

  final List<RecentGame> games;
  final List<TeamWeek> teamWeeks;
  final List<PlayerGame> players;
  final List<InjuryNote> injuries;
  final List<String> sources;
  final String notice;
  final String? mainBundleCutoff;

  factory RecentEvidence.fromJson(Map<String, dynamic> json) {
    final sources = <String>[];
    final rawSources = json['sources'];
    if (rawSources is List) {
      for (final source in rawSources) {
        if (source is Map && source['url'] is String) {
          sources.add(source['url'] as String);
        }
      }
    }
    return RecentEvidence(
      games: [
        for (final row in json['games'] as List)
          RecentGame.fromJson(Map<String, dynamic>.from(row as Map)),
      ],
      teamWeeks: [
        for (final row in json['teamWeeks'] as List)
          TeamWeek.fromJson(Map<String, dynamic>.from(row as Map)),
      ],
      players: [
        for (final row in json['players'] as List)
          PlayerGame.fromJson(Map<String, dynamic>.from(row as Map)),
      ],
      injuries: [
        for (final row in json['injuries'] as List)
          InjuryNote.fromJson(Map<String, dynamic>.from(row as Map)),
      ],
      sources: sources,
      notice: (json['notice'] as String?) ?? '',
      mainBundleCutoff: json['mainBundleCutoff'] as String?,
    );
  }
}
