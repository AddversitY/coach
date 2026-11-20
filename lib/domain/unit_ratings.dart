import 'player_stats.dart';

/// Opponent-adjusted team units from player box scores.
///
/// A rating for a week uses only games from earlier weeks. Yards per attempt,
/// yards per carry, yards per target and sacks per dropback are the inputs.
/// Play-by-play EPA and down-to-down success rate are not in these rows, so
/// they are not invented here. Pass rush is sacks, not pressures.
enum UnitKey { pass, run, wr, te, rb, sack }

/// Walk-forward on the no-price path, November 20, 2026.
///
/// Weight 0.25 beat the stacked projection on 2025 and on 2026, on Brier
/// and log loss, with more than 1,000 games each year. It is the served
/// weight whenever the screen has no spread or no total.
const matchupAdjustmentAdopted = true;
const matchupRecencyWeight = 0.25;

/// Priced path, same date. The line is the previous season's median. The
/// closing spread and total come from the schedule file.
///
/// Dropping both the team-total scale and the raw defense-yards scale, and
/// using one opponent unit factor plus the shrunk sensitivity, beat the
/// stacked path and beat "keep the total, then multiply by the unit."
/// Both years, Brier and log loss, more than 1,000 games. The numbers are
/// in docs/MATCHUPS.md. This is not a profit test.
const pricedPathDropsStackedScales = true;

/// November 20, 2026. A unit-versus-unit nudge, with and without recent
/// closing-line form, did not beat the closing spread, moneyline, or total
/// on both 2025 and 2026. Served game numbers stay on version 2.
const gameUnitAdjustmentAdopted = false;

enum UnitTier { elite, average, weak, unavailable }

class UnitRating {
  const UnitRating({
    required this.team,
    required this.unit,
    required this.offense,
    required this.tier,
    required this.games,
    required this.teams,
    this.rank,
    this.versusLeague,
    this.leagueRate,
  });

  final String team;
  final UnitKey unit;

  /// True for the offense's own rate, false for the defense it faces.
  final bool offense;
  final UnitTier tier;
  final int games;

  /// Clubs with enough earlier games to be ranked.
  final int teams;

  /// 1 is the best. Null when the club does not have enough earlier games.
  final int? rank;

  /// Opponent-adjusted rate minus the league rate. For a defense against
  /// yards, negative means it allows less. For pass rush, positive means
  /// more sacks per dropback.
  final double? versusLeague;
  final double? leagueRate;

  bool get ranked => rank != null && tier != UnitTier.unavailable;

  String get unitLabel => switch (unit) {
    UnitKey.pass => offense ? 'pass offense' : 'pass defense',
    UnitKey.run => offense ? 'run offense' : 'run defense',
    UnitKey.wr => offense ? 'WR receiving' : 'defense vs WR',
    UnitKey.te => offense ? 'TE receiving' : 'defense vs TE',
    UnitKey.rb => offense ? 'RB receiving' : 'defense vs RB',
    UnitKey.sack => offense ? 'pass protection' : 'pass rush',
  };

  String get tierLabel => switch (tier) {
    UnitTier.elite => 'Elite',
    UnitTier.average => 'Average',
    UnitTier.weak => 'Weak',
    UnitTier.unavailable => 'Unavailable',
  };

  /// One line for the top of an answer. Ranked defenses read as the matchup
  /// the offense is about to face.
  String get sentence {
    if (!ranked || versusLeague == null) {
      return '$team $unitLabel is unavailable. Fewer than three earlier games.';
    }
    final direction = versusLeague!.abs() < 0.05
        ? 'about average'
        : offense
        ? (versusLeague! > 0 ? 'above average' : 'below average')
        : _defenseQuality;
    final amount = versusLeague!.abs().toStringAsFixed(2);
    return '$team $unitLabel ranks $rank of $teams ($tierLabel, $direction, $amount vs the league rate, $games earlier games).';
  }

  String get _defenseQuality {
    final better = switch (unit) {
      UnitKey.sack => versusLeague! > 0,
      _ => versusLeague! < 0,
    };
    return better ? 'tougher than average' : 'easier than average';
  }
}

class UnitSnapshot {
  const UnitSnapshot(this._ratings);
  final Map<String, UnitRating> _ratings;

  UnitRating? lookup(String team, UnitKey unit, {required bool offense}) =>
      _ratings['${team.toUpperCase()}|${unit.name}|$offense'];

