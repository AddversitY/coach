import 'dart:math' as math;

import 'hit_rate.dart';
import 'player_stats.dart';
import 'prop_chance.dart';
import 'prop_context.dart';
import 'prop_projection.dart';
import 'prop_report.dart';

/// November 21, 2026. An anytime chance is served only when it is pulled
/// toward the position score rate (or the book's no-vig when that price
/// exists), the average chance matches the rate players scored within
/// [anytimeCalibrationMatch], and it beats the position-anchored record
/// on Brier and log loss in both 2025 and 2026. Otherwise the card says
/// the chance is unavailable. It is not pulled toward 50 percent.
/// Passing touchdowns are not scores for the passer.
const anytimeModelAdopted = false;

/// Which anytime curve won, or `unavailable` when none is served.
const servedAnytimeModel = 'unavailable';

/// Red-zone share and the closing total are served on anytime only when
/// that add-on beat the curve above and stayed calibrated.
const anytimeRedZoneAdopted = false;
const anytimeScriptAdopted = false;

/// Earlier scored games required before the mean correction is applied.
const anytimeCalibrationGames = 200;

/// How far the average chance may sit from the rate players scored.
/// Two points. A walk-forward cannot use the week it is scoring.
const anytimeCalibrationMatch = 0.02;

class AnytimeForecast {
  const AnytimeForecast({
    required this.season,
    required this.legacy,
    required this.record,
    required this.poisson,
    required this.inflated,
    required this.poissonZone,
    required this.inflatedZone,
    required this.poissonScript,
    required this.inflatedScript,
    required this.poissonBoth,
    required this.inflatedBoth,
    required this.hit,
    required this.games,
  });

  final int season, games;

  /// The old record, pulled toward 50 percent. Kept so the before number
  /// can be printed. It is not a candidate.
  final double legacy;
  final double record, poisson, inflated;
  final double poissonZone, inflatedZone;
  final double poissonScript, inflatedScript;
  final double poissonBoth, inflatedBoth;
  final bool hit;
}

