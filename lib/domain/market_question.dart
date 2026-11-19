import 'market_math.dart';
import 'nfl_teams.dart';
import 'odds.dart';

/// What a price-shopping question asks for.
enum MarketAsk { bestPrice, value, arbitrage, middles, lowHold }

class MarketQuery {
  const MarketQuery({
    required this.ask,
    this.teams = const {},
    this.market,
    this.participant,
  });
  final MarketAsk ask;

  /// Full club names mentioned in the question.
  final Set<String> teams;

  /// `spreads`, `totals`, `h2h`, `props`, or null for every market.
  final String? market;

  /// A player named in the question, matched against saved prop prices.
  final String? participant;
}

final _arb = RegExp(r'\b(arbs?|arbitrage|sure bets?|risk[- ]free)\b');
final _middle = RegExp(r'\bmiddl(e|es|ing)\b');
final _hold = RegExp(
  r'\b(low(est)?[- ]hold|low(est)?[- ]vig|lowest juice|reduced juice)\b',
);
final _value = RegExp(
  r'(\+ ?ev\b|\bpositive ev\b|\bexpected value\b|\bvalue (bets?|plays?|lines?|prices?)\b|\bunderpriced\b|\bmispriced\b|\bsoft (lines?|prices?)\b|\bbest value\b)',
);
final _best = RegExp(
  r'\b(best (price|line|odds|number)|line[- ]shop(ping)?|shop (the )?(line|price)|which (book|sportsbook)|where (should i|to) bet|compare (the )?(books|sportsbooks|prices|odds))\b',
);

/// Reads a price-shopping question. Null when the question is about
/// something else, so the regular research path answers it.
MarketQuery? parseMarketQuestion(
  String question, {
  Iterable<String> players = const [],
}) {
  final q = question.toLowerCase();
  final MarketAsk ask;
  if (_arb.hasMatch(q)) {
    ask = MarketAsk.arbitrage;
  } else if (_middle.hasMatch(q)) {
    ask = MarketAsk.middles;
  } else if (_hold.hasMatch(q)) {
    ask = MarketAsk.lowHold;
  } else if (_value.hasMatch(q)) {
    ask = MarketAsk.value;
  } else if (_best.hasMatch(q)) {
    ask = MarketAsk.bestPrice;
  } else {
    return null;
  }
  final teams = <String>{};
  for (final name in nflTeams.keys) {
    final nickname = name.split(' ').last.toLowerCase();
    if (q.contains(name.toLowerCase()) ||
        RegExp('\\b${RegExp.escape(nickname)}\\b').hasMatch(q)) {
      teams.add(name);
    }
  }
  final market = RegExp(r'\b(spreads?|point spread|ats)\b').hasMatch(q)
      ? 'spreads'
      : RegExp(r'\b(totals?|over/under|o/u)\b').hasMatch(q)
      ? 'totals'
      : RegExp(r'\b(moneylines?|money line|ml|to win)\b').hasMatch(q)
      ? 'h2h'
      : RegExp(r'\b(props?|yards|receptions|catches|carries)\b').hasMatch(q)
      ? 'props'
      : null;
  String? participant;
  for (final name in players) {
    if (name.isNotEmpty && q.contains(name.toLowerCase())) {
      participant = name;
      break;
    }
  }
  return MarketQuery(
    ask: ask,
    teams: teams,
    market: participant != null ? 'props' : market,
    participant: participant,
  );
}

class MarketAnswer {
  const MarketAnswer({
    required this.query,
    required this.markets,
    required this.arbitrage,
    required this.middles,
    required this.snapshotAt,
    required this.summary,
    this.emptyReason,
  });
  final MarketQuery query;
  final List<PricedMarket> markets;
  final List<ArbitrageOpportunity> arbitrage;
  final List<MiddleOpportunity> middles;
  final DateTime snapshotAt;
  final String summary;
  final String? emptyReason;
}

bool _isProp(String market) => market.startsWith('player_');

