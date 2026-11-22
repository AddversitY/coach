import 'matchup.dart';
import 'player_stats.dart';
import 'prop_context.dart';

/// November 22, 2026. These sizes were written down before the 2025 and
/// 2026 scores. They are not a search over those seasons.
///
/// The card already turns recent targets, carries, and dropbacks into a
/// share. This layer moves that share only when earlier playing time, or a
/// teammate who is newly listed Out, says the role changed. A missing snap
/// or route share stays unused. It is not filled in.
const playingTimeRoleBand = 0.15;
const playingTimeRoleKeep = 0.35;
const playingTimeRoleFloor = 0.90;
const playingTimeRoleCeil = 1.10;
const playingTimeInjuryTransfer = 0.40;
const playingTimeInjuryCeil = 1.18;
const playingTimeInjuryMinShare = 0.15;
const playingTimeReturnKeep = 0.50;
const playingTimeReturnFloor = 0.90;
const playingTimeQbBelief = 2.0;
const playingTimeQbShare = 0.85;
const playingTimeQbCeil = 4.0;
const playingTimeQbMinStarter = 0.55;
const playingTimeStackFloor = 0.88;
const playingTimeStackCeil = 1.22;

/// On the card only when the walk-forward in
/// `test/playing_time_test.dart` beats the current chance on Brier, log
/// loss, and projection error in both 2025 and 2026.
const playingTimeAdopted = false;

/// Which earlier playing-time series the role change used.
enum PlayingTimeBasis { route, snap, unavailable }

/// A multiplier on the current projection. 1 leaves it where it is.
class PlayingTimeMove {
  const PlayingTimeMove({
    required this.factor,
    required this.detail,
    required this.basis,
    required this.routeUnavailable,
  });

  final double factor;
  final String detail;
  final PlayingTimeBasis basis;

  /// Receivers prefer route share. True when that series was not there
  /// and snap share was the fallback, or neither series was there.
  final bool routeUnavailable;

  static const unchanged = PlayingTimeMove(
    factor: 1,
    detail: 'No playing-time change.',
    basis: PlayingTimeBasis.unavailable,
    routeUnavailable: false,
  );
}

class _Game {
  _Game({
    required this.season,
    required this.week,
    required this.team,
    required this.position,
    required this.targets,
    required this.carries,
    required this.attempts,
    this.snap,
    this.route,
  });

  final int season, week;
  final String team, position;
  final double targets, carries, attempts;
  final double? snap, route;
}

class _Out {
  const _Out(this.name, this.position);
  final String name, position;
}

class _Volume {
  double targets = 0, carries = 0, attempts = 0;
}

class _Share {
  const _Share(this.value, this.games);
  final double value;
  final int games;
}

/// Earlier games, snap and route shares, and the weekly Out list.
///
/// A lookup uses weeks strictly before the game. The Out list for the
/// week being scored is the pregame report. That week's box score is not
/// an input. Shares come from the derived nflverse file (CC BY 4.0).
class PlayingTimeBook {
  PlayingTimeBook._({
    required this._games,
    required this._volume,
    required this._outs,
    required this._outWeeks,
    required this._idByName,
    required this._byTeam,
    required this._teamWeeks,
  });

  final Map<String, List<_Game>> _games;
  final Map<String, _Volume> _volume;
  final Map<String, List<_Out>> _outs;
  final Map<String, List<(int, int)>> _outWeeks;
  final Map<String, String> _idByName;
  final Map<String, Set<String>> _byTeam;
  final Map<String, List<(int, int)>> _teamWeeks;

