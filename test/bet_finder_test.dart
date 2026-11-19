import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/bet_finder.dart';
import 'package:odds_edge/domain/odds.dart';
import 'package:odds_edge/domain/player_stats.dart';

final now = DateTime.utc(2026, 11, 19, 12);
final kickoff = DateTime.utc(2026, 11, 22, 18);

SportEvent game(String id, String away, String home) =>
    SportEvent(id, away, home, kickoff);

OddsQuote q(
  String event,
  String book,
  String outcome,
  double decimal, {
  String market = 'h2h',
  double? point,
}) => OddsQuote(
  selection: Selection(
    eventId: event,
    market: market,
    outcome: outcome,
    point: point,
    rules: 'game_market_unverified',
  ),
  bookId: book,
  book: book,
  provider: 'test',
  decimal: decimal,
  sourceAt: now.subtract(const Duration(minutes: 5)),
  collectedAt: now.subtract(const Duration(minutes: 1)),
);

/// Three games. Book "soft" hangs a better price on one side of each game.
OddsBoard board() {
  final games = [
    game('g1', 'Buffalo Bills', 'Kansas City Chiefs'),
    game('g2', 'Miami Dolphins', 'New York Jets'),
    game('g3', 'Dallas Cowboys', 'Philadelphia Eagles'),
  ];
  return OddsBoard(
    events: games,
    quotes: [
      for (final g in games) ...[
        for (final book in ['a', 'b']) ...[
          q(g.id, book, g.home, 1.8),
          q(g.id, book, g.away, 2.05),
        ],
        q(g.id, 'soft', g.home, 1.8),
        q(g.id, 'soft', g.away, 2.25),
        // A longshot that looks good only because of fee removal error.
        q(g.id, 'a', 'Over', 1.91, market: 'totals', point: 44.5),
        q(g.id, 'a', 'Under', 1.91, market: 'totals', point: 44.5),
      ],
    ],
    fetchedAt: now.subtract(const Duration(minutes: 1)),
  );
}