/// Week-by-week anytime chances. Earlier weeks only. The line is 0.5,
/// which is at least one touchdown. The anchor is the position's earlier
/// score rate, not 50 percent. A mean correction uses only earlier weeks.
List<AnytimeForecast> anytimeForecasts(
  List<PlayerGame> rows, {
  UsageBook? shares,
  ScriptBook? scripts,
}) {
  final pending = <_AnytimeRow>[];
  final byPlayer = <String, List<PlayerGame>>{};
  for (final game in rows) {
    if (game.seasonType != 'REG') continue;
    if (anytimeTouchdowns(game) == null) continue;
    (byPlayer[game.playerId] ??= []).add(game);
  }
  final position = _TouchdownRates(rows);
  for (final games in byPlayer.values) {
    games.sort((a, b) {
      final season = a.season.compareTo(b.season);
      return season != 0 ? season : a.week.compareTo(b.week);
    });
    final bySeason = <int, List<PlayerGame>>{};
    for (final game in games) {
      (bySeason[game.season] ??= []).add(game);
    }
    final seasons = bySeason.keys.toList()..sort();
    for (var index = 1; index < seasons.length; index++) {
      final season = seasons[index];
      if (season < 2024 || season > 2026) continue;
      final previous = bySeason[seasons[index - 1]]!;
      if (previous.length < 4) continue;
      final history = <PlayerGame>[
        for (final earlier in seasons.take(index)) ...bySeason[earlier]!,
      ];
      final weeks = <int, List<PlayerGame>>{};
      for (final game in bySeason[season]!) {
        (weeks[game.week] ??= []).add(game);
      }
      for (final week in (weeks.keys.toList()..sort())) {
        for (final game in weeks[week]!) {
          final value = anytimeTouchdowns(game);
          if (value == null) continue;
          final observed = history.length;
          if (observed < 4) continue;
          var hits = 0;
          for (final earlier in history) {
            final count = anytimeTouchdowns(earlier);
            if (count != null && count > 0.5) hits++;
          }
          final anchor = position.scoreRate(game.position, season, week);
          if (anchor == null || anchor <= 0 || anchor >= 1) continue;
          final legacy = propSideChance(
            hits: hits,
            observed: observed,
            market: propReportMarketProxy,
          );
          final record = propSideChance(
            hits: hits,
            observed: observed,
            market: anchor,
          );
          final plain = _expectedTouchdowns(
            history: history,
            position: game.position,
            season: season,
            week: week,
            rates: position,
            playerId: game.playerId,
            team: game.team,
          );
          final zone = _expectedTouchdowns(
            history: history,
            position: game.position,
            season: season,
            week: week,
            rates: position,
            shares: shares,
            playerId: game.playerId,
            team: game.team,
          );
          final scripted = _expectedTouchdowns(
            history: history,
            position: game.position,
            season: season,
            week: week,
            rates: position,
            scripts: scripts,
            playerId: game.playerId,
            team: game.team,
          );
          final both = _expectedTouchdowns(
            history: history,
            position: game.position,
            season: season,
            week: week,
            rates: position,
            shares: shares,
            scripts: scripts,
            playerId: game.playerId,
            team: game.team,
          );
          if (legacy == null ||
              record == null ||
              plain == null ||
              zone == null ||
              scripted == null ||
              both == null) {
            continue;
          }
          final zeros = history
              .where((earlier) => (anytimeTouchdowns(earlier) ?? 1) <= 0)
              .length
              .toDouble();
          final positionZero =
              position.zero(game.position, season, week) ?? zeros / observed;
          final curves = <String, double>{};
          final raws = <String, double>{};
          void put(String name, double mean, {required bool inflated}) {
            final raw = _touchdownRaw(
              mean: mean,
              inflated: inflated,
              zeros: zeros,
              positionZero: positionZero,
              observed: observed,
            );
            final chance = _anchored(
              raw: raw,
              observed: observed,
              anchor: anchor,
            );
            if (chance == null) return;
            curves[name] = chance;
            raws[name] = raw;
          }

          put('poisson', plain, inflated: false);
          put('inflated', plain, inflated: true);
          put('poissonZone', zone, inflated: false);
          put('inflatedZone', zone, inflated: true);
          put('poissonScript', scripted, inflated: false);
          put('inflatedScript', scripted, inflated: true);
          put('poissonBoth', both, inflated: false);
          put('inflatedBoth', both, inflated: true);
          if (curves.length < 8) continue;
          pending.add(
            _AnytimeRow(
              season: season,
              week: week,
              games: observed,
              hit: value > 0.5,
              legacy: legacy,
              record: record,
              anchor: anchor,
              shrunk: curves,
              raw: raws,
            ),
          );
        }
        history.addAll(weeks[week]!);
      }
    }
  }
  final prepared = _calibrate(pending);
  _cachedRows = rows;
  _cachedShares = shares;
  _cachedScripts = scripts;
  _cachedEvents = prepared.$1;
  _cachedBias = prepared.$2;
  return prepared.$1;
}

List<PlayerGame>? _cachedRows;
UsageBook? _cachedShares;
ScriptBook? _cachedScripts;
List<AnytimeForecast>? _cachedEvents;
Map<String, double>? _cachedBias;

(List<AnytimeForecast>, Map<String, double>) _prepare(
  List<PlayerGame> rows, {
  UsageBook? shares,
  ScriptBook? scripts,
}) {
  if (identical(_cachedRows, rows) &&
      identical(_cachedShares, shares) &&
      identical(_cachedScripts, scripts) &&
      _cachedEvents != null &&
      _cachedBias != null) {
    return (_cachedEvents!, _cachedBias!);
  }
  anytimeForecasts(rows, shares: shares, scripts: scripts);
  return (_cachedEvents!, _cachedBias!);
}

