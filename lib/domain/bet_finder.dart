import 'game_research.dart';
import 'market_math.dart';
import 'market_question.dart';
import 'odds.dart';
import 'player_stats.dart';
import 'prop_depth.dart';

/// How the player's record compares with the market on this side.
enum RecordSignal { agrees, disagrees, none }

/// One bet Coach can stand behind with numbers: a price above the fee-free
/// consensus of the other books, and for props the player's record.
class BetIdea {
  const BetIdea({
    required this.market,
    required this.side,
    required this.price,
    required this.fair,
    required this.edge,
    double? estimate,
    this.recordRate,
    this.recordSample = 0,
    this.signal = RecordSignal.none,
  }) : estimate = estimate ?? fair;
  final PricedMarket market;
  final PricedSide side;
  final OddsQuote price;

  /// Fee-free consensus chance of this side.
  final double fair;

  /// Coach's chance: the market, plus for props up to 30% weight on the
  /// player's record (more games, more weight).
  final double estimate;

  /// Profit per dollar at [price] if [estimate] is right.
  final double edge;

  /// Shrunk record rate for this side (props only), and the games behind it.
  final double? recordRate;
  final int recordSample;
  final RecordSignal signal;

  String get label => sideLabel(side);
  String get eventId => market.eventId;
}

class ParlayIdea {
  const ParlayIdea({
    required this.book,
    required this.legs,
    required this.decimal,
    required this.fair,
  });
  final String book;
  final List<BetIdea> legs;

  /// Legs multiplied at [book]'s own prices.
  final double decimal;

  /// Product of the legs' fee-free chances. Legs are in different games.
  final double fair;
  double get edge => fair * decimal - 1;
}

class BetFinderAnswer {
  const BetFinderAnswer({
    required this.straight,
    this.parlay,
    required this.summary,
    required this.notes,
    required this.snapshotAt,
  });
  final List<BetIdea> straight;
  final ParlayIdea? parlay;
  final String summary;
  final List<String> notes;
  final DateTime snapshotAt;
}

final _parlay = RegExp(r'\bparlays?\b');
final _bestBets = RegExp(
  r'\b(best|top|good|strongest|smart(est)?) (straight |prop |player prop |game |longshot |value |parlay )?(bets?|plays?|picks?)\b|\bwhat should i bet\b|\bstraight bets?\b',
);
final _explicitLeg = RegExp(r'\b(over|under|o|u)\s*\d');

/// True for "build me a parlay", "best bets this week" and similar, but not
/// when explicit legs are supplied (those go to the joint simulation).
bool asksForBetIdeas(String question) {
  final q = question.toLowerCase();
  if (_explicitLeg.hasMatch(q)) return false;
  return _parlay.hasMatch(q) &&
          RegExp(
            r'\b(build|make|create|give|suggest|best|good|find|recommend|show|top|smart)\b',
          ).hasMatch(q) ||
      _bestBets.hasMatch(q);
}

int _legCount(String q) {
  final m = RegExp(r'\b([2-6])[- ]?(leg|team|pick)').firstMatch(q);
  if (m != null) return int.parse(m.group(1)!);
  for (final e in const {'two': 2, 'three': 3, 'four': 4}.entries) {
    if (RegExp('\\b${e.key}[- ]?(leg|team|pick)').hasMatch(q)) return e.value;
  }
  return 3;
}

