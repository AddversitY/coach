import 'dart:math' as math;

import 'coach_line_v2.dart';

/// November 21, 2026. A walk-forward on nflverse closing lines, 2015–2026.
///
/// The fit for a week uses only earlier weeks. The spot model is key numbers
/// 3 and 7, a big favorite, home favorite, a divisional game, and the total
/// band. Rest, roof, and weather are scored in a separate fit and are not
/// eligible to be served, because version 2 already uses them. The file has
/// no opening line, so open-to-close movement is not a path.
///
/// A path is served only when it beats both a flat 50 percent and the
/// closing price's no-vig chance on Brier and log loss, in both 2025 and
/// 2026. None did. Version 2 stays the served game number.
const closingSpotOnCoversAdopted = false;
const closingSpotOnTotalsAdopted = false;
const closingMoneylineAdopted = false;

/// One completed regular-season game and the close that was up at kickoff.
class ClosingGame {
  const ClosingGame({
    required this.season,
    required this.week,
    required this.homeScore,
    required this.awayScore,
    required this.spreadLine,
    required this.totalLine,
    required this.divisional,
    this.roof = '',
    this.temp,
    this.wind,
    this.homeRest,
    this.awayRest,
    this.homeSpreadOdds,
    this.awaySpreadOdds,
    this.overOdds,
    this.underOdds,
    this.homeMoneyline,
    this.awayMoneyline,
  });

  final int season, week, homeScore, awayScore;
  final double spreadLine, totalLine;
  final bool divisional;
  final String roof;
  final double? temp, wind, homeRest, awayRest;
  final double? homeSpreadOdds, awaySpreadOdds, overOdds, underOdds;
  final double? homeMoneyline, awayMoneyline;

  double get margin => (homeScore - awayScore).toDouble();
  double get points => (homeScore + awayScore).toDouble();

  factory ClosingGame.fromJson(Map<String, dynamic> json) {
    double? optional(String key) =>
        json[key] is num ? (json[key] as num).toDouble() : null;
    return ClosingGame(
      season: json['season'] as int? ?? 0,
      week: json['week'] as int? ?? 0,
      homeScore: json['homeScore'] as int? ?? 0,
      awayScore: json['awayScore'] as int? ?? 0,
      spreadLine: (json['spreadLine'] as num?)?.toDouble() ?? 0,
      totalLine: (json['totalLine'] as num?)?.toDouble() ?? 0,
      divisional: json['divisional'] == true,
      roof: '${json['roof'] ?? ''}',
      temp: optional('temp'),
      wind: optional('wind'),
      homeRest: optional('homeRest'),
      awayRest: optional('awayRest'),
      homeSpreadOdds: optional('homeSpreadOdds'),
      awaySpreadOdds: optional('awaySpreadOdds'),
      overOdds: optional('overOdds'),
      underOdds: optional('underOdds'),
      homeMoneyline: optional('homeMoneyline'),
      awayMoneyline: optional('awayMoneyline'),
    );
  }
}

/// No-vig chance of the first American price. Null when either price is missing.
double? noVigAmerican(double? first, double? second) {
  double? implied(double? price) {
    if (price == null || price == 0 || !price.isFinite) return null;
    if (price < 0) return (-price) / ((-price) + 100);
    return 100 / (price + 100);
  }

  final left = implied(first);
  final right = implied(second);
  if (left == null || right == null || left + right <= 0) return null;
  return left / (left + right);
}

class ClosingBoard {
  int n = 0;
  double brier = 0;
  double logLoss = 0;

  void add(double probability, bool hit) {
    final p = probability.clamp(1e-4, 1 - 1e-4);
    final y = hit ? 1.0 : 0.0;
    n++;
    brier += (p - y) * (p - y);
    logLoss += -(hit ? math.log(p) : math.log(1 - p));
  }

  void finish() {
    if (n == 0) return;
    brier /= n;
    logLoss /= n;
  }
}

class ClosingSeason {
  final coverFlat = ClosingBoard();
  final coverPrice = ClosingBoard();
  final coverSpot = ClosingBoard();
  final coverContext = ClosingBoard();
  final coverEmpirical = ClosingBoard();
  final totalFlat = ClosingBoard();
  final totalPrice = ClosingBoard();
  final totalSpot = ClosingBoard();
  final totalContext = ClosingBoard();
  final totalEmpirical = ClosingBoard();
  final moneylineCurve = ClosingBoard();
  final moneylinePrice = ClosingBoard();
  final moneylineSpot = ClosingBoard();
  final moneylineEmpirical = ClosingBoard();

