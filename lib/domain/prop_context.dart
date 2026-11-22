import 'dart:math' as math;

import 'history.dart';
import 'player_stats.dart';

/// Switches for one prop projection. Every switch defaults off, which is
/// the chance the card already serves.
class PropTune {
  const PropTune({
    this.recency = false,
    this.shares = false,
    this.scriptMix = false,
    this.scriptVolume = false,
    this.positionVariance = false,
    this.gamma = false,
    this.zeroInflated = false,
  });

  final bool recency;
  final bool shares;
  final bool scriptMix;
  final bool scriptVolume;
  final bool positionVariance;
  final bool gamma;
  final bool zeroInflated;

  bool get any =>
      recency ||
      shares ||
      scriptMix ||
      scriptVolume ||
      positionVariance ||
      gamma ||
      zeroInflated;

  static const off = PropTune();
}

/// One earlier week of free nflverse shares. A null share was not in the file.
class UsageWeek {
  const UsageWeek({
    required this.season,
    required this.week,
    this.snap,
    this.route,
    this.air,
    this.redZone,
  });

  final int season, week;
  final double? snap, route, air, redZone;
}

/// Player-week snap, route, air-yards and red-zone shares.
///
/// A lookup uses weeks strictly before the game. The file is derived from
/// nflverse (CC BY 4.0). It is not a feed of prices.
class UsageBook {
  UsageBook._(this._rows, this._routeByPosition, this._redZoneByPosition);

  final Map<String, List<UsageWeek>> _rows;
  final Map<String, List<UsageWeek>> _routeByPosition;
  final Map<String, List<UsageWeek>> _redZoneByPosition;

  factory UsageBook.fromJson(Map<String, dynamic> json) {
    final keys = json['keys'];
    final raw = json['rows'];
    if (keys is! List || raw is! List) {
      return UsageBook._(const {}, const {}, const {});
    }
    final names = [for (final key in keys) '$key'];
    int at(String name) => names.indexOf(name);
    final idAt = at('id');
    final seasonAt = at('season');
    final weekAt = at('week');
    final positionAt = at('position');
    if (idAt < 0 || seasonAt < 0 || weekAt < 0) {
      return UsageBook._(const {}, const {}, const {});
    }
    final rows = <String, List<UsageWeek>>{};
    final routes = <String, List<UsageWeek>>{};
    final redZones = <String, List<UsageWeek>>{};
    double? numAt(List<dynamic> row, String name) {
      final index = at(name);
      if (index < 0 || index >= row.length) return null;
      final value = row[index];
      if (value is! num || !value.isFinite) return null;
      return value.toDouble();
    }

    for (final item in raw) {
      if (item is! List) continue;
      final id = item[idAt];
      final season = item[seasonAt];
      final week = item[weekAt];
      if (id is! String || season is! int || week is! int) continue;
      final weekRow = UsageWeek(
        season: season,
        week: week,
        snap: numAt(item, 'snap'),
        route: numAt(item, 'route'),
        air: numAt(item, 'air'),
        redZone: numAt(item, 'rz'),
      );
      (rows[id] ??= []).add(weekRow);
      final position = positionAt < 0 ? '' : '${item[positionAt]}';
      if (weekRow.route != null && position.isNotEmpty) {
        (routes[position] ??= []).add(weekRow);
      }
      if (weekRow.redZone != null && position.isNotEmpty) {
        (redZones[position] ??= []).add(weekRow);
      }
    }
    for (final list in [...rows.values, ...routes.values, ...redZones.values]) {
      list.sort((a, b) {
        final season = a.season.compareTo(b.season);
        return season != 0 ? season : a.week.compareTo(b.week);
      });
    }
    return UsageBook._(rows, routes, redZones);
  }