/// Ranks straight bets and builds a cross-game parlay from saved prices.
///
/// The edge is the price against the fee-free consensus of the other books,
/// which is line shopping, not a forecast. Player records are shown beside
/// props as a second, independent check.
BetFinderAnswer findBets(
  String question,
  OddsBoard board,
  DateTime now, {
  PlayerStatsDataset? data,
  Map<String, String> playerIds = const {},
  Set<String>? books,
  int limit = 5,
}) {
  final q = question.toLowerCase();
  final base = parseMarketQuestion(question, players: playerIds.keys);
  final query = MarketQuery(
    ask: MarketAsk.value,
    teams: base?.teams ?? _teams(question),
    market: base?.market ?? _market(q),
    participant: base?.participant,
  );
  final scan = answerMarketQuestion(
    MarketQuery(
      ask: MarketAsk.bestPrice,
      teams: query.teams,
      market: query.market,
      participant: query.participant,
    ),
    board,
    now,
    books: books,
    limit: 1 << 20,
  );
  // Long prices carry the most fee-removal error and rarely make a sensible
  // ticket, so they are left out unless the question asks for them.
  final longshots = RegExp(
    r'\b(longshots?|long shots?|lotto|big odds|plus money)\b',
  ).hasMatch(q);
  bool inRange(double decimal) =>
      longshots || (decimal >= 1.4 && decimal <= 3.5);
  final ideas = <BetIdea>[];
  for (final market in scan.markets) {
    if (!market.complete || market.booksAveraged < 2) continue;
    for (final side in market.sides) {
      final fair = side.fairProbability, best = side.best;
      if (fair == null || best == null || !inRange(best.decimal)) continue;
      ideas.add(
        _withRecord(
          BetIdea(
            market: market,
            side: side,
            price: best,
            fair: fair,
            edge: fair * best.decimal - 1,
          ),
          data,
          playerIds,
          now,
        ),
      );
    }
  }
  ideas.sort((a, b) => b.edge.compareTo(a.edge));
  final positive = [
    for (final i in ideas)
      if (i.edge > 0) i,
  ];
  final straight = (positive.isNotEmpty ? positive : ideas)
      .take(limit)
      .toList();

  ParlayIdea? parlay;
  final notes = <String>[];
  if (_parlay.hasMatch(q)) {
    final usable = usableSnapshotQuotes(
      board.quotes,
      now,
      books: books,
      events: board.events,
      fetchedAt: board.fetchedAt,
    );
    parlay = _buildParlay(
      scan.markets,
      [
        for (final quote in usable)
          if (inRange(quote.decimal)) quote,
      ],
      _legCount(q),
      data,
      playerIds,
      now,
    );
    if (parlay == null) {
      notes.add(
        'Not enough separate games with every leg at one book to build that parlay.',
      );
    }
  }
  final distinctGames = straight.map((i) => i.eventId).toSet().length;
  final String summary;
  if (ideas.isEmpty) {
    summary =
        'No complete prices from at least two books in the saved snapshot'
        '${query.teams.isEmpty ? '' : ' for ${query.teams.join(' and ')}'}.';
  } else if (parlay != null) {
    summary =
        '${parlay.legs.length}-leg parlay at ${parlay.book}: ${americanLabel(parlay.decimal)}, '
        'fee-free chance ${(parlay.fair * 100).toStringAsFixed(1)}%, '
        '${parlay.edge >= 0 ? '+' : ''}${(parlay.edge * 100).toStringAsFixed(1)}% per dollar against the market.';
  } else if (positive.isEmpty) {
    summary =
        'No saved price beats the fee-free market right now. These are the closest, across $distinctGames ${distinctGames == 1 ? 'game' : 'games'}.';
  } else {
    summary =
        '${positive.length} saved ${positive.length == 1 ? 'price beats' : 'prices beat'} the fee-free market. '
        'Best: ${straight.first.label} ${americanLabel(straight.first.price.decimal)} at ${straight.first.price.book}, '
        '+${(straight.first.edge * 100).toStringAsFixed(1)}% per dollar.';
  }
  if (!longshots) {
    notes.add(
      'Prices from -250 to +250 only. Ask for longshots to include the rest.',
    );
  }
  notes.add(
    'The edge is each price against Coach\'s chance: the fee-free average of the books, and for props up to 30% weight on the player\'s record. Not a validated forecast.',
  );
  if (straight.any((i) => i.signal == RecordSignal.disagrees)) {
    notes.add(
      'A prop marked "record disagrees" has history pointing the other way.',
    );
  }
  return BetFinderAnswer(
    straight: straight,
    parlay: parlay,
    summary: summary,
    notes: notes,
    snapshotAt: board.fetchedAt,
  );
}