(List<AnytimeForecast>, Map<String, double>) _calibrate(
  List<_AnytimeRow> rows,
) {
  rows.sort((a, b) {
    final season = a.season.compareTo(b.season);
    return season != 0 ? season : a.week.compareTo(b.week);
  });
  const names = [
    'poisson',
    'inflated',
    'poissonZone',
    'inflatedZone',
    'poissonScript',
    'inflatedScript',
    'poissonBoth',
    'inflatedBoth',
  ];
  final totals = {for (final name in names) name: _Running()};
  final events = <AnytimeForecast>[];
  final biases = <String, double>{};
  var index = 0;
  while (index < rows.length) {
    final season = rows[index].season;
    final week = rows[index].week;
    final bias = {for (final name in names) name: totals[name]!.bias};
    for (final name in names) {
      biases['$season|$week|$name'] = bias[name]!;
    }
    while (index < rows.length &&
        rows[index].season == season &&
        rows[index].week == week) {
      final row = rows[index];
      final shown = <String, double>{};
      for (final name in names) {
        final shifted = (row.shrunk[name]! + bias[name]!).clamp(1e-4, 1 - 1e-4);
        shown[name] = limitChanceGap(
          chance: shifted,
          raw: row.raw[name]!,
          observed: row.games,
          market: row.anchor,
        );
        totals[name]!.add(shown[name]!, row.hit);
      }
      if (season == 2025 || season == 2026) {
        events.add(
          AnytimeForecast(
            season: season,
            legacy: row.legacy,
            record: row.record,
            poisson: shown['poisson']!,
            inflated: shown['inflated']!,
            poissonZone: shown['poissonZone']!,
            inflatedZone: shown['inflatedZone']!,
            poissonScript: shown['poissonScript']!,
            inflatedScript: shown['inflatedScript']!,
            poissonBoth: shown['poissonBoth']!,
            inflatedBoth: shown['inflatedBoth']!,
            hit: row.hit,
            games: row.games,
          ),
        );
      }
      index++;
    }
  }
  for (final name in names) {
    biases['next|$name'] = totals[name]!.bias;
  }
  return (events, biases);
}

double _biasFor(
  List<PlayerGame> rows, {
  required int season,
  required int week,
  required String name,
  UsageBook? shares,
  ScriptBook? scripts,
}) {
  final biases = _prepare(rows, shares: shares, scripts: scripts).$2;
  return biases['$season|$week|$name'] ?? biases['next|$name'] ?? 0;
}

class _Running {
  int n = 0;
  double predicted = 0;
  double actual = 0;

  double get bias {
    if (n < anytimeCalibrationGames) return 0;
    return actual / n - predicted / n;
  }

  void add(double chance, bool hit) {
    n++;
    predicted += chance;
    if (hit) actual += 1;
  }
}

class _AnytimeRow {
  const _AnytimeRow({
    required this.season,
    required this.week,
    required this.games,
    required this.hit,
    required this.legacy,
    required this.record,
    required this.anchor,
    required this.shrunk,
    required this.raw,
  });

  final int season, week, games;
  final bool hit;
  final double legacy, record, anchor;
  final Map<String, double> shrunk, raw;
}

double _touchdownRaw({
  required double mean,
  required bool inflated,
  required double zeros,
  required double positionZero,
  required int observed,
}) {
  if (!inflated) return 1 - math.exp(-mean.clamp(0.02, 3.0));
  final pi = ((zeros + 8 * positionZero) / (observed + 8)).clamp(0.0, 0.85);
  final lambda = pi >= 0.999 ? mean.clamp(0.02, 3.0) : mean / (1 - pi);
  return (1 - pi) * (1 - math.exp(-lambda.clamp(0.02, 4.0)));
}

double? _anchored({
  required double raw,
  required int observed,
  required double anchor,
}) {
  final projected = raw.clamp(1e-4, 1 - 1e-4);
  final shrunk = shrinkProjectedChance(
    projected: projected,
    observed: observed,
    market: anchor,
  );
  if (shrunk == null) return null;
  return limitChanceGap(
    chance: shrunk,
    raw: projected,
    observed: observed,
    market: anchor,
  );
}

double? _expectedTouchdowns({
  required List<PlayerGame> history,
  required String position,
  required int season,
  required int week,
  required _TouchdownRates rates,
  required String playerId,
  required String team,
  UsageBook? shares,
  ScriptBook? scripts,
  ScriptPoint? closing,
}) {
  final window = history.length <= 8
      ? history
      : history.sublist(history.length - 8);
  var sum = 0.0;
  var weight = 0.0;
  for (var i = 0; i < window.length; i++) {
    final count = anytimeTouchdowns(window[i]);
    if (count == null) continue;
    final w = math.pow(0.8, window.length - 1 - i).toDouble();
    sum += w * count.toDouble();
    weight += w;
  }
  if (weight <= 0) return null;
  final prior = rates.mean(position, season, week) ?? (sum / weight);
  var mean = (sum + 8 * prior) / (weight + 8);
  final tilt = shares?.tilt(playerId, season, week);
  final typical = shares?.positionRedZone(position, season, week);
  final redZone = tilt?.redZone;
  if (redZone != null && typical != null && typical > 0.02) {
    final scale = (redZone / typical).clamp(0.75, 1.25);
    mean *= scale;
  }
  final script =
      closing ?? scripts?.lookup(season: season, week: week, team: team);
  if (script != null && script.implied > 0) {
    mean *= (script.implied / 22.5).clamp(0.90, 1.10);
  }
  if (!mean.isFinite || mean < 0) return null;
  return mean > 3 ? 3 : mean;
}

