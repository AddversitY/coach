import 'dart:math' as math;

import 'hit_rate.dart';
import 'player_stats.dart';
import 'prop_chance.dart';
import 'prop_context.dart';
import 'prop_projection.dart';
import 'prop_report.dart';

/// November 21, 2026. The anytime model is served only when it beats the
/// shrunk record on Brier and log loss in both 2025 and 2026. The record
/// is the current method: recorded games, 32 games at 50 percent, and the
/// 10/15-point gap. Passing touchdowns are not scores for the passer.
const anytimeModelAdopted = true;

/// Which anytime curve won, or `record` when neither curve won.
const servedAnytimeModel = 'inflated';

/// Red-zone share and the closing total are served on anytime only when
/// that add-on beat the curve above. They are not the yard-prop switches.
const anytimeRedZoneAdopted = true;
const anytimeScriptAdopted = true;

class AnytimeForecast {
  const AnytimeForecast({
    required this.season,
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
  final double record, poisson, inflated;
  final double poissonZone, inflatedZone;
  final double poissonScript, inflatedScript;
  final double poissonBoth, inflatedBoth;
  final bool hit;
}

/// Week-by-week anytime chances. Earlier weeks only. The line is 0.5,
/// which is at least one touchdown. The anchor is a fair 50 percent,
/// the same anchor the other prop test uses when no book price is saved.
List<AnytimeForecast> anytimeForecasts(
  List<PlayerGame> rows, {
  UsageBook? shares,
  ScriptBook? scripts,
}) {
  final events = <AnytimeForecast>[];
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
      if (season != 2025 && season != 2026) continue;
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
          final record = propSideChance(
            hits: hits,
            observed: observed,
            market: propReportMarketProxy,
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
          if (record == null ||
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
          double? cappedPoisson(double mean) => _capped(
            raw: 1 - math.exp(-mean.clamp(0.02, 3.0)),
            observed: observed,
          );
          double? cappedInflated(double mean) {
            final pi = ((zeros + 8 * positionZero) / (observed + 8)).clamp(
              0.0,
              0.85,
            );
            final lambda = pi >= 0.999 ? mean : mean / (1 - pi);
            return _capped(
              raw: (1 - pi) * (1 - math.exp(-lambda.clamp(0.02, 4.0))),
              observed: observed,
            );
          }

          final poisson = cappedPoisson(plain);
          final inflated = cappedInflated(plain);
          final poissonZone = cappedPoisson(zone);
          final inflatedZone = cappedInflated(zone);
          final poissonScript = cappedPoisson(scripted);
          final inflatedScript = cappedInflated(scripted);
          final poissonBoth = cappedPoisson(both);
          final inflatedBoth = cappedInflated(both);
          if (poisson == null ||
              inflated == null ||
              poissonZone == null ||
              inflatedZone == null ||
              poissonScript == null ||
              inflatedScript == null ||
              poissonBoth == null ||
              inflatedBoth == null) {
            continue;
          }
          events.add(
            AnytimeForecast(
              season: season,
              record: record,
              poisson: poisson,
              inflated: inflated,
              poissonZone: poissonZone,
              inflatedZone: inflatedZone,
              poissonScript: poissonScript,
              inflatedScript: inflatedScript,
              poissonBoth: poissonBoth,
              inflatedBoth: inflatedBoth,
              hit: value > 0.5,
              games: observed,
            ),
          );
        }
        history.addAll(weeks[week]!);
      }
    }
  }
  return events;
}

double? _capped({required double raw, required int observed}) {
  final shrunk = shrinkProjectedChance(
    projected: raw.clamp(1e-4, 1 - 1e-4),
    observed: observed,
    market: propReportMarketProxy,
  );
  if (shrunk == null) return null;
  return limitChanceGap(
    chance: shrunk,
    raw: raw.clamp(1e-4, 1 - 1e-4),
    observed: observed,
    market: propReportMarketProxy,
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

/// The card's anytime chance when [anytimeModelAdopted] is set.
/// Otherwise the caller keeps the recorded-game chance.
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
  if (!anytimeModelAdopted || servedAnytimeModel == 'record') return null;
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
  final raw = servedAnytimeModel == 'inflated'
      ? () {
          final zeros = prior
              .where((game) => (anytimeTouchdowns(game) ?? 1) <= 0)
              .length
              .toDouble();
          final positionZero =
              rates.zero(prior.last.position, cutoff.$1, cutoff.$2) ??
              zeros / prior.length;
          final pi = ((zeros + 8 * positionZero) / (prior.length + 8)).clamp(
            0.0,
            0.85,
          );
          final lambda = pi >= 0.999 ? mean : mean / (1 - pi);
          return (1 - pi) * (1 - math.exp(-lambda.clamp(0.02, 4.0)));
        }()
      : 1 - math.exp(-mean.clamp(0.02, 3.0));
  final over = raw.clamp(1e-4, 1 - 1e-4);
  final sideRaw = side == LineSide.over ? over : (1 - over);
  final shrunk = shrinkProjectedChance(
    projected: sideRaw,
    observed: prior.length,
    market: market,
  );
  final anchor = market;
  var shown = shrunk;
  if (shown != null &&
      anchor != null &&
      anchor.isFinite &&
      anchor > 0 &&
      anchor < 1) {
    shown = limitChanceGap(
      chance: shown,
      raw: sideRaw,
      observed: prior.length,
      market: anchor,
    );
  }
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
    capped: shown != null && shrunk != null && (shown - shrunk).abs() > 1e-9,
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
}