BetIdea _withRecord(
  BetIdea idea,
  PlayerStatsDataset? data,
  Map<String, String> playerIds,
  DateTime now,
) {
  final s = idea.side.selection;
  final playerId = playerIds[s.participant];
  final metric = _metricFor(s.market);
  if (data == null || playerId == null || metric == null || s.point == null) {
    return idea;
  }
  final depth = propDepth(
    data: data,
    playerId: playerId,
    metric: metric,
    line: s.point!,
    through: now,
  );
  final over = depth.historyOver;
  if (over == null) return idea;
  final isOver = s.outcome.toLowerCase() == 'over';
  final rate = isOver ? over : 1 - over;
  final sample = depth.windows
      .lastWhere((w) => w.decided >= 8, orElse: () => depth.windows.last)
      .decided;
  final diff = rate - idea.fair;
  final weight = .3 * sample / (sample + 10);
  final estimate = (1 - weight) * idea.fair + weight * rate;
  return BetIdea(
    market: idea.market,
    side: idea.side,
    price: idea.price,
    fair: idea.fair,
    estimate: estimate,
    edge: estimate * idea.price.decimal - 1,
    recordRate: rate,
    recordSample: sample,
    signal: sample < 5
        ? RecordSignal.none
        : diff >= 0.05
        ? RecordSignal.agrees
        : diff <= -0.05
        ? RecordSignal.disagrees
        : RecordSignal.none,
  );
}

String? _metricFor(String market) {
  for (final m in [
    passingResearch,
    rushingResearch,
    receivingResearch,
    receptionsResearch,
  ]) {
    if (m.market == market) return m.key;
  }
  return null;
}

/// One leg per game, all priced at the same book, since a parlay is placed
/// at one book. Picks the book whose best legs give the highest edge.
ParlayIdea? _buildParlay(
  List<PricedMarket> markets,
  List<OddsQuote> usable,
  int legs,
  PlayerStatsDataset? data,
  Map<String, String> playerIds,
  DateTime now,
) {
  final offers = <String, List<OddsQuote>>{};
  for (final quote in usable) {
    (offers[quote.selection.key] ??= []).add(quote);
  }
  final byBook = <String, List<BetIdea>>{};
  for (final market in markets) {
    if (!market.complete || market.booksAveraged < 2) continue;
    for (final side in market.sides) {
      final fair = side.fairProbability;
      if (fair == null) continue;
      for (final quote in offers[side.selection.key] ?? const <OddsQuote>[]) {
        (byBook[quote.bookId] ??= []).add(
          BetIdea(
            market: market,
            side: side,
            price: quote,
            fair: fair,
            edge: fair * quote.decimal - 1,
          ),
        );
      }
    }
  }
  ParlayIdea? best;
  for (final entry in byBook.entries) {
    final candidates = [...entry.value]
      ..sort((a, b) => b.edge.compareTo(a.edge));
    final chosen = <BetIdea>[];
    final games = <String>{};
    for (final c in candidates) {
      if (games.add(c.eventId)) chosen.add(c);
      if (chosen.length == legs) break;
    }
    if (chosen.length < legs) continue;
    var decimal = 1.0, fair = 1.0;
    for (final leg in chosen) {
      decimal *= leg.price.decimal;
      fair *= leg.fair;
    }
    final idea = ParlayIdea(
      book: chosen.first.price.book,
      legs: [for (final leg in chosen) _withRecord(leg, data, playerIds, now)],
      decimal: decimal,
      fair: fair,
    );
    if (best == null || idea.edge > best.edge) best = idea;
  }
  return best;
}

Set<String> _teams(String question) =>
    parseMarketQuestion('best price $question')?.teams ?? const {};

String? _market(String q) => parseMarketQuestion('best price $q')?.market;
