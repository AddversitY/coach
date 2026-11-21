import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:odds_edge/data/repository.dart';
import 'package:odds_edge/domain/coach_briefing.dart';
import 'package:odds_edge/domain/price_history.dart';

void main() {
  test('the median stays the test line until 1,000 real closes', () {
    expect(
      walkForwardTestLine(median: 64.5, close: 71.5, closesForMarket: 999),
      64.5,
    );
    expect(
      walkForwardTestLine(median: 64.5, close: null, closesForMarket: 1000),
      64.5,
    );
    expect(
      walkForwardTestLine(median: 64.5, close: 71.5, closesForMarket: 1000),
      71.5,
    );
  });

  test('a close is the last price before kickoff', () {
    final history = PriceHistory.fromJson({
      'observations': [
        _row('2026-11-22T12:00:00Z', 1.91, -3.5),
        _row('2026-11-22T17:50:00Z', 1.83, -2.5),
        _row('2026-11-22T18:10:00Z', 1.50, -1.0),
      ],
      'closes': [
        _row('2026-11-22T17:50:00Z', 1.83, -2.5),
      ],
    });
    expect(history.closes.single.line, -2.5);
    expect(history.closes.single.beforeKickoff, isTrue);
    expect(history.observations.last.beforeKickoff, isFalse);
    expect(
      history.closeLine(
        market: 'player_reception_yds',
        season: 2026,
        week: 11,
        team: 'HOU',
        player: 'Nico Collins',
      ),
      isNull,
    );
  });

  test('the report says unavailable until a card is graded', () {
    final empty = SelfGradeReport.fromJson({
      'propCloses': 0,
      'realCloseGate': 1000,
      'sources': [
        {'source': 'draftkings-public', 'status': 'unavailable', 'detail': 'HTTP 403'},
      ],
      'markets': {
        'player_reception_yds': {
          'market': 'player_reception_yds',
          'label': 'receiving yards props',
          'savedPrices': 0,
          'cards': 0,
          'graded': 0,
          'hits': 0,
          'pushes': 0,
          'clvCount': 0,
        },
      },
      'notice': 'not a pick',
    });
    final text = selfGradeSentence(empty, 'player_reception_yds');
    expect(text, contains('unavailable'));
    expect(text, contains('not a pick'));
    expect(text, contains('not a betting edge'));
    expect(text, contains('draftkings-public'));

    final graded = SelfGradeReport.fromJson({
      'markets': {
        'player_reception_yds': {
          'market': 'player_reception_yds',
          'label': 'receiving yards props',
          'savedPrices': 4,
          'cards': 2,
          'graded': 2,
          'hits': 1,
          'pushes': 0,
          'chanceSum': 1.08,
          'clvSum': 0.03,
          'clvCount': 2,
        },
      },
    });
    final report = selfGradeSentence(graded, 'player_reception_yds');
    expect(report, contains('graded 2 receiving yards props'));
    expect(report, contains('54.0 percent'));
    expect(report, contains('1 of 2'));
    expect(report, contains('1.5 cents better'));
    expect(report, contains('not a pick'));
  });

  test('a receiving-yards question reads the report instead of the prop board', () {
    final brief = interpretQuestion(
      question: 'How good is Coach at receiving yards props?',
      evidence: null,
      players: null,
      ratings: null,
      grades: SelfGradeReport.empty,
    );
    expect(brief, isNotNull);
    expect(brief!.title, 'Report card');
    expect(brief.text, contains('receiving yards props'));
    expect(brief.text, contains('unavailable'));
    expect(gradeMarketForQuestion('rushing yards report card'), 'player_rush_yds');
    expect(asksForGrade('why did the Texans beat the Colts'), isFalse);
  });

  test('a book prop price is shown only when it was saved', () {
    final coverage = BookPriceCoverage.fromJson({
      'consensusAdopted': false,
      'consensusReason': 'Two-sided closes are unavailable for 2025.',
      'notice': 'This is a comparison, not a pick.',
      'books': [
        {'book': 'bovada', 'status': 'ok', 'prices': 4, 'closes': 0},
        {'book': 'draftkings', 'status': 'unavailable', 'prices': 0, 'closes': 0},
      ],
      'observations': [
        {
          'book': 'bovada',
          'market': 'player_pass_yds',
          'outcome': 'Over',
          'player': 'C.J. Stroud',
          'playerId': '00-0039163',
          'line': 242.5,
          'decimal': 1.91,
        },
      ],
    });
    expect(coverage.consensusAdopted, isFalse);
    final text = bookPriceSentence(
      coverage,
      question: 'FanDuel price for C.J. Stroud passing yards',
      player: 'C.J. Stroud',
    );
    expect(text, contains('bovada'));
    expect(text, contains('242.5'));
    expect(text, contains('1.91'));
    expect(text, contains('not on the card'));
    expect(text, contains('comparison, not a pick'));
    final hidden = bookPriceSentence(
      BookPriceCoverage.fromJson({
        'consensusAdopted': false,
        'consensusReason': 'Two-sided closes are unavailable for 2025.',
        'books': [
          {'book': 'fanduel', 'status': 'ok', 'prices': 12, 'closes': 0},
        ],
        'notice': 'This is a comparison, not a pick.',
      }),
      question: 'FanDuel passing yards price',
    );
    expect(hidden, contains('unavailable'));
    expect(hidden, contains('fanduel 12 prices'));
    expect(asksForBookPrices('FanDuel passing yards price'), isTrue);
    expect(asksForBookPrices('How good is Coach at receiving yards props?'), isFalse);
    final brief = interpretQuestion(
      question: 'What is the FanDuel passing yards price?',
      evidence: null,
      players: null,
      ratings: null,
      bookPrices: coverage,
    );
    expect(brief!.title, 'Book prices');
    expect(brief.props, isNotNull);
    expect(brief.props!.rows, isNotEmpty);
    expect(brief.props!.rows.first.book, 'Bovada');
    expect(brief.props!.rows.first.price, '-110');
    expect(brief.props!.summary, contains('comparison, not a pick'));

    final bundled = BookPriceCoverage.fromJson({
      'books': [
        {'book': 'fanduel', 'status': 'ok', 'prices': 12, 'closes': 4},
      ],
      'consensusAdopted': false,
      'consensusReason': 'Two-sided closes are unavailable for 2025.',
      'notice': 'This is a comparison, not a pick.',
    });
    expect(mergeLiveBookPrices(bundled, null).prices, isEmpty);
    expect(
      mergeLiveBookPrices(bundled, {'available': false, 'prices': 'unavailable'}).prices,
      isEmpty,
    );
    final merged = mergeLiveBookPrices(bundled, {
      'observations': [
        {
          'book': 'fanduel',
          'market': 'player_pass_yds',
          'outcome': 'Over',
          'player': 'C.J. Stroud',
          'eventId': 'nflverse:2026_12_IND_HOU',
          'at': '2026-11-21T22:00:00Z',
          'line': 242.5,
          'decimal': 1.91,
        },
      ],
    });
    expect(merged.prices.single.book, 'fanduel');
    expect(merged.prices.single.decimal, 1.91);
    expect(merged.books.single.prices, 12);
    expect(merged.consensusAdopted, isFalse);
    final missed = propBoardForBookPrices(
      bundled,
      question: 'FanDuel passing yards price',
    );
    expect(missed.rows, isEmpty);
    expect(missed.summary, contains('unavailable'));
  });

  test('a failed book-price read stays unavailable', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/book-prices');
      return http.Response('nope', 503);
    });
    final repo = BackendRepository('https://coach.example', client: client);
    expect(await repo.loggedOutBookPrices(), isNull);
    repo.close();

    final ok = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'observations': [
            {
              'book': 'betrivers',
              'market': 'player_rush_yds',
              'outcome': 'Over',
              'player': 'Jonathan Taylor',
              'line': 75.5,
              'decimal': 1.87,
            },
          ],
        }),
        200,
      ),
    );
    final live = BackendRepository('https://coach.example', client: ok);
    final body = await live.loggedOutBookPrices();
    expect(body, isNotNull);
    expect((body!['observations'] as List).single['player'], 'Jonathan Taylor');
    live.close();
  });
}

Map<String, Object?> _row(String at, double decimal, double line) => {
  'at': at,
  'source': 'the-odds-api',
  'book': 'draftkings',
  'eventId': 'nflverse:2026_11_IND_HOU',
  'kickoff': '2026-11-22T18:00:00Z',
  'season': 2026,
  'week': 11,
  'away': 'IND',
  'home': 'HOU',
  'market': 'spreads',
  'outcome': 'Houston Texans',
  'player': '',
  'line': line,
  'decimal': decimal,
};
