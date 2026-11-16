import 'dart:convert';
import 'dart:math' as math;

import 'game_research.dart';
import 'game_script_simulation.dart';
import 'history.dart';
import 'odds.dart';
import 'player_stats.dart';
import 'eastern.dart';

const coachAnalysisVersion = 'copula-robust-research-v1';

class AnalysisLeg {
  const AnalysisLeg({
    required this.player,
    required this.event,
    required this.metric,
    required this.line,
    required this.over,
  });
  final GameResearchPlayer player;
  final SportEvent event;
  final ResearchMetric metric;
  final double line;
  final bool over;
  String get id => '${event.id}/${player.id}/${metric.key}/$line/$over';
  String get label =>
      '${player.name} ${over ? 'Over' : 'Under'} $line ${metric.shortLabel} · ${event.away} at ${event.home} · ${formatEastern(event.startsAt)}';
  List<double> get recorded => player.games
      .map((g) => g.stats[metric.key])
      .whereType<num>()
      .map((v) => v.toDouble())
      .toList();
  String get workloadMetric => metric.key == 'passing_yards'
      ? 'attempts'
      : metric.key == 'rushing_yards'
      ? 'carries'
      : 'targets';
  List<double> get usageSamples => player.games
      .map((g) => g.stats[workloadMetric])
      .whereType<num>()
      .where((v) => v.isFinite && v >= 0)
      .map((v) => v.toDouble())
      .toList();
  double? get usageFloor {
    final sample = usageSamples..sort();
    return sample.length < 5
        ? null
        : sample[((sample.length - 1) * .1).floor()];
  }

  double? get usageCv {
    final sample = usageSamples;
    if (sample.length < 5) return null;
    final average = sample.reduce((a, b) => a + b) / sample.length;
    if (average <= 0) return null;
    return math.sqrt(
          sample.map((v) => math.pow(v - average, 2)).reduce((a, b) => a + b) /
              (sample.length - 1),
        ) /
        average;
  }

  ScriptLeg fit({double multiplier = 1}) {
    final values = recorded;
    if (values.length < 6 ||
        values.any((v) => !v.isFinite) ||
        !line.isFinite ||
        line > 1000 ||
        line % 1 != .5 ||
        line < 0) {
      throw ArgumentError(
        'Each leg needs six recorded games and an explicit non-push half-line.',
      );
    }
    final adjusted = values.map((v) => v * multiplier).toList();
    final mean = adjusted.reduce((a, b) => a + b) / adjusted.length;
    final variance =
        adjusted.map((v) => math.pow(v - mean, 2)).reduce((a, b) => a + b) /
        (adjusted.length - 1);
    final hits = adjusted.where((v) => over ? v > line : v < line).length;
    // Fixed fair-50% prior, matching the dependence research. No claim of a
    // calibrated workload marginal or sportsbook edge follows from this fit.
    return ScriptLeg(
      id: id,
      eventId: event.id,
      playerId: player.id,
      team: player.team,
      metric: metric.key,
      line: line,
      over: over,
      chance: (hits + 16) / (adjusted.length + 32),
      mean: mean,
      sd: math.max(math.sqrt(variance), math.max(1, mean.abs() * .1)),
    );
  }
}

class StressCase {
  const StressCase(this.name, this.multiplier);
  final String name;
  final double multiplier;
}

const coachStressCases = [
  StressCase('Baseline', 1),
  StressCase('Usage −15%', .85),
  StressCase('Usage +15%', 1.15),
  StressCase('Efficiency −10%', .90),
  StressCase('Efficiency +10%', 1.10),
  StressCase('Lower pace proxy −10%', .90),
  StressCase('Higher pace proxy +10%', 1.10),
  StressCase('Usage/efficiency downside', .85 * .90),
  StressCase('Usage/efficiency upside', 1.15 * 1.10),
];

class CoachAnalysis {
  const CoachAnalysis({
    required this.legs,
    required this.createdAt,
    required this.fingerprint,
    required this.rows,
    required this.summary,
    required this.validation,
    this.simulation,
    this.ticketPrice,
    this.conditionalEv,
    this.blocked = false,
    this.reason,
    this.kind = 'simulation',
  });
  final List<AnalysisLeg> legs;
  final DateTime createdAt;
  final String fingerprint, summary, kind;
  final Map<String, dynamic> validation;
  final List<Map<String, dynamic>> rows;
  final ScriptSimulation? simulation;
  final double? ticketPrice, conditionalEv;
  final bool blocked;
  final String? reason;
  Set<String> get eventIds => legs.map((l) => l.event.id).toSet();
  Set<String> get playerIds => legs.map((l) => l.player.id).toSet();
  Map<String, dynamic> toEvidence() => {
    'tool': kind,
    'version': coachAnalysisVersion,
    'experimental': true,
    'hasEdge': false,
    'createdAt': createdAt.toIso8601String(),
    'summary': summary,
    'legs': legs.map((l) => l.label).toList(),
    'legInputs': [
      for (final l in legs)
        {
          'playerId': l.player.id,
          'eventId': l.event.id,
          'stat': l.metric.key,
          'recordedGames': l.recorded.length,
          'workload': l.workloadMetric,
          'workloadRecords': l.usageSamples.length,
          'recordedP10Workload': l.usageFloor,
          'workloadCoefficientOfVariation': l.usageCv,
        },
    ],
    'rows': rows,
    if (simulation != null) 'joint': simulation!.joint,
    if (simulation != null) 'independent': simulation!.independent,
    if (simulation != null)
      'samplingInterval': [simulation!.lower, simulation!.upper],
    'intervalExcludesModelUncertainty': true,
    'validation': validation,
    if (ticketPrice != null) 'userEnteredUnverifiedTicketDecimal': ticketPrice,
    if (conditionalEv != null) 'conditionalEvPerUnit': conditionalEv,
    'forecastStatus': 'Research assumptions only; no validated betting edge',
    'blocked': blocked,
    if (reason != null) 'reason': reason,
  };
}

