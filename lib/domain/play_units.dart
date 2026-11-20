import 'matchup.dart';

/// November 20, 2026. Play-by-play EPA, success, pressure, sack rate,
/// third-down rate and pass rate over expected were scored inside the
/// opponent unit rating. None beat the served prop chance on Brier and log
/// loss in both 2025 and 2026. None beat the closing spread, moneyline and
/// total in both seasons. The card does not use them. The rematch answer
/// still quotes the play file, because that sentence is a count, not a
/// projection. The numbers are in docs/MATCHUPS.md.
const playUnitOnPropsAdopted = false;
const playUnitOnGamesAdopted = false;
const servedPlayUnitFeature = 'none';
const servedPlayGameFeature = 'none';

/// Plays of prior mixed in before a rate is used as a rating.
const playShrinkPlays = 200;
const playShrinkDropbacks = 40;
const playShrinkThirds = 8;
const playShrinkProe = 40;

/// One offense's counts for one game, from nflverse play-by-play.
class PlayGame {
  const PlayGame({
    required this.id,
    required this.season,
    required this.week,
    required this.seasonType,
    required this.team,
    required this.opponent,
    required this.plays,
    required this.epaSum,
    required this.successes,
    required this.dropbacks,
    required this.sacks,
    required this.hits,
    required this.thirdConverted,
    required this.thirdFailed,
    required this.passOeSum,
    required this.passOePlays,
  });

  final String id, seasonType, team, opponent;
  final int season, week, plays, successes, dropbacks, sacks, hits;
  final int thirdConverted, thirdFailed, passOePlays;
  final double epaSum, passOeSum;

  int get thirdPlays => thirdConverted + thirdFailed;

  factory PlayGame.fromJson(Map<String, dynamic> json) => PlayGame(
    id: '${json['id'] ?? ''}',
    season: json['season'] as int? ?? 0,
    week: json['week'] as int? ?? 0,
    seasonType: '${json['seasonType'] ?? ''}',
    team: '${json['team'] ?? ''}',
    opponent: '${json['opponent'] ?? ''}',
    plays: json['plays'] as int? ?? 0,
    epaSum: (json['epaSum'] as num?)?.toDouble() ?? 0,
    successes: json['successes'] as int? ?? 0,
    dropbacks: json['dropbacks'] as int? ?? 0,
    sacks: json['sacks'] as int? ?? 0,
    hits: json['hits'] as int? ?? 0,
    thirdConverted: json['thirdConverted'] as int? ?? 0,
    thirdFailed: json['thirdFailed'] as int? ?? 0,
    passOeSum: (json['passOeSum'] as num?)?.toDouble() ?? 0,
    passOePlays: json['passOePlays'] as int? ?? 0,
  );
}

class PlayTotals {
  int plays = 0;
  double epaSum = 0;
  int successes = 0;
  int dropbacks = 0;
  int sacks = 0;
  int hits = 0;
  int thirdConverted = 0;
  int thirdFailed = 0;
  double passOeSum = 0;
  int passOePlays = 0;

  void add(PlayGame game) {
    plays += game.plays;
    epaSum += game.epaSum;
    successes += game.successes;
    dropbacks += game.dropbacks;
    sacks += game.sacks;
    hits += game.hits;
    thirdConverted += game.thirdConverted;
    thirdFailed += game.thirdFailed;
    passOeSum += game.passOeSum;
    passOePlays += game.passOePlays;
  }
}

/// Rates after the shrink toward the league. Null when the league has no
/// plays of that kind yet.
class PlayRates {
  const PlayRates({
    this.epa,
    this.success,
    this.pressure,
    this.sack,
    this.third,
    this.proe,
  });

  final double? epa, success, pressure, sack, third, proe;

  static const empty = PlayRates();
}

class PlayPrior {
  const PlayPrior({
    required this.league,
    required Map<String, PlayRates> offense,
    required Map<String, PlayRates> defense,
  }) : _offense = offense,
       _defense = defense;

  final PlayRates league;
  final Map<String, PlayRates> _offense, _defense;

  PlayRates offense(String team) =>
      _offense[boxScoreTeam(team)] ?? league;

  PlayRates defense(String team) =>
      _defense[boxScoreTeam(team)] ?? league;
}

/// Team-game play rates. A prior for a week does not include that week.
class PlayBook {
  PlayBook._(this.games);
  final List<PlayGame> games;
  final Map<String, PlayGame> _byGame = {};
  final Map<String, PlayPrior> _prior = {};

