import 'dart:math' as math;

import 'hit_rate.dart';

/// Lower regularized gamma, P(shape, x / scale) when [x] is the raw stat.
///
/// Shape and scale come from the mean and the spread. A non-positive
/// boundary is a certain over. The same half-yard step used by the
/// lognormal curve is used here, so an integer line still leaves the tie out.
double gammaSideChance({
  required double mean,
  required double sd,
  required double line,
  required LineSide side,
}) {
  final center = mean <= 0.5 ? 0.5 : mean;
  final width = sd <= 0 ? 1.0 : sd;
  final shape = (center * center) / (width * width);
  final scale = (width * width) / center;
  final whole = (line - line.roundToDouble()).abs() < 1e-9;
  final boundary = whole
      ? (side == LineSide.over ? line + 0.5 : line - 0.5)
      : line;
  if (boundary <= 0) return side == LineSide.over ? 1 - 1e-4 : 1e-4;
  final cdf = gammaCdf(boundary / scale, shape);
  final chance = side == LineSide.over ? 1 - cdf : cdf;
  return chance.clamp(1e-4, 1 - 1e-4);
}

/// P(X ≤ k) for a zero-inflated negative binomial whose mixture mean is [mean].
///
/// [zeroRate] is the chance of the extra zero. The counting part is scaled
/// so the mixture still averages [mean]. A zero rate of 0 is the ordinary
/// negative binomial.
double zeroInflatedSideChance({
  required double mean,
  required double sd,
  required double line,
  required LineSide side,
  required double zeroRate,
}) {
  final pi = zeroRate.clamp(0.0, 0.85);
  final mu = mean <= 0
      ? 0.05
      : (pi <= 1e-6 ? (mean <= 0 ? 0.05 : mean) : mean / (1 - pi));
  final variance = math.max(sd * sd, mu + 0.25);
  final r = (mu * mu / (variance - mu)).clamp(0.3, 200.0);
  if (side == LineSide.over) {
    final cdf = negativeBinomialCdf(mu, r, line.floor());
    return ((1 - pi) * (1 - cdf)).clamp(1e-4, 1 - 1e-4);
  }
  final whole = (line - line.roundToDouble()).abs() < 1e-9;
  final max = whole ? line.floor() - 1 : line.floor();
  if (max < 0) return pi.clamp(1e-4, 1 - 1e-4);
  final cdf = negativeBinomialCdf(mu, r, max);
  return (pi + (1 - pi) * cdf).clamp(1e-4, 1 - 1e-4);
}

/// Lanczos approximation of ln Γ(z).
double lnGamma(double z) {
  const coefficients = <double>[
    0.99999999999980993,
    676.5203681218851,
    -1259.1392167224028,
    771.32342877765313,
    -176.61502916214059,
    12.507343278686905,
    -0.13857109526572012,
    9.9843695780195716e-6,
    1.5056327351493116e-7,
  ];
  if (z < 0.5) {
    return math.log(math.pi / math.sin(math.pi * z)) - lnGamma(1 - z);
  }
  var x = coefficients[0];
  final y = z - 1;
  for (var i = 1; i < coefficients.length; i++) {
    x += coefficients[i] / (y + i);
  }
  final t = y + 7.5;
  return 0.5 * math.log(2 * math.pi) +
      (y + 0.5) * math.log(t) -
      t +
      math.log(x);
}

/// Lower regularized gamma P(shape, x). x is already divided by the scale.
double gammaCdf(double x, double shape) {
  if (x <= 0 || shape <= 0 || !x.isFinite || !shape.isFinite) return 0;
  final upper = x < shape + 1
      ? 1 - _gammaSeries(x, shape)
      : _gammaContinued(x, shape);
  final cdf = 1 - upper;
  if (cdf < 0) return 0;
  if (cdf > 1) return 1;
  return cdf;
}

double _gammaSeries(double x, double shape) {
  var term = 1.0 / shape;
  var sum = term;
  for (var n = 1; n < 200; n++) {
    term *= x / (shape + n);
    sum += term;
    if (term.abs() < sum.abs() * 1e-12) break;
  }
  final log = -x + shape * math.log(x) - lnGamma(shape) + math.log(sum);
  final value = math.exp(log);
  if (value < 0) return 0;
  if (value > 1) return 1;
  return value;
}

double _gammaContinued(double x, double shape) {
  const tiny = 1e-30;
  var b = x + 1 - shape;
  var c = 1 / tiny;
  var d = 1 / b;
  var h = d;
  for (var i = 1; i <= 200; i++) {
    final an = -i * (i - shape);
    b += 2;
    d = an * d + b;
    if (d.abs() < tiny) d = tiny;
    c = b + an / c;
    if (c.abs() < tiny) c = tiny;
    d = 1 / d;
    final delta = d * c;
    h *= delta;
    if ((delta - 1).abs() < 1e-12) break;
  }
  final log = -x + shape * math.log(x) - lnGamma(shape);
  final value = math.exp(log) * h;
  if (value < 0) return 0;
  if (value > 1) return 1;
  return value;
}

/// Negative-binomial CDF used by the receptions curve. k below 0 is 0.
double negativeBinomialCdf(double mean, double r, int k) {
  if (k < 0) return 0;
  final p = r / (r + mean);
  var pmf = math.pow(p, r).toDouble();
  if (!pmf.isFinite || pmf < 0) pmf = 0;
  var cdf = pmf;
  final fail = 1 - p;
  for (var i = 1; i <= k; i++) {
    pmf *= (i + r - 1) / i * fail;
    cdf += pmf;
    if (cdf >= 1) return 1;
  }
  if (cdf < 0) return 0;
  if (cdf > 1) return 1;
  return cdf;
}