/// The curve name the card serves, including a red-zone or script add-on.
String get servedAnytimeKey {
  if (!anytimeModelAdopted || servedAnytimeModel == 'unavailable') {
    return 'unavailable';
  }
  if (anytimeRedZoneAdopted && anytimeScriptAdopted) {
    return '${servedAnytimeModel}Both';
  }
  if (anytimeRedZoneAdopted) return '${servedAnytimeModel}Zone';
  if (anytimeScriptAdopted) return '${servedAnytimeModel}Script';
  return servedAnytimeModel;
}

/// The card's anytime chance when [anytimeModelAdopted] is set.
/// Otherwise the caller shows the chance as unavailable.
PropProjection? projectAnytime({
  required List<PlayerGame> games,
  required String playerId,
  required double line,
  required LineSide side,
  required int beforeSeason,
  required int beforeWeek,
  double? market,
  UsageBook? shares,
  ScriptBook? scripts,
  double? closingSpread,
  double? closingTotal,
  DateTime? beforeDate,
}) {
  if (!anytimeModelAdopted || servedAnytimeKey == 'unavailable') return null;
  final prior =
      [
        for (final game in games)
          if (game.playerId == playerId &&
              _before(game, beforeSeason, beforeWeek, beforeDate) &&
              anytimeTouchdowns(game) != null)
            game,
      ]..sort((a, b) {
        final season = a.season.compareTo(b.season);
        return season != 0 ? season : a.week.compareTo(b.week);
      });
  if (prior.length < 4) return null;
  final rates = _TouchdownRates(games);
  final cutoff = _cutoff(
    games: games,
    beforeSeason: beforeSeason,
    beforeWeek: beforeWeek,
    beforeDate: beforeDate,
  );
  final mean = _expectedTouchdowns(
    history: prior,
    position: prior.last.position,
    season: cutoff.$1,
    week: cutoff.$2,
    rates: rates,
    shares: anytimeRedZoneAdopted ? shares : null,
    scripts: anytimeScriptAdopted ? scripts : null,
    closing: anytimeScriptAdopted
        ? ScriptPoint.fromBetting(
            teamSpread: closingSpread ?? double.nan,
            total: closingTotal ?? double.nan,
          )
        : null,
    playerId: playerId,
    team: prior.last.team,
  );
  if (mean == null) return null;
  final positionRate = rates.scoreRate(
    prior.last.position,
    cutoff.$1,
    cutoff.$2,
  );
  final book = market != null && market > 0 && market < 1 ? market : null;
  final overAnchor = book == null
      ? positionRate
      : side == LineSide.over
      ? book
      : (1 - book).clamp(1e-4, 1 - 1e-4);
  if (overAnchor == null || overAnchor <= 0 || overAnchor >= 1) return null;
  final zeros = prior
      .where((game) => (anytimeTouchdowns(game) ?? 1) <= 0)
      .length
      .toDouble();
  final positionZero =
      rates.zero(prior.last.position, cutoff.$1, cutoff.$2) ??
      zeros / prior.length;
  final raw = _touchdownRaw(
    mean: mean,
    inflated: servedAnytimeModel == 'inflated',
    zeros: zeros,
    positionZero: positionZero,
    observed: prior.length,
  );
  final shrunk = _anchored(
    raw: raw,
    observed: prior.length,
    anchor: overAnchor,
  );
  if (shrunk == null) return null;
  final bias = _biasFor(
    games,
    season: cutoff.$1,
    week: cutoff.$2,
    name: servedAnytimeKey,
    shares: shares,
    scripts: scripts,
  );
  final shifted = (shrunk + bias).clamp(1e-4, 1 - 1e-4);
  final overShown = limitChanceGap(
    chance: shifted,
    raw: raw.clamp(1e-4, 1 - 1e-4),
    observed: prior.length,
    market: overAnchor,
  );
  var capped = (overShown - shifted).abs() > 1e-9;
  var shown = side == LineSide.over
      ? overShown
      : (1 - overShown).clamp(1e-4, 1 - 1e-4);
  if (book != null) {
    final beforeBook = shown;
    shown = limitChanceGap(
      chance: shown,
      raw: side == LineSide.over
          ? raw.clamp(1e-4, 1 - 1e-4)
          : (1 - raw).clamp(1e-4, 1 - 1e-4),
      observed: prior.length,
      market: book,
    );
    if ((shown - beforeBook).abs() > 1e-9) capped = true;
  }
  final sideRaw = side == LineSide.over
      ? raw.clamp(1e-4, 1 - 1e-4)
      : (1 - raw).clamp(1e-4, 1 - 1e-4);
  return PropProjection(
    metric: 'anytime_td',
    mean: mean,
    sd: math.sqrt(mean),
    distribution: servedAnytimeModel == 'inflated'
        ? 'zero-inflated poisson'
        : 'poisson',
    rawChance: sideRaw,
    adjustedChance: sideRaw,
    chance: shown,
    market: market,
    capped: capped,
    games: prior.length,
    side: side,
    factors: [
      PropFactor(
        label: 'Touchdowns',
        detail: '${mean.toStringAsFixed(2)} expected from earlier weeks',
        delta: mean,
      ),
    ],
  );
}