  List<UnitRating> forTeam(String team) => [
    for (final rating in _ratings.values)
      if (rating.team == team.toUpperCase()) rating,
  ];
}

class _TeamWeek {
  _TeamWeek(this.team, this.opponent, this.season, this.week, this.date);
  final String team, opponent;
  final int season, week;
  final DateTime date;
  double passYds = 0, attempts = 0, completions = 0, sacks = 0;
  double rushYds = 0, carries = 0;
  double wrYds = 0, wrTargets = 0, teYds = 0, teTargets = 0;
  double rbYds = 0, rbTargets = 0;
}

class _Obs {
  const _Obs(this.offense, this.defense, this.rate, this.volume);
  final String offense, defense;
  final double rate, volume;
}

class _Fit {
  const _Fit({
    required this.league,
    required this.offense,
    required this.defense,
    required this.offenseGames,
    required this.defenseGames,
  });
  final double league;
  final Map<String, double> offense, defense;
  final Map<String, int> offenseGames, defenseGames;
}

/// Ratings cached by the week they are allowed to use.
class RatingBook {
  RatingBook._(this._weeks);
  final List<_TeamWeek> _weeks;
  final Map<String, UnitSnapshot> _cache = {};

  factory RatingBook.build(Iterable<PlayerGame> rows) {
    final grouped = <String, _TeamWeek>{};
    for (final game in rows) {
      if (game.seasonType != 'REG' || game.opponent.isEmpty) continue;
      final key = '${game.season}|${game.week}|${game.team}';
      final week = grouped.putIfAbsent(
        key,
        () => _TeamWeek(
          game.team,
          game.opponent,
          game.season,
          game.week,
          DateTime.utc(game.date.year, game.date.month, game.date.day),
        ),
      );
      final stats = game.stats;
      week.passYds += stats['passing_yards']?.toDouble() ?? 0;
      week.attempts += stats['attempts']?.toDouble() ?? 0;
      week.completions += stats['completions']?.toDouble() ?? 0;
      week.sacks += stats['sacks_suffered']?.toDouble() ?? 0;
      week.rushYds += stats['rushing_yards']?.toDouble() ?? 0;
      week.carries += stats['carries']?.toDouble() ?? 0;
      final targets = stats['targets']?.toDouble() ?? 0;
      final yards = stats['receiving_yards']?.toDouble() ?? 0;
      switch (game.position) {
        case 'WR':
          week.wrYds += yards;
          week.wrTargets += targets;
          break;
        case 'TE':
          week.teYds += yards;
          week.teTargets += targets;
          break;
        case 'RB':
          week.rbYds += yards;
          week.rbTargets += targets;
          break;
        default:
          break;
      }
    }
    final weeks = grouped.values.toList()
      ..sort((a, b) {
        final season = a.season.compareTo(b.season);
        if (season != 0) return season;
        final week = a.week.compareTo(b.week);
        if (week != 0) return week;
        return a.team.compareTo(b.team);
      });
    return RatingBook._(weeks);
  }

  /// Ratings that could have been known before [season] week [week].
  UnitSnapshot before({
    required int season,
    required int week,
    DateTime? date,
  }) {
    final day = date == null
        ? null
        : DateTime.utc(date.year, date.month, date.day);
    final key = day == null ? '$season-$week' : day.toIso8601String();
    return _cache.putIfAbsent(key, () {
      final prior = [
        for (final row in _weeks)
          if (day != null
              ? row.date.isBefore(day)
              : row.season < season ||
                    (row.season == season && row.week < week))
            row,
      ];
      return _snapshot(prior);
    });
  }
}

