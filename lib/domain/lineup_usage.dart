import 'matchup.dart';
import 'player_stats.dart';
import 'prop_projection.dart';

/// The shrunk lineup shift is not the served chance until a walk-forward
/// beats the lognormal card on Brier and log loss in both 2025 and 2026.
const lineupUsageAdopted = false;

/// How a pregame Out list would move one player's share.
class LineupMove {
  const LineupMove({required this.factor, required this.reason});

  final double factor;
  final String reason;

  static const none = LineupMove(factor: 1, reason: '');
}

class _Snap {
  const _Snap(
    this.season,
    this.week,
    this.team,
    this.targets,
    this.carries,
    this.attempts,
  );

  final int season, week;
  final String team;
  final double targets, carries, attempts;
}

class _Volume {
  double targets = 0, carries = 0, attempts = 0;
}

class _OutName {
  const _OutName(this.name, this.position);
  final String name, position;
}

/// Earlier games and the weekly Out list. A week uses only earlier games
/// for shares. The Out list for the week being scored is the pregame report.
class LineupTape {
  LineupTape._({
    required this._snaps,
    required this._volume,
    required this._outs,
    required this._outWeeks,
    required this._idByName,
    required this._nameOf,
    required this._positionOf,
    required this._byTeam,
  });

  final Map<String, List<_Snap>> _snaps;
  final Map<String, _Volume> _volume;
  final Map<String, List<_OutName>> _outs;
  final Map<String, List<(int, int)>> _outWeeks;
  final Map<String, String> _idByName;
  final Map<String, String> _nameOf;
  final Map<String, String> _positionOf;
  final Map<String, Set<String>> _byTeam;

  factory LineupTape.build(
    List<PlayerGame> rows,
    List<List<dynamic>> outs,
  ) {
    final snaps = <String, List<_Snap>>{};
    final volume = <String, _Volume>{};
    final nameOf = <String, String>{};
    final positionOf = <String, String>{};
    final idsByName = <String, Set<String>>{};
    for (final game in rows) {
      if (game.seasonType != 'REG') continue;
      final targets = game.stats['targets']?.toDouble() ?? 0;
      final carries = game.stats['carries']?.toDouble() ?? 0;
      final attempts = game.stats['attempts']?.toDouble() ?? 0;
      (snaps[game.playerId] ??= []).add(
        _Snap(game.season, game.week, game.team, targets, carries, attempts),
      );
      final club = volume.putIfAbsent(
        _key(game.season, game.week, game.team),
        _Volume.new,
      );
      club.targets += targets;
      club.carries += carries;
      club.attempts += attempts;
      nameOf[game.playerId] = game.name;
      positionOf[game.playerId] = game.position;
      final name = normalizePropName(game.name);
      if (name.isNotEmpty) (idsByName[name] ??= {}).add(game.playerId);
    }
    for (final list in snaps.values) {
      list.sort((a, b) {
        final season = a.season.compareTo(b.season);
        return season != 0 ? season : a.week.compareTo(b.week);
      });
    }
    final idByName = <String, String>{
      for (final entry in idsByName.entries)
        if (entry.value.length == 1) entry.key: entry.value.single,
    };
    final listed = <String, List<_OutName>>{};
    final outWeeks = <String, List<(int, int)>>{};
    final byTeam = <String, Set<String>>{};
    for (final row in outs) {
      if (row.length < 4) continue;
      final season = row[0];
      final week = row[1];
      if (season is! int || week is! int) continue;
      final team = boxScoreTeam('${row[2]}');
      final name = '${row[3]}';
      final position = row.length > 4 ? '${row[4]}' : '';
      (listed[_key(season, week, team)] ??= []).add(_OutName(name, position));
      final normal = normalizePropName(name);
      if (normal.isNotEmpty) {
        (outWeeks[normal] ??= []).add((season, week));
      }
      final id = idByName[normal];
      if (id != null) (byTeam[team] ??= {}).add(id);
    }
    for (final entry in snaps.entries) {
      for (final snap in entry.value) {
        (byTeam[snap.team] ??= {}).add(entry.key);
      }
    }
    return LineupTape._(
      snaps: snaps,
      volume: volume,
      outs: listed,
      outWeeks: outWeeks,
      idByName: idByName,
      nameOf: nameOf,
      positionOf: positionOf,
      byTeam: byTeam,
    );
  }