  void finish() {
    for (final board in [
      coverFlat,
      coverPrice,
      coverSpot,
      coverContext,
      coverEmpirical,
      totalFlat,
      totalPrice,
      totalSpot,
      totalContext,
      totalEmpirical,
      moneylineCurve,
      moneylinePrice,
      moneylineSpot,
      moneylineEmpirical,
    ]) {
      board.finish();
    }
  }
}

class ClosingDistributionReport {
  ClosingDistributionReport(this.seasons);
  final Map<int, ClosingSeason> seasons;

  bool get spotCoversBeatCurrent => _beats(
    (season) => season.coverSpot,
    (season) => season.coverFlat,
    (season) => season.coverPrice,
  );

  bool get spotTotalsBeatCurrent => _beats(
    (season) => season.totalSpot,
    (season) => season.totalFlat,
    (season) => season.totalPrice,
  );

  /// A moneyline model has to beat the closing price, not a curve drawn
  /// through the spread. The price itself is the market, so it is not a model.
  bool get moneylineModelBeatsPrice => _beatsModel(
    (season) => season.moneylineSpot,
    (season) => season.moneylinePrice,
  );

  bool _beats(
    ClosingBoard Function(ClosingSeason season) model,
    ClosingBoard Function(ClosingSeason season) flat,
    ClosingBoard Function(ClosingSeason season) price,
  ) {
    for (final year in [2025, 2026]) {
      final season = seasons[year];
      if (season == null) return false;
      if (!_better(model(season), flat(season))) return false;
      if (!_better(model(season), price(season))) return false;
    }
    return true;
  }

  bool _beatsModel(
    ClosingBoard Function(ClosingSeason season) model,
    ClosingBoard Function(ClosingSeason season) price,
  ) {
    for (final year in [2025, 2026]) {
      final season = seasons[year];
      if (season == null || !_better(model(season), price(season))) {
        return false;
      }
    }
    return true;
  }
}

bool _better(ClosingBoard left, ClosingBoard right) =>
    left.n >= 100 &&
    right.n >= 100 &&
    left.brier < right.brier &&
    left.logLoss < right.logLoss;

const _spotNames = ['k3', 'k7', 'big', 'homeFav', 'div', 'tlow', 'thigh'];
const _contextNames = [
  'k3',
  'k7',
  'big',
  'homeFav',
  'div',
  'rest',
  'shortHome',
  'shortAway',
  'dome',
  'wind',
  'cold',
  'tlow',
  'thigh',
];

Map<String, double> _features(ClosingGame game) {
  final size = game.spreadLine.abs();
  final dome = game.roof == 'dome' || game.roof == 'closed';
  final wind = dome || game.wind == null ? 0.0 : math.max(0, game.wind! - 8);
  final cold = dome || game.temp == null ? 0.0 : math.max(0, 35 - game.temp!);
  final homeRest = game.homeRest;
  final awayRest = game.awayRest;
  final rest = homeRest == null || awayRest == null
      ? 0.0
      : (homeRest - awayRest).clamp(-7, 7) / 7;
  return {
    'k3': size >= 2.5 && size <= 3.5 ? 1 : 0,
    'k7': size >= 6.5 && size <= 7.5 ? 1 : 0,
    'big': size >= 10 ? 1 : 0,
    'homeFav': game.spreadLine > 0 ? 1 : 0,
    'div': game.divisional ? 1 : 0,
    'rest': rest.toDouble(),
    'shortHome': homeRest != null && homeRest <= 6 ? 1 : 0,
    'shortAway': awayRest != null && awayRest <= 6 ? 1 : 0,
    'dome': dome ? 1 : 0,
    'wind': wind / 10,
    'cold': cold / 20,
    'tlow': game.totalLine < 41 ? 1 : 0,
    'thigh': game.totalLine >= 52 ? 1 : 0,
  };
}

String _spreadBand(double spread) {
  final size = spread.abs();
  final name = size < 1
      ? 'pick'
      : size >= 2.5 && size <= 3.5
      ? 'k3'
      : size >= 6.5 && size <= 7.5
      ? 'k7'
      : size >= 10
      ? 'big'
      : size >= 6
      ? 'med'
      : 'small';
  final side = spread > 0.5 ? 'home' : spread < -0.5 ? 'away' : 'pk';
  return '$side:$name';
}

String _totalBand(double total) {
  if (total < 41) return 'low';
  if (total < 47) return 'mid';
  if (total < 52) return 'high';
  return 'huge';
}

class _Fit {
  _Fit(this.mean, this.means, this.scales, this.beta, this.names);
  final double mean;
  final List<double> means, scales, beta;
  final List<String> names;