  factory PlayingTimeBook.build({
    required List<PlayerGame> games,
    required UsageBook shares,
    required List<List<dynamic>> outs,
  }) {
    final playing = <String, ({double? snap, double? route})>{};
    shares.forEachShare((id, week) {
      playing['$id|${week.season}|${week.week}'] = (
        snap: _unit(week.snap),
        route: _unit(week.route),
      );
    });
    final rows = <String, List<_Game>>{};
    final volume = <String, _Volume>{};
    final idsByName = <String, Set<String>>{};
    final byTeam = <String, Set<String>>{};
    final teamWeeks = <String, Set<String>>{};
    for (final game in games) {
      if (game.seasonType != 'REG') continue;
      final team = boxScoreTeam(game.team);
      final share = playing['${game.playerId}|${game.season}|${game.week}'];
      (rows[game.playerId] ??= []).add(
        _Game(
          season: game.season,
          week: game.week,
          team: team,
          position: game.position,
          targets: game.stats['targets']?.toDouble() ?? 0,
          carries: game.stats['carries']?.toDouble() ?? 0,
          attempts: game.stats['attempts']?.toDouble() ?? 0,
          snap: share?.snap,
          route: share?.route,
        ),
      );
      final club = volume.putIfAbsent(
        _key(game.season, game.week, team),
        _Volume.new,
      );
      club.targets += game.stats['targets']?.toDouble() ?? 0;
      club.carries += game.stats['carries']?.toDouble() ?? 0;
      club.attempts += game.stats['attempts']?.toDouble() ?? 0;
      final name = playingTimeName(game.name);
      if (name.isNotEmpty) (idsByName[name] ??= {}).add(game.playerId);
      (byTeam[team] ??= {}).add(game.playerId);
      (teamWeeks[team] ??= {}).add('${game.season}|${game.week}');
    }
    for (final list in rows.values) {
      list.sort(_order);
    }
    final idByName = <String, String>{
      for (final entry in idsByName.entries)
        if (entry.value.length == 1) entry.key: entry.value.single,
    };
    final listed = <String, List<_Out>>{};
    final outWeeks = <String, List<(int, int)>>{};
    for (final row in outs) {
      if (row.length < 4) continue;
      final season = row[0];
      final week = row[1];
      if (season is! int || week is! int) continue;
      final team = boxScoreTeam('${row[2]}');
      final name = '${row[3]}';
      final position = row.length > 4 ? '${row[4]}' : '';
      (listed[_key(season, week, team)] ??= []).add(_Out(name, position));
      final normal = playingTimeName(name);
      if (normal.isNotEmpty) (outWeeks[normal] ??= []).add((season, week));
    }
    final orderedWeeks = <String, List<(int, int)>>{
      for (final entry in teamWeeks.entries)
        entry.key:
            [
              for (final stamp in entry.value)
                (
                  int.parse(stamp.split('|')[0]),
                  int.parse(stamp.split('|')[1]),
                ),
            ]..sort((a, b) {
              final season = a.$1.compareTo(b.$1);
              return season != 0 ? season : a.$2.compareTo(b.$2);
            }),
    };
    return PlayingTimeBook._(
      games: rows,
      volume: volume,
      outs: listed,
      outWeeks: outWeeks,
      idByName: idByName,
      byTeam: byTeam,
      teamWeeks: orderedWeeks,
    );
  }

  /// Multiplier for one player-week. Uses only earlier weeks, plus the
  /// pregame Out list for [week].
  PlayingTimeMove move({
    required String playerId,
    required String metric,
    required String team,
    required String position,
    required int season,
    required int week,
  }) {
    if (metric != 'passing_yards' &&
        metric != 'rushing_yards' &&
        metric != 'receiving_yards' &&
        metric != 'receptions') {
      return PlayingTimeMove.unchanged;
    }
    final club = boxScoreTeam(team);
    final role = _role(
      playerId: playerId,
      metric: metric,
      season: season,
      week: week,
    );
    final injury = _injury(
      playerId: playerId,
      metric: metric,
      team: club,
      position: position,
      season: season,
      week: week,
    );
    final back = injury.qbJump
        ? 1.0
        : _returned(
            playerId: playerId,
            metric: metric,
            team: club,
            position: position,
            season: season,
            week: week,
          );
    var factor = role.factor * injury.factor * back;
    if (!factor.isFinite || factor <= 0) factor = 1;
    factor = injury.qbJump
        ? factor.clamp(playingTimeStackFloor, playingTimeQbCeil)
        : factor.clamp(playingTimeStackFloor, playingTimeStackCeil);
    if ((factor - 1).abs() < 0.01) factor = 1;
    final sentences = <String>[
      if (role.sentence.isNotEmpty) role.sentence,
      if (injury.sentence.isNotEmpty) injury.sentence,
      if ((back - 1).abs() >= 0.01) 'A teammate is no longer listed Out. Recent share is pulled back toward the games they played, then shrunk.',
    ];
    if (sentences.isEmpty && role.basis == PlayingTimeBasis.unavailable) {
      sentences.add(
        'Snap share and route share are unavailable. The projection stays on recent target or carry share.',
      );
    }
    return PlayingTimeMove(
      factor: factor,
      detail: sentences.isEmpty
          ? 'Recent playing time matches the earlier weeks.'
          : sentences.join(' '),
      basis: role.basis,
      routeUnavailable: role.routeUnavailable,
    );
  }

