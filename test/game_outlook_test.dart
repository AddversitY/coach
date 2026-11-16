import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/game_outlook.dart';
import 'package:odds_edge/domain/odds.dart';
import 'package:odds_edge/domain/coach_telemetry.dart';

Map<String, dynamic> gameOutlookFixture(
  SportEvent event,
  DateTime now, {
  String? bookId,
}) => {
  'available': true,
  'schemaVersion': 1,
  'version': 'test',
  'modelVersion': 'test',
  'event': event.toJson(),
  'createdAt': now.toIso8601String(),
  'cutoff': '2026-11-12',
  'summary':
      'Game forecasts and exact-price research. No validated betting edge.',
  'basis': 'market_anchored',
  'hasEdge': false,
  'recommendationsReady': false,
  'bookId': bookId,
  'books': [
    {'id': 'draftkings', 'name': 'DraftKings'},
  ],
  'score': {
    'home': 24.0,
    'away': 21.0,
    'homeWin': .57,
    'tie': .02,
    'marginMedian': 3,
    'totalMedian': 45,
    'marginRange': [-10, 17],
    'totalRange': [30, 60],
  },
  'categories': [
    for (final market in ['spreads', 'totals', 'h2h', 'props'])
      {
        'market': market,
        'label': {
          'spreads': 'Spread',
          'totals': 'Game total',
          'h2h': 'Moneyline',
          'props': 'Player props',
        }[market],
        'status': market == 'spreads'
            ? 'priced_research'
            : 'prices_unavailable',
        'totalRows': market == 'spreads' ? 1 : 0,
        'rows': [
          if (market == 'spreads')
            {
              'selection': Selection(
                eventId: event.id,
                market: 'spreads',
                outcome: event.home,
                point: -3.5,
                rules: 'game_market_unverified',
              ).toJson(),
              'book': 'DraftKings',
              'bookId': 'draftkings',
              'decimal': 1.91,
              'win': .55,
              'push': 0.0,
              'loss': .45,
              'minimumDecimal': 1 / .55,
              'conditionalEv': .55 * 1.91 - 1,
              'sourceAt': now.toIso8601String(),
              'collectedAt': now.toIso8601String(),
              'hasEdge': false,
              'modelValidated': false,
              'blocked': false,
            },
        ],
      },
  ],
  'projections': [
    {
      'name': 'Recorded Quarterback',
      'label': 'Pass yards',
      'mean': 235.0,
      'expectedWorkload': 32.0,
      'workload': 'attempts',
      'records': 8,
    },
  ],
  'productionTrial': {
    'available': true,
    'version': 'production-joint-v1',
    'hasEdge': false,
    'adopted': false,
    'status': 'shadow_only',
    'cutoff': '2026-11-12',
    'inputCutoff': '2026-11-12',
    'notice':
        'Joint empirical production research; no validated betting advantage.',
    'rows': [],
    'forecasts': [
      {
        'playerId': 'p',
        'name': 'Recorded Quarterback',
        'group': 'QB_passing_yards',
        'metric': 'passing_yards',
        'prediction': 241.5,
        'incumbent': 250.2,
        'interval': [130.0, 350.0],
        'historicalCoverage': .81,
        'reviewReasons': [],
      },
    ],
  },
  'workloadTrial': {
    'available': true,
    'version': 'workload-ridge-v1',
    'hasEdge': false,
    'adopted': false,
    'status': 'shadow_only',
    'cutoff': '2026-11-12',
    'inputCutoff': '2026-11-12',
    'notice': 'Conditional workload trial; not a betting edge.',
    'forecasts': [
      {
        'playerId': 'p',
        'name': 'Recorded Quarterback',
        'group': 'QB_attempts',
        'metric': 'attempts',
        'prediction': 28.1,
        'incumbent': 30.2,
        'last3': 31.0,
        'last6': 30.5,
        'records': 8,
        'latestDate': '2026-11-12',
        'interval': [20.0, 40.0],
        'reviewReasons': [],
      },
    ],
  },
  'limits': [
    'Experimental model; do not treat this estimate as a proven edge.',
  ],
  'decision': {
    'headline': 'Resolve the lineup questions first',
    'lean': {
      'team': event.home,
      'notice': 'Experimental; not a recommendation.',
    },
    'price': null,
    'priceNotice': 'No saved price for this requested selection.',
    'counterargument':
        'The listed quarterback differs from the last recorded passing leader.',
    'recheck': 'Confirm the starting quarterback and exact price.',
    'hasEdge': false,
    'recommendationsReady': false,
  },
  'context': {
    'schemaVersion': 1,
    'version': 'role-context-v1',
    'adjustmentsApplied': false,
    'cutoff': '2026-11-12',
    'teams': [
      {
        'team': event.home,
        'quarterback': {
          'listed': 'Listed Quarterback',
          'lastObserved': {
            'name': 'Recorded Quarterback',
            'date': '2026-11-12',
          },
          'notice': 'A schedule listing is not a confirmed starter.',
        },
        'restDays': 7,
        'availability': [],
        'offensiveLine': {
          'lastObserved': [],
          'notice': 'Current starters unconfirmed.',
        },
        'usage': [
          {
            'name': 'Recorded Receiver',
            'metric': 'targets',
            'recentMean': 4.0,
            'priorMean': 8.0,
            'recentShare': .2,
            'recentSnapShare': .75,
          },
        ],
      },
    ],
    'sources': [],
    'unknowns': [
      'No automatic injury or quarterback point adjustment is applied.',
    ],
  },
};