  double predict(Map<String, double> features) {
    var value = mean;
    for (var i = 0; i < names.length; i++) {
      value += beta[i] * ((features[names[i]]! - means[i]) / scales[i]);
    }
    return value;
  }
}

_Fit? _ridge(
  List<Map<String, double>> rows,
  List<double> target,
  List<String> names, {
  double lambda = 40,
}) {
  if (rows.length < 80 || rows.length != target.length) return null;
  final mean = target.reduce((a, b) => a + b) / target.length;
  final columns = <List<double>>[];
  final means = <double>[];
  final scales = <double>[];
  for (final name in names) {
    final values = [for (final row in rows) row[name]!];
    final center = values.reduce((a, b) => a + b) / values.length;
    var variance = 0.0;
    for (final value in values) {
      variance += (value - center) * (value - center);
    }
    variance /= values.length;
    final scale = variance > 1e-8 ? math.sqrt(variance) : 1.0;
    means.add(center);
    scales.add(scale);
    columns.add([for (final value in values) (value - center) / scale]);
  }
  final width = names.length;
  final count = rows.length;
  final matrix = [
    for (var row = 0; row < width; row++) List<double>.filled(width + 1, 0),
  ];
  for (var column = 0; column < width; column++) {
    for (var other = 0; other < width; other++) {
      var sum = column == other ? lambda : 0.0;
      for (var i = 0; i < count; i++) {
        sum += columns[column][i] * columns[other][i];
      }
      matrix[column][other] = sum;
    }
    var sum = 0.0;
    for (var i = 0; i < count; i++) {
      sum += columns[column][i] * (target[i] - mean);
    }
    matrix[column][width] = sum;
  }
  for (var column = 0; column < width; column++) {
    var pivot = column;
    for (var row = column + 1; row < width; row++) {
      if (matrix[row][column].abs() > matrix[pivot][column].abs()) pivot = row;
    }
    final hold = matrix[column];
    matrix[column] = matrix[pivot];
    matrix[pivot] = hold;
    final divisor = matrix[column][column];
    if (divisor.abs() < 1e-12) return null;
    for (var k = column; k <= width; k++) {
      matrix[column][k] /= divisor;
    }
    for (var row = 0; row < width; row++) {
      if (row == column) continue;
      final factor = matrix[row][column];
      for (var k = column; k <= width; k++) {
        matrix[row][k] -= factor * matrix[column][k];
      }
    }
  }
  return _Fit(
    mean,
    means,
    scales,
    [for (var row = 0; row < width; row++) matrix[row][width]],
    names,
  );
}

double _sd(List<double> values) {
  if (values.isEmpty) return 13;
  final mean = values.reduce((a, b) => a + b) / values.length;
  var variance = 0.0;
  for (final value in values) {
    variance += (value - mean) * (value - mean);
  }
  return math.sqrt(variance / values.length).clamp(8.0, 16.0);
}

double _rate(int hits, int count, {double prior = 80}) =>
    (hits + 0.5 * prior) / (count + prior);