  /// Recency-weighted shares from weeks before [season]/[week].
  ShareTilt? tilt(String playerId, int season, int week) {
    final rows = _rows[playerId];
    if (rows == null) return null;
    final prior = [
      for (final row in rows)
        if (row.season < season || (row.season == season && row.week < week))
          row,
    ];
    if (prior.isEmpty) return null;
    final window = prior.length <= 8 ? prior : prior.sublist(prior.length - 8);
    return ShareTilt(
      snap: _weighted(window, (row) => row.snap),
      route: _weighted(window, (row) => row.route),
      air: _weighted(window, (row) => row.air),
      redZone: _weighted(window, (row) => row.redZone),
    );
  }

  /// Mean route share for [position] from earlier weeks only.
  /// Null when fewer than 12 earlier weeks are stored.
  double? positionRoute(String position, int season, int week) {
    final rows = _routeByPosition[position];
    if (rows == null) return null;
    final values = [
      for (final row in rows)
        if ((row.season < season ||
                (row.season == season && row.week < week)) &&
            row.route != null)
          row.route!,
    ];
    if (values.length < 12) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  /// Every stored share, including later weeks. Callers that score a week
  /// have to drop that week themselves.
  void forEachShare(void Function(String playerId, UsageWeek week) visit) {
    for (final entry in _rows.entries) {
      for (final week in entry.value) {
        visit(entry.key, week);
      }
    }
  }

  /// Mean red-zone touch share for [position] from earlier weeks only.
  double? positionRedZone(String position, int season, int week) {
    final rows = _redZoneByPosition[position];
    if (rows == null) return null;
    final values = [
      for (final row in rows)
        if ((row.season < season ||
                (row.season == season && row.week < week)) &&
            row.redZone != null)
          row.redZone!,
    ];
    if (values.length < 12) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  static double? _weighted(
    List<UsageWeek> rows,
    double? Function(UsageWeek row) pick,
  ) {
    var sum = 0.0;
    var weight = 0.0;
    for (var i = 0; i < rows.length; i++) {
      final value = pick(rows[i]);
      if (value == null) continue;
      final w = math.pow(0.8, rows.length - 1 - i).toDouble();
      sum += w * value;
      weight += w;
    }
    if (weight <= 0) return null;
    return sum / weight;
  }
}

class ShareTilt {
  const ShareTilt({this.snap, this.route, this.air, this.redZone});

  final double? snap, route, air, redZone;
  bool get known =>
      snap != null || route != null || air != null || redZone != null;
}

/// The game's closing spread and total, as the team's own margin.
///
/// [margin] is positive when this team is favored. That matches the
/// schedule file: a positive `spreadLine` means the home club was favored.
class ScriptPoint {
  const ScriptPoint({required this.margin, required this.total});

  final double margin, total;

  double get implied => (total + margin) / 2;

  /// [teamSpread] is the betting number on the screen. Negative means
  /// this team is favored, which is the sign [teamSpreadFor] already uses.
  static ScriptPoint? fromBetting({
    required double teamSpread,
    required double total,
  }) {
    if (!teamSpread.isFinite || !total.isFinite || total <= 0) return null;
    return ScriptPoint(margin: -teamSpread, total: total);
  }
}

class ScriptBook {
  ScriptBook(List<HistoricalGame> games) {
    for (final game in games) {
      final spread = game.spreadLine;
      final total = game.totalLine;
      if (spread == null || total == null || total <= 0) continue;
      _put(game.season, game.week, game.home, spread, total);
      _put(game.season, game.week, game.away, -spread, total);
    }
  }

  final _rows = <String, ScriptPoint>{};

  void _put(int season, int week, String team, double margin, double total) {
    if (team.isEmpty) return;
    _rows['$season|$week|$team'] = ScriptPoint(margin: margin, total: total);
  }

  ScriptPoint? lookup({
    required int season,
    required int week,
    required String team,
  }) => _rows['$season|$week|$team'];
}

/// Player spread and zero rate, shrunk toward the position, from earlier games.
class PositionSpread {
  PositionSpread(List<PlayerGame> rows) {
    for (final game in rows) {
      if (game.seasonType != 'REG') continue;
      for (final metric in _metrics) {
        if (!_counts(game, metric)) continue;
        final value = game.stats[metric]!.toDouble();
        (_series['${game.playerId}|$metric'] ??= _Series(
          game.position,
          metric,
        )).add(game.season, game.week, value);
      }
    }
    for (final series in _series.values) {
      series.sort();
    }
  }

  final _series = <String, _Series>{};
  final _cache = <String, double?>{};

  static const _metrics = [
    'passing_yards',
    'rushing_yards',
    'receiving_yards',
    'receptions',
  ];

  /// Mean of the players' own game-to-game spreads before this week.
  /// Null when fewer than 12 players have four earlier games.
  double? sd({
    required String position,
    required String metric,
    required int season,
    required int week,
  }) {
    final key = 'sd|$position|$metric|$season|$week';
    if (_cache.containsKey(key)) return _cache[key];
    final values = <double>[];
    for (final series in _series.values) {
      if (series.position != position || series.metric != metric) continue;
      final spread = series.sdBefore(season, week);
      if (spread != null) values.add(spread);
    }
    final result = values.length < 12
        ? null
        : values.reduce((a, b) => a + b) / values.length;
    _cache[key] = result;
    return result;
  }

  /// Share of earlier games at this position that finished at zero.
  double? zeroRate({
    required String position,
    required String metric,
    required int season,
    required int week,
  }) {
    final key = 'z|$position|$metric|$season|$week';
    if (_cache.containsKey(key)) return _cache[key];
    var zeros = 0.0;
    var games = 0.0;
    for (final series in _series.values) {
      if (series.position != position || series.metric != metric) continue;
      final read = series.zerosBefore(season, week);
      if (read == null) continue;
      zeros += read.$1;
      games += read.$2;
    }
    final result = games < 12 ? null : zeros / games;
    _cache[key] = result;
    return result;
  }
}

class _Series {
  _Series(this.position, this.metric);
  final String position, metric;
  final seasons = <int>[];
  final weeks = <int>[];
  final values = <double>[];

  void add(int season, int week, double value) {
    seasons.add(season);
    weeks.add(week);
    values.add(value);
  }

  void sort() {
    final order = List<int>.generate(seasons.length, (index) => index)
      ..sort((a, b) {
        final season = seasons[a].compareTo(seasons[b]);
        return season != 0 ? season : weeks[a].compareTo(weeks[b]);
      });
    final nextSeasons = [for (final index in order) seasons[index]];
    final nextWeeks = [for (final index in order) weeks[index]];
    final nextValues = [for (final index in order) values[index]];
    seasons
      ..clear()
      ..addAll(nextSeasons);
    weeks
      ..clear()
      ..addAll(nextWeeks);
    values
      ..clear()
      ..addAll(nextValues);
  }

  int _cut(int season, int week) {
    var cut = 0;
    while (cut < seasons.length &&
        (seasons[cut] < season ||
            (seasons[cut] == season && weeks[cut] < week))) {
      cut++;
    }
    return cut;
  }

  double? sdBefore(int season, int week) {
    final n = _cut(season, week);
    if (n < 4) return null;
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      sum += values[i];
    }
    final mean = sum / n;
    var ss = 0.0;
    for (var i = 0; i < n; i++) {
      final gap = values[i] - mean;
      ss += gap * gap;
    }
    return math.sqrt(ss / (n - 1));
  }

  (double, double)? zerosBefore(int season, int week) {
    final n = _cut(season, week);
    if (n < 4) return null;
    var zeros = 0.0;
    for (var i = 0; i < n; i++) {
      if (values[i] <= 0) zeros++;
    }
    return (zeros, n.toDouble());
  }
}

bool _counts(PlayerGame game, String metric) {
  final value = game.stats[metric];
  if (value == null) return false;
  switch (metric) {
    case 'passing_yards':
      final attempts = game.stats['attempts'];
      if (attempts != null) return attempts >= 1;
      return value > 0;
    case 'rushing_yards':
      final carries = game.stats['carries'];
      if (carries != null) return carries >= 1;
      return value > 0;
    case 'receiving_yards':
    case 'receptions':
      final targets = game.stats['targets'];
      if (targets != null) return targets >= 1;
      return value > 0;
    default:
      return false;
  }
}
