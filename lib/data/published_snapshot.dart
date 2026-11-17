import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/odds.dart';
import '../domain/nfl_teams.dart';
import '../domain/eastern.dart';

const publishedPropMarkets = <String>{
  'player_pass_yds',
  'player_receptions',
  'player_rush_yds',
  'player_reception_yds',
};
const publishedGameMarkets = <String>{'h2h', 'spreads', 'totals'};
const publishedMarkets = <String>{
  ...publishedPropMarkets,
  ...publishedGameMarkets,
};
const _publishedBooks = <String, String>{
  'draftkings': 'DraftKings',
  'fanduel': 'FanDuel',
  'betmgm': 'BetMGM',
  'williamhill_us': 'Caesars',
  'espnbet': 'ESPN BET',
  'fanatics': 'Fanatics',
  'betrivers': 'BetRivers',
  'hardrockbet': 'Hard Rock Bet',
  'ballybet': 'Bally Bet',
  'fliff': 'Fliff',
};

DateTime _publishedTime(Object? value) {
  if (value is! String || !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value)) {
    throw const FormatException('Public timestamps must include a timezone.');
  }
  return DateTime.parse(value).toUtc();
}

const _priceAvailabilityMessages = <String, String>{
  'disabled': 'Scheduled sportsbook price updates are disabled.',
  'missing_key': 'The price connection needs its server credential restored.',
  'identity_unavailable':
      'Prices are withheld until player identities can be verified.',
  'publication_running': 'A scheduled price update is already running.',
  'ledger_unavailable': 'Price updates are paused while the private usage checkpoint is recovered.',
  'daily_limit': 'The free daily price-update allowance has been used.',
  'monthly_limit': 'The free monthly price-update allowance has been used.',
  'no_upcoming_game':
      'There are no upcoming NFL games in the current schedule.',
  'waiting_window':
      'Prices are waiting for the scheduled pregame update window.',
  'usage_review': 'Price updates are paused for a provider-usage check.',
  'protected_reserve':
      'Price updates are paused to preserve the free provider allowance.',
  'event_unmatched': 'The provider has no verified match for an upcoming game.',
  'no_valid_quotes': 'The provider returned no usable exact-selection prices.',
  'source_unavailable': 'The scheduled price update could not be completed. Saved prices have not been refreshed.',
};

String _priceAvailabilityMessage(Map<String, dynamic> odds, DateTime now) {
  if (odds['status'] == 'not_configured') {
    return 'Sportsbook prices are not connected.';
  }
  final availability = odds['availability'];
  if (odds['status'] != 'unavailable' ||
      odds['provider'] != 'the-odds-api' ||
      availability is! Map<String, dynamic> ||
      !_priceAvailabilityMessages.containsKey(availability['reason'])) {
    throw const FormatException('Invalid public price availability.');
  }
  final checked = _publishedTime(availability['checkedAt']);
  if (checked.isAfter(now.add(const Duration(seconds: 5)))) {
    throw const FormatException('Future price availability check.');
  }
  if (now.difference(checked) > const Duration(hours: 24)) {
    return 'The price-update status is out of date. Refresh the schedule before relying on it.';
  }
  var message = _priceAvailabilityMessages[availability['reason']]!;
  if (availability['eligibleAt'] != null) {
    final eligible = _publishedTime(availability['eligibleAt']);
    if (!const [
          'waiting_window',
          'daily_limit',
          'monthly_limit',
        ].contains(availability['reason']) ||
        !eligible.isAfter(checked) ||
        eligible.difference(checked) > const Duration(days: 32)) {
      throw const FormatException('Invalid price eligibility time.');
    }
    message += eligible.isAfter(now)
        ? ' Next eligible window: ${formatEastern(eligible)}. This is eligibility, not a promised refresh time.'
        : ' The eligibility time has passed; a successful scheduled update is still needed.';
  }
  return message;
}

/// Public, read-only app snapshot. Never an authenticated backend or raw feed.
class PublishedSnapshot {
  const PublishedSnapshot({
    required this.board,
    required this.props,
    required this.generatedAt,
    required this.scheduleAt,
    required this.oddsMessage,
    this.quoteAt,
    this.coveredEventId,
    this.playerIdsByName = const {},
  });
  final OddsBoard board, props;
  final DateTime generatedAt, scheduleAt;
  final String oddsMessage;
  final DateTime? quoteAt;
  final String? coveredEventId;