/// Answers [query] from the saved snapshot only. No prices are requested.
MarketAnswer answerMarketQuestion(
  MarketQuery query,
  OddsBoard board,
  DateTime now, {
  Set<String>? books,
  int limit = 6,
}) {
  final events = {for (final e in board.events) e.id: e};
  bool keepEvent(String eventId) {
    if (query.teams.isEmpty) return true;
    final e = events[eventId];
    return e != null && query.teams.every((t) => e.home == t || e.away == t);
  }

  bool keepMarket(String market, String detail) {
    final m = query.market;
    if (m != null) {
      if (m == 'props' ? !_isProp(market) : market != m) return false;
    }
    if (query.participant != null &&
        !detail.toLowerCase().contains(query.participant!.toLowerCase())) {
      return false;
    }
    return true;
  }

  final scoped = OddsBoard(
    events: board.events,
    quotes: [
      for (final q in board.quotes)
        if (keepEvent(q.selection.eventId) &&
            keepMarket(
              q.selection.market,
              '${q.selection.participant} ${q.selection.outcome}',
            ))
          q,
    ],
    fetchedAt: board.fetchedAt,
    demo: board.demo,
    notices: board.notices,
  );
  final scan = scanMarkets(scoped, now, books: books);
  var markets = [
    for (final m in scan.markets)
      if (m.sides.every((s) => s.best != null)) m,
  ];
  switch (query.ask) {
    case MarketAsk.value:
      markets = [
        for (final m in markets)
          if ((m.bestMarketEv ?? -1) > 0) m,
      ]..sort((a, b) => b.bestMarketEv!.compareTo(a.bestMarketEv!));
    case MarketAsk.lowHold:
      markets = sortPricedMarkets(markets, MarketSort.lowestFee);
    case MarketAsk.bestPrice:
    case MarketAsk.arbitrage:
    case MarketAsk.middles:
      break;
  }
  final arbs = query.ask == MarketAsk.arbitrage
      ? scan.arbitrage.where((a) => !a.sameBook).toList()
      : <ArbitrageOpportunity>[];
  final middles = query.ask == MarketAsk.middles
      ? scan.middles
      : <MiddleOpportunity>[];
  final shown =
      query.ask == MarketAsk.arbitrage || query.ask == MarketAsk.middles
      ? <PricedMarket>[]
      : markets.take(limit).toList();
  final scope = [
    if (query.participant != null) query.participant!,
    if (query.participant == null && query.teams.isNotEmpty)
      query.teams.join(' and '),
    if (query.market != null && query.participant == null)
      const {
        'spreads': 'spreads',
        'totals': 'totals',
        'h2h': 'moneylines',
        'props': 'player props',
      }[query.market]!,
  ].join(', ');
  final where = scope.isEmpty ? 'across saved games' : 'for $scope';
  final String summary;
  switch (query.ask) {
    case MarketAsk.arbitrage:
      summary = arbs.isEmpty
          ? 'No two-book arbitrage $where in the saved snapshot.'
          : '${arbs.length} two-book ${arbs.length == 1 ? 'price crosses' : 'prices cross'} $where. Best: ${(arbs.first.roi * 100).toStringAsFixed(1)}% on the combined stake if both bets are accepted at these prices.';
    case MarketAsk.middles:
      summary = middles.isEmpty
          ? 'No middle windows $where in the saved snapshot.'
          : '${middles.length} middle ${middles.length == 1 ? 'window' : 'windows'} $where, where both bets can win.';
    case MarketAsk.value:
      summary = markets.isEmpty
          ? 'No saved price beats the fee-free market $where.'
          : '${markets.length} saved ${markets.length == 1 ? 'price beats' : 'prices beat'} the fee-free market average $where. Top: ${_sideLabel(markets.first)}, ${(markets.first.bestMarketEv! * 100).toStringAsFixed(1)}% per dollar versus that market.';
    case MarketAsk.lowHold:
      summary = markets.isEmpty
          ? 'No complete two-sided markets $where.'
          : 'Lowest combined fee $where: ${markets.first.detail} in ${markets.first.matchup}, ${((markets.first.bestHold ?? 0) * 100).toStringAsFixed(1)}% at the best prices.';
    case MarketAsk.bestPrice:
      summary = markets.isEmpty
          ? 'No complete saved prices $where.'
          : 'Best saved price for each side $where, with the fee-free market chance.';
  }
  return MarketAnswer(
    query: query,
    markets: shown,
    arbitrage: arbs.take(limit).toList(),
    middles: middles.take(limit).toList(),
    snapshotAt: board.fetchedAt,
    summary: summary,
    emptyReason: scan.emptyReason,
  );
}

String _sideLabel(PricedMarket market) {
  final side = market.sides.reduce(
    (a, b) => (a.marketEv ?? -9) >= (b.marketEv ?? -9) ? a : b,
  );
  return '${sideLabel(side)} at ${side.best!.book} ${americanLabel(side.best!.decimal)}';
}

String sideLabel(PricedSide side) {
  final s = side.selection;
  final point = s.point == null
      ? ''
      : ' ${s.point! > 0 && s.market == 'spreads' ? '+' : ''}${s.point}';
  final who = s.participant.isEmpty ? '' : '${s.participant} ';
  return '$who${s.outcome}$point';
}