  _Role _role({
    required String playerId,
    required String metric,
    required int season,
    required int week,
  }) {
    final prior = _before(playerId, season, week);
    final recentCount = prior.length < 3 ? prior.length : 3;
    if (recentCount == 0) {
      return _Role.missing(_receiving(metric));
    }
    final recent = prior.sublist(prior.length - recentCount);
    final baseEnd = prior.length - recentCount;
    final baseStart = baseEnd <= 5 ? 0 : baseEnd - 5;
    final base = baseEnd <= 0
        ? const <_Game>[]
        : prior.sublist(baseStart, baseEnd);
    final receiving = _receiving(metric);
    final routeRecent = _mean(recent, (game) => game.route, 2);
    final routeBase = _mean(base, (game) => game.route, 3);
    final snapRecent = _mean(recent, (game) => game.snap, 2);
    final snapBase = _mean(base, (game) => game.snap, 3);
    double? recentMean;
    double? baseMean;
    var basis = PlayingTimeBasis.unavailable;
    if (receiving &&
        routeRecent != null &&
        routeBase != null &&
        routeBase >= 0.08) {
      recentMean = routeRecent;
      baseMean = routeBase;
      basis = PlayingTimeBasis.route;
    } else if (snapRecent != null && snapBase != null && snapBase >= 0.08) {
      recentMean = snapRecent;
      baseMean = snapBase;
      basis = PlayingTimeBasis.snap;
    }
    final routeUnavailable = receiving && basis != PlayingTimeBasis.route;
    if (recentMean == null || baseMean == null || baseMean <= 0) {
      final sentence = routeUnavailable
          ? 'Route share and snap share are unavailable.'
          : '';
      return _Role(
        factor: 1,
        sentence: basis == PlayingTimeBasis.unavailable ? sentence : '',
        basis: basis,
        routeUnavailable: routeUnavailable,
      );
    }
    final ratio = recentMean / baseMean;
    final inside =
        ratio >= 1 - playingTimeRoleBand && ratio <= 1 + playingTimeRoleBand;
    final moved = inside
        ? 1.0
        : (1 + playingTimeRoleKeep * (ratio - 1)).clamp(
            playingTimeRoleFloor,
            playingTimeRoleCeil,
          );
    final noun = basis == PlayingTimeBasis.route ? 'Route share' : 'Snap share';
    final sentence = (moved - 1).abs() < 0.01
        ? ''
        : '$noun moved from ${_pct(baseMean)} to ${_pct(recentMean)} against the earlier weeks. '
              'The projection moves part of the way.'
              '${routeUnavailable ? ' Route share is unavailable.' : ''}';
    return _Role(
      factor: moved,
      sentence: sentence.trim(),
      basis: basis,
      routeUnavailable: routeUnavailable,
    );
  }