/// Exact selection/record provenance makes a changed quote or source invalidate
/// the old result. A new timestamp alone never makes an old observation fresh.
String analysisFingerprint(
  List<AnalysisLeg> legs,
  OddsBoard prices,
  PlayerStatsDataset data,
) => jsonEncode({
  'version': coachAnalysisVersion,
  'cutoff': data.metadata['cutoff'],
  'retrievedAt': data.metadata['retrievedAt'],
  'legs': [
    for (final l in legs)
      {
        'id': l.id,
        'kickoff': l.event.startsAt.toIso8601String(),
        'records': [
          for (final g in data.rows.where(
            (g) =>
                g.playerId == l.player.id &&
                g.season == l.player.latest.season &&
                g.date.isBefore(l.event.startsAt),
          ))
            [
              g.identity,
              g.date.toIso8601String(),
              g.stats[l.metric.key],
              g.stats[l.workloadMetric],
            ],
        ],
      },
  ],
  'quotes':
      (prices.quotes
          .where(
            (q) => legs.any(
              (l) =>
                  q.selection.eventId == l.event.id &&
                  q.selection.participant == l.player.name &&
                  q.selection.market == l.metric.market,
            ),
          )
          .map((q) => jsonEncode(q.toJson()))
          .toList()
        ..sort()),
});

class CoachAnalysisEngine {
  const CoachAnalysisEngine();
  List<AnalysisLeg> parse(
    String question, {
    required OddsBoard board,
    required PlayerStatsDataset data,
    required DateTime now,
  }) {
    final clauses = question.split(
      RegExp(r'\s+(?:and|plus)\s+|\s*\+\s*|\s*;\s*', caseSensitive: false),
    );
    final legs = <AnalysisLeg>[];
    final upcoming = board.events.where((e) => e.startsAt.isAfter(now)).toList()
      ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    for (final clause in clauses) {
      final line = RegExp(
        r'\b(over|under)\s+(\d+(?:\.\d+)?)',
        caseSensitive: false,
      ).firstMatch(clause);
      if (line == null) continue;
      final lower = clause.toLowerCase();
      final metric = lower.contains('receptions')
          ? receptionsResearch
          : lower.contains('receiv')
          ? receivingResearch
          : lower.contains('rush')
          ? rushingResearch
          : lower.contains('pass')
          ? passingResearch
          : null;
      if (metric == null) {
        throw ArgumentError(
          'Specify passing yards, rushing yards, receiving yards, or receptions for every leg.',
        );
      }
      final candidates = <(SportEvent, GameResearchPlayer)>[];
      for (final event in upcoming) {
        for (final p in buildGameResearch(
          data: data,
          event: event,
          now: now,
        ).players) {
          if (lower.contains(p.name.toLowerCase()) &&
              p.metrics.any((m) => m.key == metric.key)) {
            candidates.add((event, p));
          }
        }
      }
      final ids = candidates.map((c) => c.$2.id).toSet();
      if (ids.length != 1) {
        throw ArgumentError(
          'Use an exact, unambiguous recorded player name for each leg.',
        );
      }
      final picked = candidates.first;
      legs.add(
        AnalysisLeg(
          player: picked.$2,
          event: picked.$1,
          metric: metric,
          line: double.parse(line.group(2)!),
          over: line.group(1)!.toLowerCase() == 'over',
        ),
      );
    }
    if (legs.isEmpty || legs.length > 8) {
      throw ArgumentError(
        'Give 1–8 explicit player/stat/side/line selections. Example: Josh Allen over 245.5 passing yards and James Cook over 65.5 rushing yards.',
      );
    }
    if (legs.map((l) => l.id).toSet().length != legs.length) {
      throw ArgumentError(
        'Duplicate legs are the same exposure, not separate chances.',
      );
    }
    for (final l in legs) {
      l.fit();
    }
    return legs;
  }

