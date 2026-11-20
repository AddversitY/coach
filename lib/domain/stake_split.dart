import 'odds.dart';

/// A calculator stake. Nothing is stored.
class StakeLeg {
  const StakeLeg({
    required this.label,
    required this.book,
    required this.decimal,
    required this.stake,
  });

  final String label, book;
  final double decimal, stake;
  double get profitIfWins => stake * (decimal - 1);
}

class StakeSplit {
  const StakeSplit({required this.total, required this.legs});
  final double total;
  final List<StakeLeg> legs;

  double result({required List<bool> wins}) {
    if (wins.length != legs.length) {
      throw ArgumentError('Each leg needs a win or a loss.');
    }
    var sum = 0.0;
    for (var i = 0; i < legs.length; i++) {
      sum += wins[i] ? legs[i].profitIfWins : -legs[i].stake;
    }
    return sum;
  }
}

/// Split [total] across legs in proportion to each price's implied
/// probability. The same split a two-sided hedge uses. It does not make
/// a profit certain, and it is not saved.
StakeSplit hedgeSplit({
  required double total,
  required List<({String label, String book, double decimal})> legs,
}) {
  if (!total.isFinite || total <= 0 || total > 1000000) {
    throw ArgumentError('Enter a stake above 0 and at most 1,000,000.');
  }
  if (legs.length < 2) {
    throw ArgumentError('A split needs two prices.');
  }
  final implied = <double>[];
  for (final leg in legs) {
    implied.add(impliedProbability(leg.decimal));
  }
  final sum = implied.reduce((a, b) => a + b);
  return StakeSplit(
    total: total,
    legs: [
      for (var i = 0; i < legs.length; i++)
        StakeLeg(
          label: legs[i].label,
          book: legs[i].book,
          decimal: legs[i].decimal,
          stake: total * implied[i] / sum,
        ),
    ],
  );
}

String impliedProbabilityNote(double decimal) {
  final chance = impliedProbability(decimal);
  final percent = (chance * 100).toStringAsFixed(1);
  return 'Implied probability is the price turned into a percentage. '
      'A decimal price of ${decimal.toStringAsFixed(2)} is about $percent%. '
      'Even money, +100, is 50%. The fee is still in that percentage. '
      'A fee-free figure removes the hold only when both sides were posted.';
}