UnitSnapshot _snapshot(List<_TeamWeek> weeks) {
  final ratings = <String, UnitRating>{};
  void add(UnitKey unit, _Fit? fit, {required bool lowerDefenseIsBetter}) {
    if (fit == null) return;
    _place(
      ratings,
      fit,
      unit: unit,
      offense: true,
      lowerIsBetter: unit == UnitKey.sack,
    );
    _place(
      ratings,
      fit,
      unit: unit,
      offense: false,
      lowerIsBetter: lowerDefenseIsBetter,
    );
  }

  add(
    UnitKey.pass,
    _fit(
      weeks,
      (row) => row.attempts >= 10 ? (row.passYds, row.attempts) : null,
      100,
    ),
    lowerDefenseIsBetter: true,
  );
  add(
    UnitKey.run,
    _fit(
      weeks,
      (row) => row.carries >= 8 ? (row.rushYds, row.carries) : null,
      50,
    ),
    lowerDefenseIsBetter: true,
  );
  add(
    UnitKey.wr,
    _fit(
      weeks,
      (row) => row.wrTargets >= 3 ? (row.wrYds, row.wrTargets) : null,
      25,
    ),
    lowerDefenseIsBetter: true,
  );
  add(
    UnitKey.te,
    _fit(
      weeks,
      (row) => row.teTargets >= 2 ? (row.teYds, row.teTargets) : null,
      20,
    ),
    lowerDefenseIsBetter: true,
  );
  add(
    UnitKey.rb,
    _fit(
      weeks,
      (row) => row.rbTargets >= 2 ? (row.rbYds, row.rbTargets) : null,
      16,
    ),
    lowerDefenseIsBetter: true,
  );
  add(
    UnitKey.sack,
    _fit(
      weeks,
      (row) => row.attempts >= 10 ? (row.sacks, row.attempts) : null,
      80,
    ),
    lowerDefenseIsBetter: false,
  );
  return UnitSnapshot(ratings);
}

_Fit? _fit(
  List<_TeamWeek> weeks,
  (double, double)? Function(_TeamWeek row) read,
  double prior,
) {
  final observations = <_Obs>[];
  for (final row in weeks) {
    final value = read(row);
    if (value == null || value.$2 <= 0) continue;
    observations.add(
      _Obs(row.team, row.opponent, value.$1 / value.$2, value.$2),
    );
  }
  if (observations.length < 8) return null;
  var weight = 0.0, weighted = 0.0;
  for (final row in observations) {
    weight += row.volume;
    weighted += row.rate * row.volume;
  }
  final league = weighted / weight;
  final teams = {
    for (final row in observations) ...[row.offense, row.defense],
  };
  final offense = {for (final team in teams) team: 0.0};
  final defense = {for (final team in teams) team: 0.0};
  final offenseGames = {for (final team in teams) team: 0};
  final defenseGames = {for (final team in teams) team: 0};
  for (final row in observations) {
    offenseGames[row.offense] = offenseGames[row.offense]! + 1;
    defenseGames[row.defense] = defenseGames[row.defense]! + 1;
  }
  for (var iteration = 0; iteration < 6; iteration++) {
    final offenseNum = {for (final team in teams) team: 0.0};
    final offenseDen = {for (final team in teams) team: prior};
    final defenseNum = {for (final team in teams) team: 0.0};
    final defenseDen = {for (final team in teams) team: prior};
    for (final row in observations) {
      offenseNum[row.offense] =
          offenseNum[row.offense]! +
          row.volume * (row.rate - league - defense[row.defense]!);
      offenseDen[row.offense] = offenseDen[row.offense]! + row.volume;
      defenseNum[row.defense] =
          defenseNum[row.defense]! +
          row.volume * (row.rate - league - offense[row.offense]!);
      defenseDen[row.defense] = defenseDen[row.defense]! + row.volume;
    }
    for (final team in teams) {
      offense[team] = offenseNum[team]! / offenseDen[team]!;
      defense[team] = defenseNum[team]! / defenseDen[team]!;
    }
  }
  return _Fit(
    league: league,
    offense: offense,
    defense: defense,
    offenseGames: offenseGames,
    defenseGames: defenseGames,
  );
}

void _place(
  Map<String, UnitRating> into,
  _Fit fit, {
  required UnitKey unit,
  required bool offense,
  required bool lowerIsBetter,
}) {
  final values = offense ? fit.offense : fit.defense;
  final games = offense ? fit.offenseGames : fit.defenseGames;
  final eligible =
      [
        for (final team in values.keys)
          if ((games[team] ?? 0) >= 3) team,
      ]..sort((a, b) {
        final left = values[a]!;
        final right = values[b]!;
        final order = lowerIsBetter
            ? left.compareTo(right)
            : right.compareTo(left);
        return order != 0 ? order : a.compareTo(b);
      });
  final count = eligible.length;
  if (count == 0) return;
  final eliteCut = count >= 24 ? 8 : (count / 4).ceil().clamp(1, count);
  final weakCut = count >= 24 ? count - 8 : count - (count / 4).floor();
  for (var index = 0; index < eligible.length; index++) {
    final team = eligible[index];
    final rank = index + 1;
    final tier = rank <= eliteCut
        ? UnitTier.elite
        : rank > weakCut
        ? UnitTier.weak
        : UnitTier.average;
    into['$team|${unit.name}|$offense'] = UnitRating(
      team: team,
      unit: unit,
      offense: offense,
      tier: tier,
      games: games[team] ?? 0,
      teams: count,
      rank: rank,
      versusLeague: values[team],
      leagueRate: fit.league,
    );
  }
}