  /// Exact provider name -> stable nflverse player identity. No fuzzy matching.
  final Map<String, String> playerIdsByName;
  bool get hasPrices => props.quotes.isNotEmpty;
  bool stale(DateTime now) =>
      scheduleAt.isAfter(now.add(const Duration(minutes: 5))) ||
      now.difference(scheduleAt) > const Duration(hours: 24);
  factory PublishedSnapshot.parse(Object? raw, DateTime now) {
    try {
      return _parse(raw, now.toUtc());
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid public snapshot.');
    }
  }

  static PublishedSnapshot _parse(Object? raw, DateTime now) {
    if (raw is! Map<String, dynamic> ||
        !const [1, 2].contains(raw['schemaVersion'])) {
      throw const FormatException('Unsupported public snapshot.');
    }
    final generated = _publishedTime(raw['generatedAt']);
    final schedule = raw['schedule'] as Map<String, dynamic>;
    final scheduleAt = _publishedTime(schedule['fetchedAt']);
    if (generated.isAfter(now.add(const Duration(minutes: 5))) ||
        scheduleAt.isAfter(generated) ||
        schedule['source'] != 'nflverse') {
      throw const FormatException('Invalid schedule provenance.');
    }
    final board = OddsBoard.fromJson(raw['board'] as Map<String, dynamic>);
    final props = OddsBoard.fromJson(raw['props'] as Map<String, dynamic>);
    final odds = raw['odds'] as Map<String, dynamic>;
    if (board.demo ||
        props.demo ||
        board.quotes.isNotEmpty ||
        board.fetchedAt != scheduleAt) {
      throw const FormatException(
        'This schedule snapshot cannot contain sportsbook prices.',
      );
    }
    final ids = <String>{};
    for (final event in board.events) {
      if (!RegExp(r'^nflverse:[A-Za-z0-9_]+$').hasMatch(event.id) ||
          !ids.add(event.id) ||
          event.home == event.away ||
          !nflTeams.containsKey(event.home) ||
          !nflTeams.containsKey(event.away) ||
          event.league != 'NFL' ||
          event.sport != 'american_football') {
        throw const FormatException('Invalid schedule identity.');
      }
    }
    if (jsonEncode(props.events.map((e) => e.toJson()).toList()) !=
        jsonEncode(board.events.map((e) => e.toJson()).toList())) {
      throw const FormatException(
        'Snapshot boards disagree about the schedule.',
      );
    }
    if (raw['schemaVersion'] == 2) {
      return _parsePrices(raw, board, props, generated, scheduleAt, now);
    }
    if (props.quotes.isNotEmpty ||
        !const ['not_configured', 'unavailable'].contains(odds['status']) ||
        props.fetchedAt != scheduleAt) {
      throw const FormatException('Version one cannot contain prices.');
    }
    final availabilityMessage = _priceAvailabilityMessage(odds, now);
    return PublishedSnapshot(
      board: board,
      props: props,
      generatedAt: generated,
      scheduleAt: scheduleAt,
      oddsMessage: availabilityMessage,
    );
  }