  _Injury _injury({
    required String playerId,
    required String metric,
    required String team,
    required String position,
    required int season,
    required int week,
  }) {
    final previous = _previousTeamGame(team, season, week);
    if (previous == null) return _Injury.none;
    final absent = _outs[_key(season, week, team)] ?? const <_Out>[];
    if (metric == 'passing_yards') {
      return _quarterback(
        playerId: playerId,
        team: team,
        position: position,
        season: season,
        week: week,
        previous: previous,
        absent: absent,
      );
    }
    final outIds = <String>{};
    var hole = 0.0;
    String? largestName;
    var largest = 0.0;
    for (final out in absent) {
      final id = _idByName[playingTimeName(out.name)];
      if (id == null || id == playerId || !outIds.add(id)) continue;
      final other = _position(id, season, week, out.position);
      if (!_vacates(metric, other)) continue;
      if (!_played(id, previous.$1, previous.$2, team)) continue;
      final share = _share(id, metric, season, week, team: team, minGames: 4);
      if (share == null || share.value < playingTimeInjuryMinShare) continue;
      hole += share.value;
      if (share.value > largest) {
        largest = share.value;
        largestName = out.name;
      }
    }
    if (hole <= 0 || largestName == null) return _Injury.none;
    hole = hole.clamp(0.0, 0.50);
    final own = _share(playerId, metric, season, week, team: team, minGames: 4);
    if (own == null || own.value < 0.04) return _Injury.none;
    if (!_vacates(metric, position)) return _Injury.none;
    var weight = 0.0;
    var selfWeight = 0.0;
    final roster = _byTeam[team] ?? const <String>{};
    for (final id in roster) {
      if (outIds.contains(id)) continue;
      final other = _position(id, season, week, '');
      if (!_vacates(metric, other)) continue;
      final playerWeight = _weight(id, metric, season, week);
      if (playerWeight <= 0) continue;
      weight += playerWeight;
      if (id == playerId) selfWeight = playerWeight;
    }
    if (weight <= 0 || selfWeight <= 0) return _Injury.none;
    final added = hole * playingTimeInjuryTransfer * (selfWeight / weight);
    final factor = ((own.value + added) / own.value).clamp(
      1.0,
      playingTimeInjuryCeil,
    );
    if ((factor - 1).abs() < 0.01) return _Injury.none;
    final noun = metric == 'rushing_yards' ? 'carries' : 'targets';
    return _Injury(
      factor: factor,
      sentence:
          '$largestName is listed Out and played last week. A ${_pct(largest)} share of $noun is split by playing time, then shrunk toward no extra share.',
    );
  }

  _Injury _quarterback({
    required String playerId,
    required String team,
    required String position,
    required int season,
    required int week,
    required (int, int) previous,
    required List<_Out> absent,
  }) {
    if (position != 'QB') return _Injury.none;
    String? starterId;
    var starterShare = 0.0;
    String? starterName;
    final outIds = <String>{};
    for (final out in absent) {
      final id = _idByName[playingTimeName(out.name)];
      if (id == null || !outIds.add(id)) continue;
      if (_position(id, season, week, out.position) != 'QB') continue;
      if (!_played(id, previous.$1, previous.$2, team)) continue;
      final share = _share(
        id,
        'passing_yards',
        season,
        week,
        team: team,
        minGames: 4,
      );
      if (share == null || share.value < playingTimeQbMinStarter) continue;
      if (share.value > starterShare) {
        starterShare = share.value;
        starterId = id;
        starterName = out.name;
      }
    }
    if (starterId == null || starterName == null) return _Injury.none;
    if (outIds.contains(playerId)) return _Injury.none;
    final own = _share(
      playerId,
      'passing_yards',
      season,
      week,
      team: team,
      minGames: 1,
    );
    if (own == null || own.value <= 0 || own.value >= 0.92) {
      return _Injury.none;
    }
    if (!_isNextQuarterback(
      playerId: playerId,
      team: team,
      season: season,
      week: week,
      outIds: outIds,
    )) {
      return _Injury.none;
    }
    final believed =
        (own.value * own.games + playingTimeQbShare * playingTimeQbBelief) /
        (own.games + playingTimeQbBelief);
    final next = believed.clamp(own.value, 0.92);
    final factor = (next / own.value).clamp(1.0, playingTimeQbCeil);
    if ((factor - 1).abs() < 0.01) return _Injury.none;
    return _Injury(
      factor: factor,
      qbJump: true,
      sentence:
          '$starterName is listed Out and played last week. The other quarterback\'s dropback share moves toward a starter\'s share, then is shrunk.',
    );
  }

  bool _isNextQuarterback({
    required String playerId,
    required String team,
    required int season,
    required int week,
    required Set<String> outIds,
  }) {
    String? bestId;
    var bestSeason = -1;
    var bestWeek = -1;
    var bestShare = -1.0;
    for (final id in _byTeam[team] ?? const <String>{}) {
      if (outIds.contains(id)) continue;
      if (_position(id, season, week, '') != 'QB') continue;
      final prior = _before(id, season, week);
      (int, int)? last;
      for (final game in prior) {
        if (game.team == team && game.attempts > 0) {
          last = (game.season, game.week);
        }
      }
      if (last == null) continue;
      final share = _share(
        id,
        'passing_yards',
        season,
        week,
        team: team,
        minGames: 1,
      );
      final value = share?.value ?? 0;
      final later =
          last.$1 > bestSeason ||
          (last.$1 == bestSeason && last.$2 > bestWeek) ||
          (last.$1 == bestSeason && last.$2 == bestWeek && value > bestShare);
      if (later) {
        bestId = id;
        bestSeason = last.$1;
        bestWeek = last.$2;
        bestShare = value;
      }
    }
    return bestId == playerId;
  }

