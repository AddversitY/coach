import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:odds_edge/data/demo.dart';
import 'package:odds_edge/data/published_snapshot.dart';
import 'package:odds_edge/domain/odds.dart';

Map<String, dynamic> snapshotJson(DateTime at) {
  final event = SportEvent(
    'nflverse:2026_11_BUF_KC',
    'Buffalo Bills',
    'Kansas City Chiefs',
    at.add(const Duration(days: 1)),
  );
  final board = OddsBoard(events: [event], quotes: const [], fetchedAt: at);
  return {
    'schemaVersion': 1,
    'generatedAt': at.toIso8601String(),
    'schedule': {'source': 'nflverse', 'fetchedAt': at.toIso8601String()},
    'odds': {'status': 'not_configured'},
    'board': board.toJson(),
    'props': board.toJson(),
  };
}

Map<String, dynamic> priceSnapshotJson(DateTime at) {
  final raw = snapshotJson(at);
  raw['schemaVersion'] = 2;
  raw['odds'] = {
    'status': 'limited',
    'provider': 'the-odds-api',
    'fetchedAt': at.toIso8601String(),
    'coverage': {
      'eventId': 'nflverse:2026_11_BUF_KC',
      'markets': publishedPropMarkets.toList(),
      'outsideCoverage': 'unavailable',
      'players': [
        {
          'playerId': '00-0033873',
          'name': 'Josh Allen',
          'team': 'Buffalo Bills',
          'asOf': '2026-11-08',
        },
      ],
    },
  };
  raw['props']['quotes'] = [
    OddsQuote(
      selection: const Selection(
        eventId: 'nflverse:2026_11_BUF_KC',
        market: 'player_pass_yds',
        outcome: 'Over',
        participant: 'Josh Allen',
        point: 234.5,
        rules: 'player_prop_unverified',
      ),
      bookId: 'draftkings',
      book: 'DraftKings',
      provider: 'the-odds-api',
      decimal: 1.91,
      sourceAt: at.subtract(const Duration(minutes: 1)),
      collectedAt: at,
    ).toJson(),
  ];
  return raw;
}