(int, int) _cutoff({
  required List<PlayerGame> games,
  required int beforeSeason,
  required int beforeWeek,
  required DateTime? beforeDate,
}) {
  if (beforeDate == null) return (beforeSeason, beforeWeek);
  var season = 0;
  var week = 0;
  var found = false;
  for (final game in games) {
    if (!_before(game, 10000, 1, beforeDate)) continue;
    if (!found ||
        game.season > season ||
        (game.season == season && game.week > week)) {
      season = game.season;
      week = game.week;
      found = true;
    }
  }
  if (!found) return (beforeSeason, beforeWeek);
  return (season, week + 1);
}

bool _before(PlayerGame game, int season, int week, DateTime? date) {
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

class _TouchdownRates {
  _TouchdownRates(List<PlayerGame> rows) {
    for (final game in rows) {
      if (game.seasonType != 'REG') continue;
      final count = anytimeTouchdowns(game);
      if (count == null) continue;
      (_series[game.playerId] ??= _TdSeries(
        game.position,
      )).add(game.season, game.week, count.toDouble());
    }
    for (final series in _series.values) {
      series.sort();
    }
  }

  final _series = <String, _TdSeries>{};
  final _cache = <String, double?>{};

  double? mean(String position, int season, int week) =>
      _read('m', position, season, week, zeros: false);

  double? zero(String position, int season, int week) =>
      _read('z', position, season, week, zeros: true);

  /// Share of earlier games at [position] with at least one score.
  /// Null when fewer than 12 players have four earlier games.
  double? scoreRate(String position, int season, int week) {
    final key = 's|$position|$season|$week';
    if (_cache.containsKey(key)) return _cache[key];
    var scores = 0.0;
    var games = 0.0;
    var players = 0;
    for (final series in _series.values) {
      if (series.position != position) continue;
      final read = series.scoresBefore(season, week);
      if (read == null) continue;
      scores += read.$1;
      games += read.$2;
      players++;
    }
    final result = players < 12 || games <= 0 ? null : scores / games;
    _cache[key] = result;
    return result;
  }

  double? _read(
    String kind,
    String position,
    int season,
    int week, {
    required bool zeros,
  }) {
    final key = '$kind|$position|$season|$week';
    if (_cache.containsKey(key)) return _cache[key];
    var sum = 0.0;
    var players = 0;
    for (final series in _series.values) {
      if (series.position != position) continue;
      final read = zeros
          ? series.zeroBefore(season, week)
          : series.meanBefore(season, week);
      if (read == null) continue;
      sum += read;
      players++;
    }
    final result = players < 12 ? null : sum / players;
    _cache[key] = result;
    return result;
  }
}

class _TdSeries {
  _TdSeries(this.position);
  final String position;
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

  double? meanBefore(int season, int week) {
    final n = _cut(season, week);
    if (n < 4) return null;
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      sum += values[i];
    }
    return sum / n;
  }

  double? zeroBefore(int season, int week) {
    final n = _cut(season, week);
    if (n < 4) return null;
    var zeros = 0.0;
    for (var i = 0; i < n; i++) {
      if (values[i] <= 0) zeros++;
    }
    return zeros / n;
  }

  (double, double)? scoresBefore(int season, int week) {
    final n = _cut(season, week);
    if (n < 4) return null;
    var scores = 0.0;
    for (var i = 0; i < n; i++) {
      if (values[i] > 0.5) scores++;
    }
    return (scores, n.toDouble());
  }
}