  CoachAnalysis run({
    required List<AnalysisLeg> legs,
    required OddsBoard prices,
    required PlayerStatsDataset data,
    required List<HistoricalGame> scores,
    required Map<String, dynamic> validation,
    required DateTime now,
    bool stress = false,
    double? ticketPrice,
  }) {
    if (legs.isEmpty ||
        legs.length > 8 ||
        legs.any((l) => !l.event.startsAt.isAfter(now))) {
      throw ArgumentError('Use upcoming games with 1–8 supported legs.');
    }
    if (ticketPrice != null &&
        (!ticketPrice.isFinite || ticketPrice <= 1 || ticketPrice > 10000)) {
      throw ArgumentError(
        'Ticket odds must be finite decimal odds greater than 1.',
      );
    }
    ScriptSimulation? base;
    final cases = stress ? coachStressCases : const [StressCase('Baseline', 1)];
    final rows = <Map<String, dynamic>>[];
    for (final scenario in cases) {
      final fitted = legs
          .map((l) => l.fit(multiplier: scenario.multiplier))
          .toList();
      if (fitted.length == 1) {
        final p = fitted.single.chance;
        rows.add({
          'scenario': scenario.name,
          'chance': p,
          'lowestLeg': p,
          if (ticketPrice != null)
            'conditionalEv': expectedValue(ticketPrice, p),
        });
      } else {
        final season = legs
            .map(
              (l) =>
                  l.event.startsAt.year - (l.event.startsAt.month <= 2 ? 1 : 0),
            )
            .reduce(math.min);
        final simulation = simulateGameScripts(
          legs: fitted,
          events: {for (final l in legs) l.event.id: l.event}.values.toList(),
          players: data.rows,
          games: scores,
          beforeSeason: season,
        );
        if (scenario.name == 'Baseline') base = simulation;
        rows.add({
          'scenario': scenario.name,
          'chance': simulation.joint,
          'independent': simulation.independent,
          'lowestLeg': simulation.legHitRates.reduce(math.min),
          if (ticketPrice != null)
            'conditionalEv': expectedValue(ticketPrice, simulation.joint),
        });
      }
    }
    final worst = rows
        .map((r) => (r['chance'] as num).toDouble())
        .reduce(math.min);
    return CoachAnalysis(
      legs: legs,
      createdAt: now,
      fingerprint: analysisFingerprint(legs, prices, data),
      rows: rows,
      simulation: base,
      validation: validation,
      kind: stress ? 'stress_test' : 'joint_probability',
      ticketPrice: ticketPrice,
      conditionalEv: ticketPrice == null
          ? null
          : expectedValue(
              ticketPrice,
              (rows.first['chance'] as num).toDouble(),
            ),
      summary: stress
          ? '${rows.length} assumption scenarios tested. Lowest scenario estimate: ${(100 * worst).toStringAsFixed(1)}%. Usage and pace multipliers are stress assumptions, not injury or weather forecasts.'
          : '${legs.length == 1 ? 'Single-leg research estimate' : 'Gaussian-copula joint estimate using 10,000 seeded draws'}. Marginals use recorded outcomes and a fixed 32-game fair-50% prior. Sparse historical pairs revert to independence. These estimates are experimental.',
    );
  }

  /// Enumerates a bounded candidate set against the SAME fixed stress grid.
  /// Rankings favor the worst scenario, then the baseline. They do not select a
  /// betting recommendation or claim that a high hit rate implies positive EV.
  List<CoachAnalysis> rank({
    required List<List<AnalysisLeg>> candidates,
    required OddsBoard prices,
    required PlayerStatsDataset data,
    required List<HistoricalGame> scores,
    required Map<String, dynamic> validation,
    required DateTime now,
  }) {
    if (candidates.isEmpty || candidates.length > 12) {
      throw ArgumentError('Use 1–12 candidate tickets.');
    }
    if (candidates.any(
      (ticket) =>
          ticket.any((leg) => leg.usageFloor == null || leg.usageCv == null),
    )) {
      throw ArgumentError(
        'Robust ranking requires at least five recorded workload values and a positive usage baseline for every candidate leg.',
      );
    }
    final results = [
      for (final legs in candidates)
        run(
          legs: legs,
          prices: prices,
          data: data,
          scores: scores,
          validation: validation,
          now: now,
          stress: true,
        ),
    ];
    double floor(CoachAnalysis r) =>
        r.rows.map((x) => (x['chance'] as num).toDouble()).reduce(math.min);
    results.sort((a, b) {
      final order = floor(b).compareTo(floor(a));
      if (order != 0) return order;
      final aCv = a.legs.map((l) => l.usageCv!).reduce(math.max),
          bCv = b.legs.map((l) => l.usageCv!).reduce(math.max);
      final consistency = aCv.compareTo(bCv);
      return consistency != 0
          ? consistency
          : (b.rows.first['chance'] as num).compareTo(
              a.rows.first['chance'] as num,
            );
    });
    return results;
  }
}