class TierSplit {
  const TierSplit({
    required this.tier,
    required this.games,
    required this.overs,
    required this.unders,
    required this.pushes,
    this.rawAverage,
    this.shrunkAverage,
  });

  final UnitTier tier;
  final int games, overs, unders, pushes;
  final double? rawAverage;

  /// Pulled toward the player's own earlier average. A short tier cannot
  /// read like a certain rate.
  final double? shrunkAverage;
  bool get smallSample => games < 8;
  int get decided => overs + unders;
}

class PlayerSplits {
  const PlayerSplits({
    required this.player,
    required this.metric,
    required this.unit,
    required this.tiers,
    required this.summary,
    this.line,
  });

  final String player, metric;
  final UnitKey unit;
  final double? line;
  final List<TierSplit> tiers;
  final String summary;

  TierSplit? operator [](UnitTier tier) {
    for (final split in tiers) {
      if (split.tier == tier) return split;
    }
    return null;
  }
}

/// How a player has produced against the defense's tier at the time, using
/// only games before [beforeSeason]/[beforeWeek].
PlayerSplits? playerSplits({
  required RatingBook book,
  required List<PlayerGame> games,
  required String metric,
  double? line,
  required int beforeSeason,
  required int beforeWeek,
}) {
  final prior =
      [
        for (final game in games)
          if (game.seasonType == 'REG' &&
              (game.season < beforeSeason ||
                  (game.season == beforeSeason && game.week < beforeWeek)) &&
              game.stats[metric] != null)
            game,
      ]..sort((a, b) {
        final season = a.season.compareTo(b.season);
        return season != 0 ? season : a.week.compareTo(b.week);
      });
  if (prior.isEmpty) return null;
  final position = prior.last.position;
  final unit = switch (metric) {
    'passing_yards' => UnitKey.pass,
    'rushing_yards' => UnitKey.run,
    'receiving_yards' || 'receptions' => switch (position) {
      'WR' => UnitKey.wr,
      'TE' => UnitKey.te,
      'RB' => UnitKey.rb,
      _ => null,
    },
    _ => null,
  };
  if (unit == null) return null;
  final buckets = {for (final tier in UnitTier.values) tier: <PlayerGame>[]};
  var total = 0.0, counted = 0;
  for (final game in prior) {
    final value = game.stats[metric]!.toDouble();
    total += value;
    counted++;
    final defense = book
        .before(season: game.season, week: game.week)
        .lookup(game.opponent, unit, offense: false);
    buckets[defense?.tier ?? UnitTier.unavailable]!.add(game);
  }
  final anchor = counted == 0 ? null : total / counted;
  TierSplit split(UnitTier tier) {
    final rows = buckets[tier]!;
    var overs = 0, unders = 0, pushes = 0, sum = 0.0;
    for (final game in rows) {
      final value = game.stats[metric]!.toDouble();
      sum += value;
      if (line == null) continue;
      if (value > line) {
        overs++;
      } else if (value < line) {
        unders++;
      } else {
        pushes++;
      }
    }
    final raw = rows.isEmpty ? null : sum / rows.length;
    final shrunk = raw == null || anchor == null
        ? null
        : (rows.length * raw + 8 * anchor) / (rows.length + 8);
    return TierSplit(
      tier: tier,
      games: rows.length,
      overs: overs,
      unders: unders,
      pushes: pushes,
      rawAverage: raw,
      shrunkAverage: shrunk,
    );
  }

  final tiers = [
    split(UnitTier.elite),
    split(UnitTier.average),
    split(UnitTier.weak),
  ];
  final asked = tiers.firstWhere(
    (row) => row.games > 0,
    orElse: () => tiers.first,
  );
  final lineText = line == null
      ? ''
      : ' Against ${line.toStringAsFixed(1)}: ${asked.overs} over, ${asked.unders} under'
            '${asked.pushes > 0 ? ', ${asked.pushes} push' : ''}.';
  final average = asked.rawAverage?.toStringAsFixed(1) ?? 'no games';
  return PlayerSplits(
    player: prior.last.name,
    metric: metric,
    unit: unit,
    line: line,
    tiers: tiers,
    summary:
        '${prior.last.name} vs ${asked.tier.name} ${unit.name} defenses: $average per game across ${asked.games} games.${asked.smallSample ? ' Small sample, shrunk toward the player\'s own average.' : ''}$lineText',
  );
}