  static PublishedSnapshot _parsePrices(
    Map<String, dynamic> raw,
    OddsBoard board,
    OddsBoard props,
    DateTime generated,
    DateTime scheduleAt,
    DateTime now,
  ) {
    void keys(Map value, Set<String> allowed) {
      if (value.keys.any((key) => !allowed.contains(key))) {
        throw const FormatException('Unexpected public price fields.');
      }
    }

    keys(raw, {
      'schemaVersion',
      'generatedAt',
      'schedule',
      'odds',
      'board',
      'props',
    });
    final schedule = raw['schedule'] as Map<String, dynamic>;
    keys(schedule, {
      'source',
      'sourceUrl',
      'license',
      'licenseUrl',
      'fetchedAt',
      'windowDays',
    });
    if ((schedule.containsKey('sourceUrl') &&
            schedule['sourceUrl'] !=
                'https://github.com/nflverse/nflverse-data/releases/download/schedules/games.csv') ||
        (schedule.containsKey('licenseUrl') &&
            schedule['licenseUrl'] !=
                'https://creativecommons.org/licenses/by/4.0/')) {
      throw const FormatException('Unexpected public source URL.');
    }
    for (final name in ['board', 'props']) {
      final value = raw[name] as Map<String, dynamic>;
      keys(value, {'events', 'quotes', 'fetchedAt', 'demo', 'notices'});
      _publishedTime(value['fetchedAt']);
      for (final event in value['events'] as List) {
        keys(event as Map, {
          'id',
          'away',
          'home',
          'startsAt',
          'sport',
          'league',
        });
        _publishedTime(event['startsAt']);
      }
    }
    final odds = raw['odds'] as Map<String, dynamic>;
    keys(odds, {'status', 'provider', 'fetchedAt', 'coverage'});
    if (odds['status'] != 'limited' || odds['provider'] != 'the-odds-api') {
      throw const FormatException('Unverified public price source.');
    }
    final fetched = _publishedTime(odds['fetchedAt']);
    const ttl = Duration(hours: 18);
    if (fetched.isAfter(generated) ||
        fetched.isAfter(now.add(const Duration(seconds: 5))) ||
        generated.difference(fetched) > ttl ||
        props.fetchedAt != fetched ||
        props.quotes.isEmpty ||
        props.quotes.length > 2000) {
      throw const FormatException('Invalid price observation time.');
    }
    final coverage = odds['coverage'] as Map<String, dynamic>;
    keys(coverage, {
      'eventId',
      'eventIds',
      'markets',
      'players',
      'outsideCoverage',
    });
    final eventId = coverage['eventId'] as String;
    final events = board.events.where((event) => event.id == eventId).toList();
    final markets = List<String>.from(coverage['markets'] as List);
    if (events.length != 1 ||
        coverage['outsideCoverage'] != 'unavailable' ||
        markets.length != publishedPropMarkets.length ||
        markets.toSet().length != markets.length ||
        !publishedMarkets.containsAll(markets)) {
      throw const FormatException('Invalid limited price coverage.');
    }
    final coveredIds = coverage['eventIds'] == null
        ? [eventId]
        : List<String>.from(coverage['eventIds'] as List);
    if (coveredIds.isEmpty ||
        coveredIds.length > 32 ||
        coveredIds.toSet().length != coveredIds.length ||
        !coveredIds.contains(eventId) ||
        coveredIds.any(
          (id) => !board.events.any(
            (e) => e.id == id && e.startsAt.isAfter(fetched),
          ),
        )) {
      throw const FormatException('Invalid slate event coverage.');
    }
    final event = events.single;
    if (!event.startsAt.isAfter(fetched)) {
      throw const FormatException(
        'Only pregame price observations are supported.',
      );
    }
    final playerIds = <String, String>{};
    final seenIds = <String>{};
    for (final player in coverage['players'] as List) {
      final p = player as Map<String, dynamic>;
      keys(p, {'playerId', 'name', 'team', 'asOf'});
      final id = p['playerId'] as String;
      final name = p['name'] as String;
      final asOf = p['asOf'] as String;
      final researchDay = easternWall(fetched)
          .toIso8601String()
          .substring(0, 10);
      final gameDay = easternWall(event.startsAt)
          .toIso8601String()
          .substring(0, 10);
      if (!RegExp(r'^00-\d{7}$').hasMatch(id) ||
          name.isEmpty ||
          name != name.trim() ||
          name.length > 100 ||
          RegExp(r'[<>@?\r\n]').hasMatch(name) ||
          playerIds.containsKey(name) ||
          !seenIds.add(id) ||
          ![event.away, event.home].contains(p['team']) ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(asOf) ||
          DateTime.tryParse(asOf)?.toIso8601String().substring(0, 10) != asOf ||
          asOf.compareTo(researchDay) >= 0 ||
          asOf.compareTo(gameDay) >= 0) {
        throw const FormatException('Ambiguous public player identity.');
      }
      playerIds[name] = id;
    }
    final seen = <String>{};
    final quotedNames = <String>{};
    final rawQuotes = (raw['props'] as Map<String, dynamic>)['quotes'] as List;
    for (var index = 0; index < props.quotes.length; index++) {
      final quote = props.quotes[index];
      final q = rawQuotes[index] as Map<String, dynamic>;
      keys(q, {
        'selection',
        'bookId',
        'book',
        'provider',
        'decimal',
        'sourceAt',
        'collectedAt',
        'status',
        'demo',
      });
      keys(q['selection'] as Map, {
        'eventId',
        'market',
        'outcome',
        'participant',
        'point',
        'period',
        'rules',
      });
      _publishedTime(q['sourceAt']);
      _publishedTime(q['collectedAt']);
      final selection = quote.selection;
      final point = selection.point;
      final quoteEvents = board.events
          .where((e) => e.id == selection.eventId && coveredIds.contains(e.id))
          .toList();
      if (quoteEvents.length != 1) {
        throw const FormatException('Quote outside declared slate.');
      }
      final quoteEvent = quoteEvents.single;
      final gameMarket = publishedGameMarkets.contains(selection.market);
      final validPoint =
          point != null &&
          point.isFinite &&
          point.abs() <= 1000 &&
          point * 2 == (point * 2).truncateToDouble();
      final validIdentity = gameMarket
          ? selection.participant.isEmpty &&
                selection.rules == 'game_market_unverified' &&
                (selection.market == 'h2h'
                    ? point == null &&
                          [
                            quoteEvent.home,
                            quoteEvent.away,
                            'Draw',
                          ].contains(selection.outcome)
                    : validPoint &&
                          (selection.market == 'spreads'
                              ? [
                                  quoteEvent.home,
                                  quoteEvent.away,
                                ].contains(selection.outcome)
                              : point >= 0 &&
                                    [
                                      'Over',
                                      'Under',
                                    ].contains(selection.outcome)))
          : selection.eventId == eventId &&
                publishedPropMarkets.contains(selection.market) &&
                ['Over', 'Under'].contains(selection.outcome) &&
                playerIds.containsKey(selection.participant) &&
                validPoint &&
                point >= 0 &&
                selection.rules == 'player_prop_unverified';
      if (quote.demo ||
          quote.status != 'open' ||
          quote.provider != 'the-odds-api' ||
          _publishedBooks[quote.bookId] != quote.book ||
          quote.decimal > 1001 ||
          quote.collectedAt != fetched ||
          quote.sourceAt.isAfter(fetched.add(const Duration(seconds: 5))) ||
          quote.sourceAt.isAfter(now.add(const Duration(seconds: 5))) ||
          fetched.difference(quote.sourceAt) > ttl ||
          generated.difference(quote.sourceAt) > ttl ||
          !coveredIds.contains(selection.eventId) ||
          !markets.contains(selection.market) ||
          !validIdentity ||
          selection.period != 'full_game' ||
          !seen.add(jsonEncode([quote.bookId, selection.key]))) {
        throw const FormatException('Invalid exact public quote identity.');
      }
      if (selection.participant.isNotEmpty) {
        quotedNames.add(selection.participant);
      }
    }
    if (quotedNames.length != playerIds.length) {
      throw const FormatException('Unmatched public player coverage.');
    }
    final currentQuotes = props.quotes
        .where(
          (quote) =>
              now.difference(fetched) <= ttl &&
              now.difference(quote.sourceAt) <= ttl &&
              board.events.any(
                (e) =>
                    e.id == quote.selection.eventId && e.startsAt.isAfter(now),
              ),
        )
        .toList();
    final expired = currentQuotes.isEmpty;
    return PublishedSnapshot(
      board: board,
      props: OddsBoard(
        events: props.events,
        quotes: currentQuotes,
        fetchedAt: fetched,
      ),
      generatedAt: generated,
      scheduleAt: scheduleAt,
      oddsMessage: expired
          ? 'Saved sportsbook prices are outdated. Prices unavailable.'
          : 'Saved NFL prices across ${coveredIds.length} games. Only listed markets are covered; prices may have changed.',
      quoteAt: fetched,
      coveredEventId: eventId,
      playerIdsByName: Map.unmodifiable(playerIds),
    );
  }
}

Future<PublishedSnapshot> loadPublishedSnapshot(
  Uri url, {
  http.Client? client,
  DateTime? now,
}) async {
  final local =
      url.scheme == 'http' && ['localhost', '127.0.0.1'].contains(url.host);
  if (!(url.scheme == 'https' || local) || url.userInfo.isNotEmpty) {
    throw ArgumentError('Use an HTTPS public snapshot.');
  }
  final connection = client ?? http.Client();
  final at = now ?? DateTime.now().toUtc();
  try {
    final request = http.Request(
      'GET',
      url.replace(
        queryParameters: {
          ...url.queryParameters,
          'v': '${at.millisecondsSinceEpoch ~/ 300000}',
        },
      ),
    )..followRedirects = false;
    final response = await connection
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Schedule snapshot unavailable.');
    }
    final bytes = <int>[];
    await for (final part in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      bytes.addAll(part);
      if (bytes.length > 1000000) {
        throw const FormatException('Unexpected snapshot size.');
      }
    }
    return PublishedSnapshot.parse(jsonDecode(utf8.decode(bytes)), at);
  } finally {
    if (client == null) connection.close();
  }
}