  /// Multiplier on the served mean. 1 leaves the mean where it is.
  LineupMove move({
    required String playerId,
    required String metric,
    required String team,
    required int season,
    required int week,
  }) {
    final club = boxScoreTeam(team);
    final self = _share(
      playerId,
      metric,
      season,
      week,
      team: null,
    );
    if (self == null || self.share <= 0) return LineupMove.none;
    final position = _positionOf[playerId] ?? '';
    final absent = _outs[_key(season, week, club)] ?? const <_OutName>[];
    var hole = 0.0;
    var count = 0;
    String? largestName;
    var largest = 0.0;
    final seen = <String>{playerId};
    for (final out in absent) {
      if (!_sameGroup(metric, position, out.position)) continue;
      final id = _idByName[normalizePropName(out.name)];
      if (id == null || !seen.add(id)) continue;
      final share = _share(id, metric, season, week, team: club);
      if (share == null) continue;
      final shrunk = share.share * share.games / (share.games + _shrinkGames);
      if (shrunk <= 0) continue;
      hole += shrunk;
      count++;
      if (shrunk > largest) {
        largest = shrunk;
        largestName = _nameOf[id] ?? out.name;
      }
    }
    if (count > 0 && largestName != null) {
      hole = hole.clamp(0.0, 0.45);
      if (hole <= 0 || hole >= 1) return LineupMove.none;
      final raw = self.share / (1 - hole);
      final cap = mathMax(self.share, mathMin(0.50, self.share * 1.35));
      final boosted = raw.clamp(self.share, cap);
      final factor = boosted / self.share;
      if ((factor - 1).abs() < 0.005) return LineupMove.none;
      final noun = metric == 'rushing_yards'
          ? 'carries'
          : metric == 'passing_yards'
          ? 'dropbacks'
          : 'targets';
      final who = count == 1
          ? '$largestName is listed Out'
          : '$count teammates are listed Out, led by $largestName';
      return LineupMove(
        factor: factor,
        reason:
            '$who. ${(largest * 100).round()}% of $noun is moved over, then shrunk toward no extra share.',
      );
    }
    return _returned(
      playerId: playerId,
      metric: metric,
      team: club,
      season: season,
      week: week,
      position: position,
      served: self.share,
      absent: absent,
    );
  }

  LineupMove _returned({
    required String playerId,
    required String metric,
    required String team,
    required int season,
    required int week,
    required String position,
    required double served,
    required List<_OutName> absent,
  }) {
    final outNow = {
      for (final out in absent) normalizePropName(out.name),
    };
    final recentWeeks = _recentWeeks(playerId, season, week);
    if (recentWeeks.isEmpty) return LineupMove.none;
    String? bestId;
    var bestShare = 0.12;
    for (final id in _byTeam[team] ?? const <String>{}) {
      if (id == playerId) continue;
      final other = _positionOf[id] ?? '';
      if (!_sameGroup(metric, position, other)) continue;
      final name = normalizePropName(_nameOf[id] ?? '');
      if (name.isEmpty || outNow.contains(name)) continue;
      final wasOut = recentWeeks.any(
        (stamp) => (_outs[stamp] ?? const <_OutName>[]).any(
          (out) => normalizePropName(out.name) == name,
        ),
      );
      if (!wasOut) continue;
      final share = _share(id, metric, season, week, team: team);
      if (share == null || share.share < bestShare) continue;
      bestShare = share.share;
      bestId = id;
    }
    if (bestId == null) return LineupMove.none;
    final withThem = _share(
      playerId,
      metric,
      season,
      week,
      team: null,
      skipWeeks: _weeksNamed(bestId, season, week),
    );
    if (withThem == null || withThem.share >= served) return LineupMove.none;
    final weight = withThem.games / (withThem.games + _shrinkGames);
    final pulled = served + (withThem.share - served) * weight;
    final factor = (pulled / served).clamp(0.85, 1.0);
    if ((factor - 1).abs() < 0.005) return LineupMove.none;
    final name = _nameOf[bestId] ?? 'A teammate';
    return LineupMove(
      factor: factor,
      reason:
          '$name is not listed Out. The recent share is pulled toward the games they played. The size of that pull is shrunk toward no extra share.',
    );
  }

