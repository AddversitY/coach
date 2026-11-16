import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/game_outlook.dart';
import 'package:odds_edge/domain/odds.dart';

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
  'limits': [
    'Experimental model; do not treat this estimate as a proven edge.',
  ],
};

void main() {
  final now = DateTime.utc(2026, 11, 16, 12),
      event = SportEvent(
        'e',
        'Buffalo Bills',
        'Kansas City Chiefs',
        DateTime.utc(2026, 11, 16, 20),
      );
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
}