void main() {
  final now = DateTime.utc(2026, 11, 16, 12),
      event = SportEvent(
        'e',
        'Buffalo Bills',
        'Kansas City Chiefs',
        DateTime.utc(2026, 11, 16, 20),
      );
  test('production trial cannot claim adoption or display reversed ranges', () {
    final raw = gameOutlookFixture(event, now);
    raw['productionTrial']['adopted'] = true;
    expect(() => GameOutlook.fromJson(raw), throwsFormatException);
    raw['productionTrial']['adopted'] = false;
    raw['productionTrial']['forecasts'][0]['interval'] = [350.0, 130.0];
    expect(() => GameOutlook.fromJson(raw), throwsFormatException);
  });
  test('workload trial rejects adoption and inverted ranges', () {
    final raw = gameOutlookFixture(event, now);
    raw['workloadTrial']['adopted'] = true;
    expect(() => GameOutlook.fromJson(raw), throwsFormatException);
    raw['workloadTrial']['adopted'] = false;
    raw['workloadTrial']['forecasts'][0]['interval'] = [40.0, 20.0];
    expect(() => GameOutlook.fromJson(raw), throwsFormatException);
  });
  test('server game outlook preserves market scope and rejects impossible probabilities', () {
    final raw = gameOutlookFixture(event, now),
        outlook = GameOutlook.fromJson(raw);
    expect(outlook.categories, hasLength(4));
    expect(outlook.event.id, 'e');
    (raw['categories'][0]['rows'][0] as Map)['win'] = .99;
    expect(() => GameOutlook.fromJson(raw), throwsFormatException);
  });
  test(
    'unverified server output cannot silently claim an established edge',
    () {
      final raw = gameOutlookFixture(event, now)..['hasEdge'] = true;
      expect(() => GameOutlook.fromJson(raw), throwsFormatException);
    },
  );
  test(
    'changed reports withdraw the old read while unchanged polling does not',
    () {
      final raw = gameOutlookFixture(event, now);
      final observed = TelemetryObservation(
        id: 'injury',
        kind: 'injury',
        eventId: event.id,
        playerId: 'p',
        source: 'ESPN',
        observedAt: now,
        value: {'status': 'Questionable'},
      );
      raw['availability'] = [
        {
          'id': observed.id,
          'kind': observed.kind,
          'eventId': event.id,
          'playerId': 'p',
          'source': 'ESPN',
          'observedAt': now.toIso8601String(),
          'value': observed.value,
        },
      ];
      final game = GameOutlook.fromJson(raw);
      expect(
        reviewGameContext(
          game,
          CoachTelemetry(checkedAt: now, observations: [observed], sources: []),
          now,
        ),
        isNull,
      );
      final changed = TelemetryObservation(
        id: observed.id,
        kind: 'injury',
        eventId: event.id,
        playerId: 'p',
        source: 'ESPN',
        observedAt: now,
        value: {'status': 'Out'},
      );
      expect(
        reviewGameContext(
          game,
          CoachTelemetry(checkedAt: now, observations: [changed], sources: []),
          now,
        ),
        contains('reports changed'),
      );
      expect(
        reviewGameContext(game, null, now.add(const Duration(minutes: 13))),
        contains('expired'),
      );
      (raw['decision'] as Map)['hasEdge'] = true;
      expect(() => GameOutlook.fromJson(raw), throwsFormatException);
    },
  );
}