void main() {
  test('recognizes requests for ideas but not explicit legs', () {
    expect(asksForBetIdeas('build me a 3 leg parlay'), isTrue);
    expect(asksForBetIdeas('best bets this week'), isTrue);
    expect(asksForBetIdeas('best prop bets'), isTrue);
    expect(asksForBetIdeas('best longshot bets'), isTrue);
    expect(asksForBetIdeas('what should I bet on Sunday'), isTrue);
    expect(
      asksForBetIdeas('parlay Josh Allen over 250.5 and Kelce over 5.5'),
      isFalse,
    );
    expect(asksForBetIdeas('Bills at Chiefs spread'), isFalse);
  });

  test('straight bets rank prices above the fee-free market first', () {
    final answer = findBets('best bets', board(), now);
    expect(answer.straight.first.price.bookId, 'soft');
    expect(answer.straight.first.edge, greaterThan(0));
    expect(answer.summary, contains('beat the fee-free market'));
  });

  test('a parlay uses one book, one leg per game, at that book\'s prices', () {
    final answer = findBets('build me a 3-leg parlay', board(), now);
    final parlay = answer.parlay!;
    expect(parlay.legs, hasLength(3));
    expect(parlay.legs.map((l) => l.eventId).toSet(), hasLength(3));
    expect(parlay.legs.map((l) => l.price.bookId).toSet(), {'soft'});
    var decimal = 1.0;
    for (final l in parlay.legs) {
      decimal *= l.price.decimal;
    }
    expect(parlay.decimal, closeTo(decimal, 1e-9));
    expect(parlay.edge, greaterThan(0));
  });

  test('a parlay that needs more games than exist is declined', () {
    final answer = findBets('give me a 5 leg parlay', board(), now);
    expect(answer.parlay, isNull);
    expect(answer.notes.first, contains('Not enough separate games'));
  });

  test('long prices are left out unless asked for', () {
    final longshot = OddsBoard(
      events: [game('g1', 'Buffalo Bills', 'Kansas City Chiefs')],
      quotes: [
        q('g1', 'a', 'Kansas City Chiefs', 1.12),
        q('g1', 'a', 'Buffalo Bills', 6.0),
        q('g1', 'b', 'Kansas City Chiefs', 1.12),
        q('g1', 'b', 'Buffalo Bills', 7.5),
      ],
      fetchedAt: now.subtract(const Duration(minutes: 1)),
    );
    expect(findBets('best bets', longshot, now).straight, isEmpty);
    expect(findBets('best longshot bets', longshot, now).straight, isNotEmpty);
  });

  test('a prop estimate leans toward a long record, never past 30% weight', () {
    final rows = [
      for (var w = 1; w <= 20; w++)
        PlayerGame(
          playerId: 'p1',
          name: 'Test Receiver',
          position: 'WR',
          team: 'BUF',
          opponent: 'MIA',
          season: 2026,
          week: w,
          // All twenty games played before [now].
          date: DateTime.utc(2026, 4, 1).add(Duration(days: 7 * w)),
          seasonType: 'REG',
          stats: {'receiving_yards': 90},
        ),
    ];
    OddsQuote prop(String book, String side, double decimal) => OddsQuote(
      selection: Selection(
        eventId: 'g1',
        market: 'player_reception_yds',
        outcome: side,
        participant: 'Test Receiver',
        point: 60.5,
        rules: 'player_prop_unverified',
      ),
      bookId: book,
      book: book,
      provider: 'test',
      decimal: decimal,
      sourceAt: now.subtract(const Duration(minutes: 5)),
      collectedAt: now.subtract(const Duration(minutes: 1)),
    );
    final board = OddsBoard(
      events: [game('g1', 'Buffalo Bills', 'Kansas City Chiefs')],
      quotes: [
        for (final book in ['a', 'b']) ...[
          prop(book, 'Over', 1.91),
          prop(book, 'Under', 1.91),
        ],
      ],
      fetchedAt: now.subtract(const Duration(minutes: 1)),
    );
    final answer = findBets(
      'best prop bets',
      board,
      now,
      data: PlayerStatsDataset(rows: rows),
      playerIds: {'Test Receiver': 'p1'},
    );
    final over = answer.straight.first;
    expect(over.side.selection.outcome, 'Over');
    expect(over.signal, RecordSignal.agrees);
    expect(over.estimate, greaterThan(over.fair));
    // 20 games: weight .3 * 20 / 30 = .2; record (20 + 2) / 24.
    expect(over.estimate, closeTo(.8 * .5 + .2 * 22 / 24, 1e-9));
    expect(over.edge, greaterThan(0));
  });

  test(
    'a same-game parlay adjusts the joint chance for legs that move together',
    () {
      // A quarterback and his receiver: both clear in the same 12 of 24 games.
      final rows = <PlayerGame>[
        for (var w = 1; w <= 24; w++) ...[
          for (final (id, name, pos, metric, value) in [
            ('qb', 'Test Passer', 'QB', 'passing_yards', w.isEven ? 300 : 180),
            (
              'wr',
              'Test Catcher',
              'WR',
              'receiving_yards',
              w.isEven ? 100 : 40,
            ),
          ])
            PlayerGame(
              playerId: id,
              name: name,
              position: pos,
              team: 'BUF',
              opponent: 'MIA',
              season: 2025 + (w > 12 ? 1 : 0),
              week: (w - 1) % 12 + 1,
              date: DateTime.utc(2025, 9, 1).add(Duration(days: 14 * w)),
              seasonType: 'REG',
              stats: {metric: value},
            ),
        ],
      ];
      OddsQuote prop(
        String book,
        String player,
        String market,
        String side,
        double point,
      ) => OddsQuote(
        selection: Selection(
          eventId: 'g1',
          market: market,
          outcome: side,
          participant: player,
          point: point,
          rules: 'player_prop_unverified',
        ),
        bookId: book,
        book: book,
        provider: 'test',
        decimal: 1.91,
        sourceAt: now.subtract(const Duration(minutes: 5)),
        collectedAt: now.subtract(const Duration(minutes: 1)),
      );
      final board = OddsBoard(
        events: [game('g1', 'Buffalo Bills', 'Kansas City Chiefs')],
        quotes: [
          for (final book in ['a', 'b'])
            for (final side in ['Over', 'Under']) ...[
              prop(book, 'Test Passer', 'player_pass_yds', side, 240.5),
              prop(book, 'Test Catcher', 'player_reception_yds', side, 70.5),
            ],
        ],
        fetchedAt: now.subtract(const Duration(minutes: 1)),
      );
      final answer = findBets(
        'same game parlay Bills',
        board,
        now,
        data: PlayerStatsDataset(rows: rows),
        playerIds: {'Test Passer': 'qb', 'Test Catcher': 'wr'},
      );
      final parlay = answer.parlay!;
      expect(parlay.sameGame, isTrue);
      expect(
        parlay.legs.map((l) => l.side.selection.participant).toSet(),
        hasLength(2),
      );
      expect(parlay.sharedGames, 24);
      // Raw lift: .5 / (.5 * .5) = 2, shrunk with 24 games: 1 + 1 * 24 / 44.
      expect(parlay.correlation, closeTo(1 + 24 / 44, 1e-9));
      var independent = 1.0;
      for (final leg in parlay.legs) {
        independent *= leg.estimate;
      }
      expect(parlay.fair, closeTo(independent * parlay.correlation, 1e-9));
    },
  );
}
