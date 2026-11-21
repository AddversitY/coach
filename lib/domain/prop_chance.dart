import 'dart:math' as math;

import 'value_check.dart';

/// Pseudo-games mixed in at the book's no-vig chance.
///
/// A player prop season is about 17 games. This prior is about two
/// seasons, so one hot month cannot become a 75% chance.
const propPriorGames = 32.0;

/// Ordinary gap limit, in probability. 0.10 is 10 percentage points.
const propEdgeCap = 0.10;

/// The widest gap a long record is allowed to publish.
const propEdgeCapCeiling = 0.15;

/// Recorded games required before the cap may open past [propEdgeCap].
const propStrongSample = 30;

/// Standard error, in probability, that still counts as a tight record.
const propStrongError = 0.08;

/// Weight on the model's disagreement with the book's no-vig chance.
///
/// Fit on 909 real 2026 props with two-sided closes
/// (`assets/prop-closes.json`, `test/market_blend_test.dart`). The weight
/// that scored best was 0.05; fit on the other week only it was 0 and 0.1.
/// The model adds almost nothing on top of the close, so the served chance
/// sits close to the market. The older 32-game shrink scored worse than the
/// close (log loss 0.7017 against 0.6958); this pool scored 0.6956.
const propModelWeight = 0.05;

/// The book's no-vig chance, moved toward [model] by [weight] in log odds.
double? poolWithMarket({
  required double model,
  required double market,
  double weight = propModelWeight,
}) {
  if (!model.isFinite || !market.isFinite) return null;
  if (market <= 0 || market >= 1) return null;
  double logit(double p) {
    final q = p.clamp(1e-4, 1 - 1e-4).toDouble();
    return math.log(q / (1 - q));
  }

  final x = logit(market) + weight * (logit(model) - logit(market));
  final chance = 1 / (1 + math.exp(-x));
  if (!chance.isFinite || chance <= 0 || chance >= 1) return null;
  return chance;
}

const propPooledSource =
    "the book's no-vig chance, moved slightly toward a usage projection";

const propChanceSource =
    "the recorded games, pulled toward the book's no-vig chance";

const propEvenSource = 'the recorded games, pulled slightly toward even';

const propProjectionSource =
    "a usage projection, pulled toward the book's no-vig chance";

/// Our chance for one prop side.
///
/// Fewer than four recorded games stays null. With a no-vig [market],
/// the chance is a binomial mean pulled toward that market, then held
/// inside [propEdgeCap] unless [propEdgeCapFor] opens the cap. With no
/// market, it falls back to [shrunkClearRate].
double? propSideChance({
  required int hits,
  required int observed,
  required double? market,
}) {
  if (observed < 4) return null;
  if (hits < 0 || hits > observed) {
    throw ArgumentError('Hits must sit inside the recorded games.');
  }
  final anchor = market;
  if (anchor == null || !anchor.isFinite || anchor <= 0 || anchor >= 1) {
    return shrunkClearRate(hits: hits, observed: observed);
  }
  final blended =
      (hits + propPriorGames * anchor) / (observed + propPriorGames);
  final cap = propEdgeCapFor(hits: hits, observed: observed, market: anchor);
  final gap = (blended - anchor).clamp(-cap, cap).toDouble();
  final chance = anchor + gap;
  if (chance <= 0 || chance >= 1 || !chance.isFinite) return null;
  return chance;
}

/// How far [propSideChance] may sit from the market.
///
/// The ordinary cap is 10 points. It opens only when the record is at
/// least [propStrongSample] games, the raw rate's standard error is at
/// most [propStrongError], and the raw rate itself is more than 10
/// points from the market. The opened cap is the raw gap minus two
/// standard errors, and it never passes [propEdgeCapCeiling].
double propEdgeCapFor({
  required int hits,
  required int observed,
  required double market,
}) {
  if (observed <= 0) return propEdgeCap;
  return propEdgeCapForRate(
    raw: hits / observed,
    observed: observed,
    market: market,
  );
}

/// Same cap as [propEdgeCapFor], when the raw chance is a projection
/// rather than a hit count. [raw] is that chance, between 0 and 1.
double propEdgeCapForRate({
  required double raw,
  required int observed,
  required double market,
}) {
  if (observed < propStrongSample) return propEdgeCap;
  if (!raw.isFinite || raw <= 0 || raw >= 1) return propEdgeCap;
  final variance = raw * (1 - raw) / observed;
  final error = variance <= 0 ? 0.0 : math.sqrt(variance);
  if (error > propStrongError) return propEdgeCap;
  final rawGap = (raw - market).abs();
  if (rawGap <= propEdgeCap) return propEdgeCap;
  final evidence = rawGap - 2 * error;
  if (evidence <= propEdgeCap) return propEdgeCap;
  if (evidence >= propEdgeCapCeiling) return propEdgeCapCeiling;
  return evidence;
}

/// Pull a projected clear-chance toward the no-vig, then cap it.
///
/// The weight on the projection is the number of games behind it. The
/// weight on the market is [propPriorGames], the same prior as the
/// hit-rate chance. Fewer than four games stays null. A missing market
/// uses the even shrink, two wins and two losses.
double? shrinkProjectedChance({
  required double projected,
  required int observed,
  required double? market,
}) {
  if (observed < 4) return null;
  if (!projected.isFinite || projected <= 0 || projected >= 1) return null;
  final anchor = market;
  final open = anchor != null && anchor.isFinite && anchor > 0 && anchor < 1;
  if (!open) {
    final blended = (observed * projected + 2) / (observed + 4);
    if (!blended.isFinite || blended <= 0 || blended >= 1) return null;
    return blended;
  }
  final blended =
      (observed * projected + propPriorGames * anchor) /
      (observed + propPriorGames);
  final cap = propEdgeCapForRate(
    raw: projected,
    observed: observed,
    market: anchor,
  );
  final gap = (blended - anchor).clamp(-cap, cap).toDouble();
  final chance = anchor + gap;
  if (!chance.isFinite || chance <= 0 || chance >= 1) return null;
  return chance;
}

/// Pull a chance back inside the same gap the shrink uses.
///
/// A map fit on earlier weeks can move a chance past that gap. The card
/// still has to stay inside it.
double limitChanceGap({
  required double chance,
  required double raw,
  required int observed,
  required double market,
}) {
  if (!chance.isFinite || !market.isFinite || market <= 0 || market >= 1) {
    return chance;
  }
  final cap = propEdgeCapForRate(raw: raw, observed: observed, market: market);
  final limited = market + (chance - market).clamp(-cap, cap);
  if (!limited.isFinite || limited <= 0 || limited >= 1) return chance;
  return limited.toDouble();
}

String propChanceNote({
  required int hits,
  required int observed,
  required bool usedMarket,
}) {
  if (!usedMarket) {
    return 'Recorded $hits of $observed. Two wins and two losses are mixed in before that becomes our chance, so a short run cannot look certain.';
  }
  return 'Recorded $hits of $observed. ${propPriorGames.toInt()} games at the book\'s no-vig chance are mixed in. The gap stays within ${(propEdgeCap * 100).toInt()} points unless the record is long and one-sided.';
}