/// Scores every path. Same-week games stay out of the fit.
ClosingDistributionReport scoreClosingLines(List<ClosingGame> games) {
  final ordered = [...games]
    ..sort((a, b) {
      final season = a.season.compareTo(b.season);
      return season != 0 ? season : a.week.compareTo(b.week);
    });
  final weeks = <String, List<int>>{};
  for (var i = 0; i < ordered.length; i++) {
    final game = ordered[i];
    (weeks['${game.season}|${game.week}'] ??= []).add(i);
  }
  final keys = weeks.keys.toList()
    ..sort((a, b) {
      final left = a.split('|');
      final right = b.split('|');
      final season = int.parse(left[0]).compareTo(int.parse(right[0]));
      return season != 0
          ? season
          : int.parse(left[1]).compareTo(int.parse(right[1]));
    });
  final features = [for (final game in ordered) _features(game)];
  final seasons = <int, ClosingSeason>{
    for (final year in [2024, 2025, 2026]) year: ClosingSeason(),
  };
  for (final key in keys) {
    final parts = key.split('|');
    final season = int.parse(parts[0]);
    final week = int.parse(parts[1]);
    if (!seasons.containsKey(season)) continue;
    final train = <int>[];
    for (final earlier in keys) {
      final earlierParts = earlier.split('|');
      final earlierSeason = int.parse(earlierParts[0]);
      final earlierWeek = int.parse(earlierParts[1]);
      if (earlierSeason < season ||
          (earlierSeason == season && earlierWeek < week)) {
        train.addAll(weeks[earlier]!);
      }
    }
    if (train.length < 200) continue;
    final coverHits = <String, int>{};
    final coverCount = <String, int>{};
    final overHits = <String, int>{};
    final overCount = <String, int>{};
    final winHits = <String, int>{};
    final winCount = <String, int>{};
    final coverResidual = <double>[];
    final totalResidual = <double>[];
    final margins = <double>[];
    for (final index in train) {
      final game = ordered[index];
      final spreadBand = _spreadBand(game.spreadLine);
      final totalBand = _totalBand(game.totalLine);
      if ((game.margin - game.spreadLine).abs() >= 1e-9) {
        coverCount[spreadBand] = (coverCount[spreadBand] ?? 0) + 1;
        if (game.margin > game.spreadLine) {
          coverHits[spreadBand] = (coverHits[spreadBand] ?? 0) + 1;
        }
        coverResidual.add(game.margin - game.spreadLine);
      }
      if ((game.points - game.totalLine).abs() >= 1e-9) {
        overCount[totalBand] = (overCount[totalBand] ?? 0) + 1;
        if (game.points > game.totalLine) {
          overHits[totalBand] = (overHits[totalBand] ?? 0) + 1;
        }
        totalResidual.add(game.points - game.totalLine);
      }
      if (game.margin != 0) {
        winCount[spreadBand] = (winCount[spreadBand] ?? 0) + 1;
        if (game.margin > 0) {
          winHits[spreadBand] = (winHits[spreadBand] ?? 0) + 1;
        }
        margins.add(game.margin);
      }
    }
    final spotCover = _ridge(
      [for (final index in train) features[index]],
      [for (final index in train) ordered[index].margin - ordered[index].spreadLine],
      _spotNames,
    );
    final spotTotal = _ridge(
      [for (final index in train) features[index]],
      [for (final index in train) ordered[index].points - ordered[index].totalLine],
      _spotNames,
    );
    final contextCover = _ridge(
      [for (final index in train) features[index]],
      [for (final index in train) ordered[index].margin - ordered[index].spreadLine],
      _contextNames,
    );
    final contextTotal = _ridge(
      [for (final index in train) features[index]],
      [for (final index in train) ordered[index].points - ordered[index].totalLine],
      _contextNames,
    );
    final coverSd = _sd(coverResidual);
    final totalSd = _sd(totalResidual);
    final marginSd = _sd(margins);
    final scored = seasons[season]!;
    for (final index in weeks[key]!) {
      final game = ordered[index];
      final row = features[index];
      final spreadBand = _spreadBand(game.spreadLine);
      if ((game.margin - game.spreadLine).abs() >= 1e-9 &&
          spotCover != null &&
          contextCover != null) {
        final hit = game.margin > game.spreadLine;
        scored.coverFlat.add(0.5, hit);
        final price = noVigAmerican(game.homeSpreadOdds, game.awaySpreadOdds);
        if (price != null) scored.coverPrice.add(price, hit);
        scored.coverSpot.add(normalCdf(spotCover.predict(row) / coverSd), hit);
        scored.coverContext.add(
          normalCdf(contextCover.predict(row) / coverSd),
          hit,
        );
        scored.coverEmpirical.add(
          _rate(coverHits[spreadBand] ?? 0, coverCount[spreadBand] ?? 0),
          hit,
        );
      }
      if ((game.points - game.totalLine).abs() >= 1e-9 &&
          spotTotal != null &&
          contextTotal != null) {
        final hit = game.points > game.totalLine;
        scored.totalFlat.add(0.5, hit);
        final price = noVigAmerican(game.overOdds, game.underOdds);
        if (price != null) scored.totalPrice.add(price, hit);
        scored.totalSpot.add(normalCdf(spotTotal.predict(row) / totalSd), hit);
        scored.totalContext.add(
          normalCdf(contextTotal.predict(row) / totalSd),
          hit,
        );
        final band = _totalBand(game.totalLine);
        scored.totalEmpirical.add(
          _rate(overHits[band] ?? 0, overCount[band] ?? 0),
          hit,
        );
      }
      if (game.margin != 0 && spotCover != null) {
        final hit = game.margin > 0;
        scored.moneylineCurve.add(normalCdf(game.spreadLine / marginSd), hit);
        final price = noVigAmerican(game.homeMoneyline, game.awayMoneyline);
        if (price != null) scored.moneylinePrice.add(price, hit);
        scored.moneylineSpot.add(
          normalCdf((game.spreadLine + spotCover.predict(row)) / marginSd),
          hit,
        );
        scored.moneylineEmpirical.add(
          _rate(winHits[spreadBand] ?? 0, winCount[spreadBand] ?? 0),
          hit,
        );
      }
    }
  }
  for (final season in seasons.values) {
    season.finish();
  }
  return ClosingDistributionReport(seasons);
}