/// One multiplier for the opponent. The served card uses [unitFactor] and
/// [sensitivity] in place of a team-total scale plus a raw yards-allowed
/// scale. [priceUnit] is the rejected experiment that kept the team total
/// and also multiplied by [unitFactor].
class MatchupEnvironment {
  const MatchupEnvironment({
    required this.known,
    required this.unitFactor,
    required this.sensitivity,
    required this.detail,
    this.priceUnit = false,
  });

  final bool known;

  /// Also multiply by [unitFactor] while keeping the team-total scale.
  /// The fair-line test did not adopt this. The served card leaves it false
  /// and drops the team-total scale instead.
  final bool priceUnit;

  /// Opponent unit rating. The served card uses this in place of the old
  /// defense multiplier and the points-scored script.
  final double unitFactor;

  /// Player-specific response, shrunk toward no extra response. Applied
  /// once. Clamped so a short sample cannot force the projection cap.
  final double sensitivity;
  final String detail;

  static const unused = MatchupEnvironment(
    known: false,
    unitFactor: 1,
    sensitivity: 1,
    detail: 'Matchup adjustment unavailable.',
  );

  MatchupEnvironment copyWith({bool? priceUnit}) => MatchupEnvironment(
    known: known,
    unitFactor: unitFactor,
    sensitivity: sensitivity,
    detail: detail,
    priceUnit: priceUnit ?? this.priceUnit,
  );
}

MatchupEnvironment matchupEnvironment({
  required RatingBook book,
  required List<PlayerGame> playerGames,
  required String metric,
  required String opponent,
  required int beforeSeason,
  required int beforeWeek,
  DateTime? beforeDate,
  double recencyWeight = 0,
}) {
  if (playerGames.isEmpty) return MatchupEnvironment.unused;
  PlayerGame? latest;
  for (final game in playerGames) {
    if (!_earlierGame(
      game,
      season: beforeSeason,
      week: beforeWeek,
      date: beforeDate,
    )) {
      continue;
    }
    if (latest == null || game.date.isAfter(latest.date)) latest = game;
  }
  if (latest == null) return MatchupEnvironment.unused;
  final position = latest.position;
  final unit = switch (metric) {
    'passing_yards' => UnitKey.pass,
    'rushing_yards' => UnitKey.run,
    'receiving_yards' || 'receptions' => switch (position) {
      'WR' => UnitKey.wr,
      'TE' => UnitKey.te,
      'RB' => UnitKey.rb,
      _ => null,
    },
    _ => null,
  };
  if (unit == null) return MatchupEnvironment.unused;
  final now = book.before(
    season: beforeSeason,
    week: beforeWeek,
    date: beforeDate,
  );
  final defense = now.lookup(opponent, unit, offense: false);
  if (defense == null ||
      defense.versusLeague == null ||
      defense.leagueRate == null) {
    return MatchupEnvironment.unused;
  }
  final league = defense.leagueRate!;
  if (league.abs() < 1e-6) return MatchupEnvironment.unused;
  final unitFactor = (1 + defense.versusLeague! / league).clamp(0.85, 1.15);
  final sensitivity = _tilt(
    _shrunkSlope(
      book: book,
      games: playerGames,
      metric: metric,
      unit: unit,
      beforeSeason: beforeSeason,
      beforeWeek: beforeWeek,
      beforeDate: beforeDate,
    ),
    defense.versusLeague!,
    league,
  );
  final recent = _recency(
    book: book,
    games: playerGames,
    metric: metric,
    unit: unit,
    beforeSeason: beforeSeason,
    beforeWeek: beforeWeek,
    beforeDate: beforeDate,
    weight: recencyWeight,
    league: league,
  );
  return MatchupEnvironment(
    known: true,
    unitFactor: unitFactor.toDouble(),
    sensitivity: sensitivity * recent,
    detail: defense.sentence,
  );
}