  factory PlayBook.fromJson(Map<String, dynamic> json) {
    final rows = json['games'];
    final games = <PlayGame>[
      if (rows is List)
        for (final row in rows)
          if (row is Map) PlayGame.fromJson(Map<String, dynamic>.from(row)),
    ];
    return PlayBook._(games);
  }

  PlayGame? game(String id, String team) {
    if (_byGame.isEmpty) {
      for (final row in games) {
        _byGame['${row.id}|${row.team}'] = row;
      }
    }
    return _byGame['$id|${boxScoreTeam(team)}'];
  }

  /// Regular-season rates that were knowable before [season] week [week].
  PlayPrior before({required int season, required int week}) {
    final key = '$season-$week';
    return _prior.putIfAbsent(key, () {
      final offense = <String, PlayTotals>{};
      final defense = <String, PlayTotals>{};
      final league = PlayTotals();
      for (final row in games) {
        if (row.seasonType != 'REG') continue;
        final earlier =
            row.season < season || (row.season == season && row.week < week);
        if (!earlier) continue;
        league.add(row);
        (offense[row.team] ??= PlayTotals()).add(row);
        (defense[row.opponent] ??= PlayTotals()).add(row);
      }
      final leagueRates = _rates(league, null);
      PlayRates teamRates(PlayTotals? sample) => _rates(sample, leagueRates);
      return PlayPrior(
        league: leagueRates,
        offense: {
          for (final entry in offense.entries) entry.key: teamRates(entry.value),
        },
        defense: {
          for (final entry in defense.entries) entry.key: teamRates(entry.value),
        },
      );
    });
  }
}

PlayRates _rates(PlayTotals? sample, PlayRates? league) {
  final row = sample ?? PlayTotals();
  double? mix(double sum, int count, double? priorRate, int prior) {
    if (count <= 0 && priorRate == null) return null;
    if (priorRate == null || prior <= 0) {
      return count <= 0 ? null : sum / count;
    }
    return (sum + priorRate * prior) / (count + prior);
  }

  return PlayRates(
    epa: mix(row.epaSum, row.plays, league?.epa, playShrinkPlays),
    success: mix(
      row.successes.toDouble(),
      row.plays,
      league?.success,
      playShrinkPlays,
    ),
    pressure: mix(
      (row.sacks + row.hits).toDouble(),
      row.dropbacks,
      league?.pressure,
      playShrinkDropbacks,
    ),
    sack: mix(
      row.sacks.toDouble(),
      row.dropbacks,
      league?.sack,
      playShrinkDropbacks,
    ),
    third: mix(
      row.thirdConverted.toDouble(),
      row.thirdConverted + row.thirdFailed,
      league?.third,
      playShrinkThirds,
    ),
    proe: mix(row.passOeSum, row.passOePlays, league?.proe, playShrinkProe),
  );
}

/// How far a defense sits from the league, in precommitted steps.
///
/// Positive means an easier matchup for the offense. Pressure and sacks
/// flip that sign. Pass rate over expected is the opponent's own offense,
/// not a defensive rate: positive means they pass more than expected.
double? playRelative(String feature, PlayRates offense, PlayRates defense, PlayRates league) {
  double? gap(double? rate, double? base, double step, {bool lowerIsEasier = false}) {
    if (rate == null || base == null || step == 0) return null;
    final raw = lowerIsEasier ? (base - rate) / step : (rate - base) / step;
    return raw.isFinite ? raw : null;
  }

  switch (feature) {
    case 'epa':
      return gap(defense.epa, league.epa, 0.10);
    case 'success':
      return gap(defense.success, league.success, 0.05);
    case 'third':
      return gap(defense.third, league.third, 0.05);
    case 'pressure':
      return gap(defense.pressure, league.pressure, 0.05, lowerIsEasier: true);
    case 'sack':
      return gap(defense.sack, league.sack, 0.02, lowerIsEasier: true);
    case 'proe':
      return gap(offense.proe, league.proe, 10);
    case 'blend':
      final parts = [
        for (final name in ['epa', 'success', 'third', 'pressure', 'sack'])
          playRelative(name, offense, defense, league),
      ].whereType<double>();
      if (parts.isEmpty) return null;
      return parts.reduce((a, b) => a + b) / parts.length;
    default:
      return null;
  }
}

/// Multiplier for a projected mean. One step is a 15 percent move, and the
/// result stays inside the same 0.85 to 1.15 band as the box-score unit factor.
double playMeanFactor(double? relative) {
  if (relative == null || !relative.isFinite) return 1;
  return (1 + 0.15 * relative.clamp(-1.0, 1.0)).clamp(0.85, 1.15).toDouble();
}