void main() {
  test('configured price waiting state preserves schedule and ignores provider text', () {
    final at = DateTime.utc(2026, 11, 17, 18);
    final raw = snapshotJson(at);
    raw['odds'] = {
      'status': 'unavailable',
      'provider': 'the-odds-api',
      'availability': {
        'reason': 'waiting_window',
        'checkedAt': at.toIso8601String(),
        'eligibleAt': at.add(const Duration(days: 2)).toIso8601String(),
        'message': 'UNTRUSTED ERROR',
      },
    };
    final result = PublishedSnapshot.parse(raw, at);
    expect(result.board.events, hasLength(1));
    expect(result.hasPrices, false);
    expect(result.oddsMessage, contains('pregame update window'));
    expect(result.oddsMessage, contains('not a promised refresh'));
    expect(result.oddsMessage, isNot(contains('UNTRUSTED')));
    expect(
      PublishedSnapshot.parse(
        raw,
        at.add(const Duration(hours: 25)),
      ).oddsMessage,
      contains('out of date'),
    );
    raw['odds']['availability']['reason'] = 'unexpected';
    expect(() => PublishedSnapshot.parse(raw, at), throwsFormatException);
  });

  test(
    'slate prices validate each game and expire started games independently',
    () {
      final at = DateTime.utc(2026, 11, 14, 15);
      final raw = priceSnapshotJson(at);
      final first = raw['board']['events'][0];
      first['startsAt'] = at.add(const Duration(hours: 1)).toIso8601String();
      final extra = Map<String, dynamic>.from(first)
        ..addAll({
          'id': 'nflverse:2026_11_PHI_DAL',
          'away': 'Philadelphia Eagles',
          'home': 'Dallas Cowboys',
          'startsAt': at.add(const Duration(hours: 3)).toIso8601String(),
        });
      raw['board']['events'].add(extra);
      raw['props']['events'] = jsonDecode(jsonEncode(raw['board']['events']));
      raw['odds']['coverage']['eventIds'] = [first['id'], extra['id']];
      raw['odds']['coverage']['markets'] = [
        'h2h',
        'spreads',
        'totals',
        'player_pass_yds',
      ];
      final quote = jsonDecode(
        jsonEncode(raw['props']['quotes'][0]),
      ) as Map<String, dynamic>;
      quote['selection'] = {
        'eventId': extra['id'],
        'market': 'h2h',
        'outcome': 'Dallas Cowboys',
        'participant': '',
        'point': null,
        'period': 'full_game',
        'rules': 'game_market_unverified',
      };
      raw['props']['quotes'].add(quote);
      final result = PublishedSnapshot.parse(
        raw,
        at.add(const Duration(hours: 2)),
      );
      expect(result.props.quotes.length, 1);
      expect(result.props.quotes.single.selection.eventId, extra['id']);
      final invalid = jsonDecode(jsonEncode(raw));
      invalid['props']['quotes'].last['selection']['outcome'] = 'Buffalo Bills';
      expect(() => PublishedSnapshot.parse(invalid, at), throwsFormatException);
      final wrongProp = jsonDecode(jsonEncode(raw));
      wrongProp['props']['quotes'][0]['selection']['eventId'] = extra['id'];
      expect(
        () => PublishedSnapshot.parse(wrongProp, at),
        throwsFormatException,
      );
    },
  );

  final now = DateTime.utc(2026, 11, 14);
  test('balanced published coverage accepts exact game markets without inventing player identities', () {
    final raw = priceSnapshotJson(now);
    raw['odds']['coverage']['markets'] = [
      'h2h',
      'spreads',
      'totals',
      'player_pass_yds',
    ];
    raw['odds']['coverage']['players'] = [];
    raw['props']['quotes'] = [
      OddsQuote(
        selection: const Selection(
          eventId: 'nflverse:2026_11_BUF_KC',
          market: 'spreads',
          outcome: 'Buffalo Bills',
          point: 3.5,
          rules: 'game_market_unverified',
        ),
        bookId: 'draftkings',
        book: 'DraftKings',
        provider: 'the-odds-api',
        decimal: 1.91,
        sourceAt: now,
        collectedAt: now,
      ).toJson(),
    ];
    final value = PublishedSnapshot.parse(raw, now);
    expect(value.props.quotes.single.selection.market, 'spreads');
    expect(value.playerIdsByName, isEmpty);
    raw['props']['quotes'][0]['selection']['outcome'] = 'Dallas Cowboys';
    expect(() => PublishedSnapshot.parse(raw, now), throwsFormatException);
  });
  test('published games preserve source dates and become stale', () {
    final value = PublishedSnapshot.parse(snapshotJson(now), now);
    expect(value.board.demo, isFalse);
    expect(value.board.quotes, isEmpty);
    expect(value.stale(now), isFalse);
    expect(value.stale(now.add(const Duration(hours: 25))), isTrue);
    expect(value.scheduleAt, now);
  });
  test('examples, prices, unknown schema and mismatched games cannot enter a schedule snapshot', () {
    for (final change in <void Function(Map<String, dynamic>)>[
      (r) => r['schemaVersion'] = 3,
      (r) => r['board']['demo'] = true,
      (r) => r['board']['quotes'] = [demoBoard(now).quotes.first.toJson()],
      (r) => r['props']['events'] = [],
      (r) => r['board']['events'][0]['home'] = 'Unknown team',
      (r) => r['board']['events'].add(r['board']['events'][0]),
      (r) => r['schedule']['source'] = 'unknown',
      (r) =>
          r['generatedAt'] = now.add(const Duration(days: 1)).toIso8601String(),
    ]) {
      final raw = snapshotJson(now);
      change(raw);
      expect(() => PublishedSnapshot.parse(raw, now), throwsFormatException);
    }
  });
  test(
    'limited real prices preserve exact player event line book and source time',
    () {
      final value = PublishedSnapshot.parse(priceSnapshotJson(now), now);
      expect(value.board.quotes, isEmpty);
      expect(value.hasPrices, isTrue);
      expect(value.coveredEventId, 'nflverse:2026_11_BUF_KC');
      expect(value.playerIdsByName, {'Josh Allen': '00-0033873'});
      expect(value.quoteAt, now);
      final quote = value.props.quotes.single;
      expect(quote.selection.participant, 'Josh Allen');
      expect(quote.selection.point, 234.5);
      expect(quote.bookId, 'draftkings');
      expect(quote.sourceAt, now.subtract(const Duration(minutes: 1)));
      expect(quote.freshness(now.add(const Duration(minutes: 3))), 'stale');
    },
  );
  test('expired price snapshots keep schedule and stop exposing prices', () {
    final value = PublishedSnapshot.parse(
      priceSnapshotJson(now),
      now.add(const Duration(hours: 19)),
    );
    expect(value.board.events, hasLength(1));
    expect(value.hasPrices, isFalse);
    expect(value.oddsMessage, contains('outdated'));
    final afterKickoff = PublishedSnapshot.parse(
      priceSnapshotJson(now),
      now.add(const Duration(days: 1)),
    );
    expect(afterKickoff.props.quotes, isEmpty);
  });
  test('price pilot rejects private fields examples identity ambiguity stale and mismatched quotes', () {
    for (final change in <void Function(Map<String, dynamic>)>[
      (r) => r['odds']['testFixture'] = true,
      (r) => r['odds']['apiKey'] = 'secret',
      (r) => r['props']['quotes'][0]['rawResponse'] = {},
      (r) => r['props']['quotes'][0]['demo'] = true,
      (r) => r['props']['quotes'][0]['provider'] = 'unknown',
      (r) => r['props']['quotes'][0]['book'] = 'Other title',
      (r) => r['props']['quotes'][0]['selection']['eventId'] = 'nflverse:other',
      (r) =>
          r['props']['quotes'][0]['selection']['market'] = 'player_anytime_td',
      (r) => r['props']['quotes'][0]['selection']['participant'] = 'J. Allen',
      (r) => r['props']['quotes'][0]['selection']['point'] = 234.25,
      (r) => r['props']['quotes'][0]['selection']['rules'] = 'verified',
      (r) => r['props']['quotes'][0]['sourceAt'] = now
          .subtract(const Duration(hours: 19))
          .toIso8601String(),
      (r) => r['props']['quotes'][0]['sourceAt'] = now
          .add(const Duration(minutes: 1))
          .toIso8601String(),
      (r) => r['props']['quotes'][0]['collectedAt'] = now
          .subtract(const Duration(minutes: 1))
          .toIso8601String(),
      (r) => r['props']['quotes'].add(r['props']['quotes'][0]),
      (r) => r['odds']['coverage']['eventId'] = 'nflverse:other',
      (r) => r['odds']['coverage']['outsideCoverage'] = 'covered',
      (r) => r['odds']['coverage']['markets'].removeLast(),
      (r) => r['odds']['coverage']['players'][0]['playerId'] = 'unknown',
      (r) => r['odds']['coverage']['players'][0]['team'] = 'New York Jets',
      (r) => r['odds']['coverage']['players'][0]['asOf'] = '2026-11-14',
      (r) => r['odds']['coverage']['players'].add(
        r['odds']['coverage']['players'][0],
      ),
    ]) {
      final raw = priceSnapshotJson(now);
      change(raw);
      expect(() => PublishedSnapshot.parse(raw, now), throwsFormatException);
    }
  });
  test('published HTTP fetch is read-only, cache-busted, and carries no credentials', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.method, 'GET');
      expect(request.url.path, '/odds-edge/data/snapshot.json');
      expect(request.url.queryParameters.keys, ['v']);
      expect(request.headers.containsKey('authorization'), isFalse);
      return http.Response(jsonEncode(snapshotJson(now)), 200);
    });
    await loadPublishedSnapshot(
      Uri.parse('https://example.com/odds-edge/data/snapshot.json'),
      client: client,
      now: now,
    );
    expect(requests, 1);
    for (final url in [
      'http://example.com/data.json',
      'https://secret@example.com/data.json',
    ]) {
      await expectLater(
        loadPublishedSnapshot(Uri.parse(url), client: client, now: now),
        throwsArgumentError,
      );
    }
    expect(requests, 1);
    client.close();
  });
  test(
    'redirects, server errors and oversized responses remain unavailable',
    () async {
      for (final status in [302, 500]) {
        final client = MockClient((_) async => http.Response('{}', status));
        await expectLater(
          loadPublishedSnapshot(
            Uri.parse('https://example.com/data.json'),
            client: client,
            now: now,
          ),
          throwsStateError,
        );
        client.close();
      }
      final large = MockClient((_) async => http.Response(' ' * 1000001, 200));
      await expectLater(
        loadPublishedSnapshot(
          Uri.parse('https://example.com/data.json'),
          client: large,
          now: now,
        ),
        throwsFormatException,
      );
      large.close();
    },
  );
}