  double _returned({
    required String playerId,
    required String metric,
    required String team,
    required String position,
    required int season,
    required int week,
  }) {
    if (!_vacates(metric, position)) return 1;
    final previous = _previousTeamGame(team, season, week);
    if (previous == null) return 1;
    final outNow = <String>{
      for (final out in _outs[_key(season, week, team)] ?? const <_Out>[])
        playingTimeName(out.name),
    };
    final previousOuts =
        _outs[_key(previous.$1, previous.$2, team)] ?? const <_Out>[];
    String? bestName;
    var bestShare = playingTimeInjuryMinShare;
    for (final out in previousOuts) {
      final normal = playingTimeName(out.name);
      if (normal.isEmpty || outNow.contains(normal)) continue;
      final id = _idByName[normal];
      if (id == null || id == playerId) continue;
      final other = _position(id, season, week, out.position);
      if (!_vacates(metric, other)) continue;
      final share = _share(id, metric, season, week, team: team, minGames: 4);
      if (share == null || share.value < bestShare) continue;
      bestShare = share.value;
      bestName = normal;
    }
    if (bestName == null) return 1;
    final full = _share(
      playerId,
      metric,
      season,
      week,
      team: team,
      minGames: 4,
    );
    final reduced = _share(
      playerId,
      metric,
      season,
      week,
      team: team,
      minGames: 4,
      skip: _weeksNamed(bestName, season, week),
    );
    if (full == null || reduced == null || reduced.value >= full.value) {
      return 1;
    }
    final pulled =
        full.value + playingTimeReturnKeep * (reduced.value - full.value);
    return (pulled / full.value).clamp(playingTimeReturnFloor, 1.0);
  }

  Set<String> _weeksNamed(String name, int season, int week) {
    final weeks = <String>{};
    for (final stamp in _outWeeks[name] ?? const <(int, int)>[]) {
      final before =
          stamp.$1 < season || (stamp.$1 == season && stamp.$2 < week);
      if (before) weeks.add('${stamp.$1}|${stamp.$2}');
    }
    return weeks;
  }

  double _weight(String id, String metric, int season, int week) {
    final prior = _before(id, season, week);
    if (prior.isEmpty) return 0;
    final recent = prior.length <= 3 ? prior : prior.sublist(prior.length - 3);
    final playing = _receiving(metric)
        ? _mean(recent, (game) => game.route, 1) ??
              _mean(recent, (game) => game.snap, 1)
        : _mean(recent, (game) => game.snap, 1);
    if (playing != null && playing >= 0.08) return playing;
    final club = prior.last.team;
    final clubShare = _share(id, metric, season, week, team: club, minGames: 1);
    if (clubShare != null && clubShare.value >= 0.04) return clubShare.value;
    return 0;
  }

  _Share? _share(
    String id,
    String metric,
    int season,
    int week, {
    required String team,
    required int minGames,
    Set<String> skip = const {},
  }) {
    final kept = [
      for (final game in _before(id, season, week))
        if (game.team == team && !skip.contains('${game.season}|${game.week}'))
          game,
    ];
    if (kept.length < minGames) return null;
    final window = kept.length <= 8 ? kept : kept.sublist(kept.length - 8);
    var player = 0.0, club = 0.0, games = 0;
    for (final game in window) {
      final volume = _volume[_key(game.season, game.week, game.team)];
      if (volume == null) continue;
      final part = _part(metric, game, volume);
      if (part == null) continue;
      player += part.$1;
      club += part.$2;
      games++;
    }
    if (games < minGames || club <= 0) return null;
    final priorWeight = metric == 'passing_yards' ? 30.0 : 40.0;
    final prior = _usagePrior(metric, _position(id, season, week, ''));
    final share = (player + priorWeight * prior) / (club + priorWeight);
    if (!share.isFinite || share <= 0) return null;
    return _Share(share, games);
  }

