import 'market_math.dart';
import 'odds.dart';

/// One book's two-sided price for a prop. A missing side stays null.
class PropBookPrice {
  const PropBookPrice({
    required this.book,
    this.overDecimal,
    this.underDecimal,
    this.line,
    this.at,
  });

  final String book;
  final double? overDecimal;
  final double? underDecimal;
  final double? line;
  final DateTime? at;
}

/// No-vig consensus and the Pinnacle price, plus books that are both
/// old and far from the others.
class PropConsensus {
  const PropConsensus({
    required this.books,
    required this.consensus,
    required this.pinnacle,
    required this.prior,
    required this.staleBooks,
    required this.detail,
  });

  /// Books with both sides, after stale prices are left out.
  final int books;

  /// Mean no-vig chance of the over. Null when fewer than two books remain.
  final double? consensus;

  /// Pinnacle's own no-vig over, when that book posted both sides.
  final double? pinnacle;

  /// Half Pinnacle and half the other books, when both exist.
  /// Otherwise whichever one exists. Null when neither does.
  final double? prior;
  final List<String> staleBooks;
  final String detail;

  static const unavailable = PropConsensus(
    books: 0,
    consensus: null,
    pinnacle: null,
    prior: null,
    staleBooks: [],
    detail: 'No two-sided prices, so the consensus is unavailable.',
  );
}

/// How far a book's no-vig chance has to sit from the others before it
/// can be called an outlier. 0.08 is 8 percentage points.
const propOutlierGap = 0.08;

/// An outlier is stale only when its price is also this much older than
/// the newest price in the group. Without a time, it is not called stale.
const propStaleGap = Duration(hours: 3);

const _sharpNames = {'pinnacle'};

/// No-vig consensus of [rows]. One-sided prices are left out.
///
/// A book is stale when its no-vig over is at least [propOutlierGap] from
/// the median of the other books and its timestamp is at least
/// [propStaleGap] older than the newest timestamp. Stale books are named
/// and left out of the average. A book with no timestamp is never called
/// stale. A stale Pinnacle price is left out of the prior as well.
PropConsensus propConsensus(List<PropBookPrice> rows) {
  final fair = <_Fair>[];
  for (final row in rows) {
    final over = _novig(row.overDecimal, row.underDecimal);
    if (over == null) continue;
    fair.add(_Fair(row.book, over, row.at));
  }
  if (fair.isEmpty) return PropConsensus.unavailable;
  final newest = _newest(fair);
  final stale = <String>[];
  final kept = <_Fair>[];
  for (final row in fair) {
    final others = [
      for (final other in fair)
        if (other.book != row.book) other.over,
    ];
    final center = others.isEmpty ? null : _median(others);
    final at = row.at;
    final old =
        newest != null && at != null && newest.difference(at) >= propStaleGap;
    final off = center != null && (row.over - center).abs() >= propOutlierGap;
    if (old && off) {
      stale.add(row.book);
      continue;
    }
    kept.add(row);
  }
  final pinnacle = _named(kept, _sharpNames);
  final others = [
    for (final row in kept)
      if (!_sharpNames.contains(row.book.toLowerCase())) row.over,
  ];
  final consensus = kept.length >= 2
      ? _mean(kept.map((row) => row.over))
      : null;
  final otherMean = others.length >= 2
      ? _mean(others)
      : (others.length == 1 ? others.single : null);
  double? prior;
  if (pinnacle != null && otherMean != null) {
    prior = 0.5 * pinnacle + 0.5 * otherMean;
  } else {
    prior = pinnacle ?? consensus;
  }
  final staleText = stale.isEmpty
      ? 'No stale outlier.'
      : 'Stale ${stale.join(', ')}: older than the newest price and at least ${(propOutlierGap * 100).round()} points off the others.';
  final priorText = prior == null
      ? 'The prior is unavailable.'
      : pinnacle != null && otherMean != null
      ? 'The prior is half Pinnacle and half the other books.'
      : pinnacle != null
      ? 'The prior is Pinnacle. The other books did not form a consensus.'
      : 'Pinnacle did not post both sides. The prior is the no-vig consensus.';
  return PropConsensus(
    books: kept.length,
    consensus: consensus,
    pinnacle: pinnacle,
    prior: prior,
    staleBooks: stale,
    detail: '$priorText $staleText',
  );
}

class _Fair {
  const _Fair(this.book, this.over, this.at);
  final String book;
  final double over;
  final DateTime? at;
}

double? _novig(double? over, double? under) {
  if (over == null || under == null || over <= 1 || under <= 1) return null;
  try {
    return removeVigProportional([
      impliedProbability(over),
      impliedProbability(under),
    ]).probabilities.first;
  } on ArgumentError {
    return null;
  }
}

double? _named(List<_Fair> rows, Set<String> names) {
  for (final row in rows) {
    if (names.contains(row.book.toLowerCase())) return row.over;
  }
  return null;
}

DateTime? _newest(List<_Fair> rows) {
  DateTime? best;
  for (final row in rows) {
    final at = row.at;
    if (at == null) continue;
    if (best == null || at.isAfter(best)) best = at;
  }
  return best;
}

double _mean(Iterable<double> values) {
  var sum = 0.0;
  var n = 0;
  for (final value in values) {
    sum += value;
    n++;
  }
  return n == 0 ? 0 : sum / n;
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}