/// Yards-per-play response to opponent allowance, shrunk toward zero with an
/// eight-game prior. Zero when the player does not have six earlier games
/// with a known opponent rating.
double _shrunkSlope({
  required RatingBook book,
  required List<PlayerGame> games,
  required String metric,
  required UnitKey unit,
  required int beforeSeason,
  required int beforeWeek,
  DateTime? beforeDate,
}) {
  final xs = <double>[];
  final ys = <double>[];
  for (final game in games) {
    if (!_earlierGame(
      game,
      season: beforeSeason,
      week: beforeWeek,
      date: beforeDate,
    )) {
      continue;
    }
    final volume = _volume(game, metric);
    final value = game.stats[metric]?.toDouble();
    if (volume == null || volume <= 0 || value == null) continue;
    final defense = book
        .before(season: game.season, week: game.week)
        .lookup(game.opponent, unit, offense: false);
    final allowance = defense?.versusLeague;
    if (allowance == null) continue;
    xs.add(allowance);
    ys.add(value / volume);
  }
  if (xs.length < 6) return 0;
  return xs.length * _slope(xs, ys) / (xs.length + 8);
}

double _tilt(double slope, double allowance, double league) {
  if (league.abs() < 1e-6) return 1;
  final raw = 1 + slope * allowance / league;
  if (!raw.isFinite) return 1;
  return raw.clamp(0.94, 1.06).toDouble();
}

double _slope(List<double> xs, List<double> ys) {
  final n = xs.length;
  var meanX = 0.0, meanY = 0.0;
  for (var i = 0; i < n; i++) {
    meanX += xs[i];
    meanY += ys[i];
  }
  meanX /= n;
  meanY /= n;
  var numerator = 0.0, den = 0.0;
  for (var i = 0; i < n; i++) {
    final dx = xs[i] - meanX;
    numerator += dx * (ys[i] - meanY);
    den += dx * dx;
  }
  if (den < 1e-8) return 0;
  return numerator / den;
}

bool _earlierGame(
  PlayerGame game, {
  required int season,
  required int week,
  DateTime? date,
}) {
  if (date != null) {
    final gameDay = DateTime.utc(
      game.date.year,
      game.date.month,
      game.date.day,
    );
    final limit = DateTime.utc(date.year, date.month, date.day);
    return gameDay.isBefore(limit);
  }
  return game.season < season || (game.season == season && game.week < week);
}

double? _volume(PlayerGame game, String metric) => switch (metric) {
  'passing_yards' => game.stats['attempts']?.toDouble(),
  'rushing_yards' => game.stats['carries']?.toDouble(),
  'receiving_yards' || 'receptions' => game.stats['targets']?.toDouble(),
  _ => null,
};

double _recency({
  required RatingBook book,
  required List<PlayerGame> games,
  required String metric,
  required UnitKey unit,
  required int beforeSeason,
  required int beforeWeek,
  DateTime? beforeDate,
  required double weight,
  required double league,
}) {
  if (weight <= 0 || league.abs() < 1e-6) return 1;
  final prior = [
    for (final game in games)
      if (_earlierGame(
        game,
        season: beforeSeason,
        week: beforeWeek,
        date: beforeDate,
      ))
        game,
  ];
  if (prior.length < 5) return 1;
  double? residual(PlayerGame game) {
    final value = game.stats[metric]?.toDouble();
    final volume = _volume(game, metric);
    final defense = book
        .before(season: game.season, week: game.week)
        .lookup(game.opponent, unit, offense: false);
    if (value == null ||
        volume == null ||
        volume <= 0 ||
        defense?.versusLeague == null ||
        defense?.leagueRate == null) {
      return null;
    }
    return value / volume - (defense!.leagueRate! + defense.versusLeague!);
  }

  final seasonValues = [for (final game in prior) ?residual(game)];
  final recentGames = prior.length <= 5
      ? prior
      : prior.sublist(prior.length - 5);
  final recentValues = [for (final game in recentGames) ?residual(game)];
  if (seasonValues.length < 5 || recentValues.length < 3) return 1;
  final seasonMean = seasonValues.reduce((a, b) => a + b) / seasonValues.length;
  final recentMean = recentValues.reduce((a, b) => a + b) / recentValues.length;
  final blended =
      1 + weight.clamp(0.0, 1.0) * ((recentMean - seasonMean) / league);
  if (!blended.isFinite) return 1;
  return blended.clamp(0.9, 1.1).toDouble();
}