  List<_Game> _before(String id, int season, int week) {
    final games = _games[id];
    if (games == null) return const [];
    var end = games.length;
    for (var i = 0; i < games.length; i++) {
      final game = games[i];
      final after =
          game.season > season || (game.season == season && game.week >= week);
      if (after) {
        end = i;
        break;
      }
    }
    return games.sublist(0, end);
  }

  (int, int)? _previousTeamGame(String team, int season, int week) {
    final weeks = _teamWeeks[team];
    if (weeks == null) return null;
    (int, int)? last;
    for (final stamp in weeks) {
      final after =
          stamp.$1 > season || (stamp.$1 == season && stamp.$2 >= week);
      if (after) break;
      last = stamp;
    }
    return last;
  }

  bool _played(String id, int season, int week, String team) {
    final games = _games[id];
    if (games == null) return false;
    for (final game in games) {
      if (game.season == season && game.week == week && game.team == team) {
        return true;
      }
      final after =
          game.season > season || (game.season == season && game.week > week);
      if (after) break;
    }
    return false;
  }

  String _position(String id, int season, int week, String fallback) {
    final prior = _before(id, season, week);
    if (prior.isEmpty) return fallback;
    return prior.last.position;
  }
}

class _Role {
  const _Role({
    required this.factor,
    required this.sentence,
    required this.basis,
    required this.routeUnavailable,
  });

  final double factor;
  final String sentence;
  final PlayingTimeBasis basis;
  final bool routeUnavailable;

  static _Role missing(bool receiving) => _Role(
    factor: 1,
    sentence: receiving
        ? 'Route share and snap share are unavailable.'
        : 'Snap share is unavailable.',
    basis: PlayingTimeBasis.unavailable,
    routeUnavailable: receiving,
  );
}

class _Injury {
  const _Injury({
    required this.factor,
    required this.sentence,
    this.qbJump = false,
  });

  final double factor;
  final String sentence;
  final bool qbJump;

  static const none = _Injury(factor: 1, sentence: '');
}

/// Same folding the prop name match already uses, so an Out list lines up
/// with the box score.
String playingTimeName(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

double? _unit(double? value) {
  if (value == null || !value.isFinite || value < 0) return null;
  if (value > 1) return 1;
  return value;
}

double? _mean(List<_Game> rows, double? Function(_Game game) pick, int min) {
  if (rows.length < min) return null;
  var sum = 0.0;
  var count = 0;
  for (final game in rows) {
    final value = pick(game);
    if (value == null) continue;
    sum += value;
    count++;
  }
  if (count < min) return null;
  return sum / count;
}

(double, double)? _part(String metric, _Game game, _Volume volume) {
  switch (metric) {
    case 'passing_yards':
      if (volume.attempts <= 0) return null;
      return (game.attempts, volume.attempts);
    case 'rushing_yards':
      if (volume.carries <= 0) return null;
      return (game.carries, volume.carries);
    case 'receiving_yards':
    case 'receptions':
      if (volume.attempts <= 0) return null;
      return (game.targets, volume.attempts);
    default:
      return null;
  }
}

double _usagePrior(String metric, String position) {
  if (metric == 'passing_yards') return position == 'QB' ? 0.92 : 0.08;
  if (metric == 'rushing_yards') {
    return switch (position) {
      'RB' => 0.45,
      'QB' => 0.10,
      'FB' => 0.08,
      _ => 0.03,
    };
  }
  return switch (position) {
    'WR' => 0.20,
    'TE' => 0.15,
    'RB' => 0.12,
    'FB' => 0.04,
    _ => 0.08,
  };
}

bool _receiving(String metric) =>
    metric == 'receiving_yards' || metric == 'receptions';

bool _vacates(String metric, String position) {
  if (metric == 'rushing_yards') return position == 'RB' || position == 'FB';
  if (metric == 'passing_yards') return position == 'QB';
  return position == 'WR' || position == 'TE' || position == 'RB';
}

String _key(int season, int week, String team) => '$season|$week|$team';

int _order(_Game a, _Game b) {
  final season = a.season.compareTo(b.season);
  return season != 0 ? season : a.week.compareTo(b.week);
}

String _pct(double value) => '${(value * 100).round()}%';
