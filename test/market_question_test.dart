import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/market_question.dart';
import 'package:odds_edge/domain/odds.dart';

final now = DateTime.utc(2026, 11, 19, 12);
final kickoff = DateTime.utc(2026, 11, 20, 1, 15);
const game = 'nflverse:2026_11_BUF_KC';

OddsQuote q(
  String book,
  String market,
  String outcome,
  double? point,
  double decimal, {
  String participant = '',
}) => OddsQuote(
  selection: Selection(
    eventId: game,
    market: market,
    outcome: outcome,
    point: point,
    participant: participant,
    rules: participant.isEmpty
        ? 'game_market_unverified'
        : 'player_prop_unverified',
  ),
  bookId: book,
  book: book,
  provider: 'test',
  decimal: decimal,
  sourceAt: now.subtract(const Duration(minutes: 5)),
  collectedAt: now.subtract(const Duration(minutes: 1)),
);

OddsBoard board(List<OddsQuote> quotes) => OddsBoard(
  events: [SportEvent(game, 'Buffalo Bills', 'Kansas City Chiefs', kickoff)],
  quotes: quotes,
  fetchedAt: now.subtract(const Duration(minutes: 1)),
);

void main() {
  test(
    'price-shopping questions are recognized and other questions are not',
    () {
      expect(
        parseMarketQuestion('best price on the Bills spread')!.ask,
        MarketAsk.bestPrice,
      );
      expect(
        parseMarketQuestion('any arbs tonight?')!.ask,
        MarketAsk.arbitrage,
      );
      expect(parseMarketQuestion('find me middles')!.ask, MarketAsk.middles);
      expect(parseMarketQuestion('show +EV plays')!.ask, MarketAsk.value);
      expect(parseMarketQuestion('lowest hold totals')!.ask, MarketAsk.lowHold);
      expect(parseMarketQuestion('Bills at Chiefs best bet'), isNull);
      expect(
        parseMarketQuestion('Josh Allen passing yards over 250.5'),
        isNull,
      );
      final scoped = parseMarketQuestion('best line on the Bills spread')!;
      expect(scoped.teams, {'Buffalo Bills'});
      expect(scoped.market, 'spreads');
      final player = parseMarketQuestion(
        'which book has the best price for Josh Allen passing yards',
        players: ['Josh Allen'],
      )!;
      expect(player.participant, 'Josh Allen');
      expect(player.market, 'props');
    },
  );

  test('best price keeps the requested market and both sides', () {
    final answer = answerMarketQuestion(
      parseMarketQuestion('best price Bills spread')!,
      board([
        q('a', 'spreads', 'Buffalo Bills', 2.5, 1.91),
        q('a', 'spreads', 'Kansas City Chiefs', -2.5, 1.91),
        q('b', 'spreads', 'Buffalo Bills', 2.5, 1.95),
        q('b', 'spreads', 'Kansas City Chiefs', -2.5, 1.87),
        q('a', 'totals', 'Over', 47.5, 1.91),
        q('a', 'totals', 'Under', 47.5, 1.91),
      ]),
      now,
    );
    expect(answer.markets, hasLength(1));
    final sides = answer.markets.single.sides;
    expect(
      sides
          .firstWhere((s) => s.selection.outcome == 'Buffalo Bills')
          .best!
          .bookId,
      'b',
    );
  });

  test('two books that cross are reported with their stake split', () {
    final answer = answerMarketQuestion(
      parseMarketQuestion('any arbitrage?')!,
      board([
        q('a', 'h2h', 'Buffalo Bills', null, 2.2),
        q('a', 'h2h', 'Kansas City Chiefs', null, 1.7),
        q('b', 'h2h', 'Buffalo Bills', null, 1.9),
        q('b', 'h2h', 'Kansas City Chiefs', null, 2.0),
      ]),
      now,
    );
    expect(answer.arbitrage, hasLength(1));
    expect(answer.arbitrage.single.roi, greaterThan(0));
    expect(answer.summary, contains('if both bets are accepted'));
  });

  test('value lists only prices above the fee-free market, best first', () {
    final answer = answerMarketQuestion(
      parseMarketQuestion('show me value bets')!,
      board([
        q('a', 'totals', 'Over', 47.5, 1.91),
        q('a', 'totals', 'Under', 47.5, 1.91),
        q('b', 'totals', 'Over', 47.5, 1.91),
        q('b', 'totals', 'Under', 47.5, 1.91),
        q('c', 'totals', 'Over', 47.5, 2.1),
        q('c', 'totals', 'Under', 47.5, 1.75),
      ]),
      now,
    );
    expect(answer.markets, hasLength(1));
    expect(answer.markets.single.bestMarketEv, greaterThan(0));
    expect(answer.summary, contains('Over 47.5 at c'));
  });

  test('games that have started are left out', () {
    final answer = answerMarketQuestion(
      parseMarketQuestion('best price')!,
      board([
        q('a', 'h2h', 'Buffalo Bills', null, 2.2),
        q('a', 'h2h', 'Kansas City Chiefs', null, 1.7),
      ]),
      kickoff.add(const Duration(minutes: 1)),
    );
    expect(answer.markets, isEmpty);
    expect(answer.emptyReason, isNotNull);
  });
}