  Set<String> _weeksNamed(String id, int season, int week) {
    final name = normalizePropName(_nameOf[id] ?? '');
    final weeks = <String>{};
    if (name.isEmpty) return weeks;
    for (final stamp in _outWeeks[name] ?? const <(int, int)>[]) {
      final before =
          stamp.$1 < season || (stamp.$1 == season && stamp.$2 < week);
      if (before) weeks.add('${stamp.$1}|${stamp.$2}');
    }
    return weeks;
  }

  List<String> _recentWeeks(String playerId, int season, int week) {
    final snaps = _before(playerId, season, week);
    if (snaps.isEmpty) return const [];
    final last = snaps.length <= 3 ? snaps : snaps.sublist(snaps.length - 3);
    return [for (final snap in last) _key(snap.season, snap.week, snap.team)];
  }

  _Share? _share(
    String playerId,
    String metric,
    int season,
    int week, {
    required String? team,
    Set<String> skipWeeks = const {},
  }) {
    final snaps = _before(playerId, season, week);
    if (snaps.isEmpty) return null;
    final kept = [
      for (final snap in snaps)
        if ((team == null || snap.team == team) &&
            !skipWeeks.contains('${snap.season}|${snap.week}'))
          snap,
    ];
    if (kept.length < 4) return null;
    final window = kept.length <= 8 ? kept : kept.sublist(kept.length - 8);
    var player = 0.0, club = 0.0, games = 0;
    for (final snap in window) {
      final volume = _volume[_key(snap.season, snap.week, snap.team)];
      if (volume == null) continue;
      final part = _part(metric, snap, volume);
      if (part == null) continue;
      player += part.$1;
      club += part.$2;
      games++;
    }
    if (games < 4 || club <= 0) return null;
    final priorWeight = metric == 'passing_yards' ? 30.0 : 40.0;
    final prior = _prior(metric, _positionOf[playerId] ?? '');
    final share = (player + priorWeight * prior) / (club + priorWeight);
    if (!share.isFinite || share <= 0) return null;
    return _Share(share, games);
  }

  List<_Snap> _before(String playerId, int season, int week) {
    final snaps = _snaps[playerId];
    if (snaps == null) return const [];
    var end = snaps.length;
    for (var i = 0; i < snaps.length; i++) {
      final snap = snaps[i];
      final after =
          snap.season > season || (snap.season == season && snap.week >= week);
      if (after) {
        end = i;
        break;
      }
    }
    return snaps.sublist(0, end);
  }
}

class _Share {
  const _Share(this.share, this.games);
  final double share;
  final int games;
}

const _shrinkGames = 8.0;

String _key(int season, int week, String team) => '$season|$week|$team';

(double, double)? _part(String metric, _Snap snap, _Volume volume) {
  switch (metric) {
    case 'passing_yards':
      if (snap.attempts <= 0 || volume.attempts <= 0) return null;
      return (snap.attempts, volume.attempts);
    case 'rushing_yards':
      if (snap.carries <= 0 || volume.carries <= 0) return null;
      return (snap.carries, volume.carries);
    case 'receiving_yards':
    case 'receptions':
      if (snap.targets <= 0 || volume.attempts <= 0) return null;
      return (snap.targets, volume.attempts);
    default:
      return null;
  }
}

double _prior(String metric, String position) {
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

bool _sameGroup(String metric, String self, String other) {
  if (metric == 'rushing_yards') return _rusher(self) && _rusher(other);
  if (metric == 'passing_yards') return self == 'QB' && other == 'QB';
  return _catcher(self) && _catcher(other);
}

bool _catcher(String position) =>
    position == 'WR' || position == 'TE' || position == 'RB';

bool _rusher(String position) =>
    position == 'RB' || position == 'QB' || position == 'FB';

double mathMax(double a, double b) => a > b ? a : b;

double mathMin(double a, double b) => a < b ? a : b;
