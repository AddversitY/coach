import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/odds.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/prop_depth.dart';

PlayerGame game(
  String id,
  String position,
  String team,
  String opponent,
  int week,
  num? yards,
) => PlayerGame(
  playerId: id,
  name: id,
  position: position,
  team: team,
  opponent: opponent,
  season: 2026,
  week: week,
  date: DateTime.utc(2026, 9, 1).add(Duration(days: 7 * week)),
  seasonType: 'REG',
  stats: {'receiving_yards': yards},
);

OddsQuote quote(String book, String side, double point, double decimal) =>
    OddsQuote(
      selection: Selection(
        eventId: 'g',
        market: 'player_reception_yds',
        outcome: side,
        participant: 'wr1',
        point: point,
        rules: 'player_prop_unverified',
      ),
      bookId: book,
      book: book,
      provider: 'test',
      decimal: decimal,
      sourceAt: DateTime.utc(2026, 11, 18),
      collectedAt: DateTime.utc(2026, 11, 18),
    );

void main() {
  final rows = [
    // wr1 cleared 60.5 in 7 of 10 games, and twice in two games against KC.
    for (var w = 1; w <= 10; w++)
      game('wr1', 'WR', 'BUF', w <= 2 ? 'KC' : 'MIA', w, w <= 7 ? 80 : 40),
    // Two defenses: KC allows more WR yards than NYJ.
    for (var w = 1; w <= 3; w++) game('x$w', 'WR', 'LV', 'KC', w, 120),
    for (var w = 1; w <= 3; w++) game('y$w', 'WR', 'LV', 'NYJ', w, 30),
  ];
  final data = PlayerStatsDataset(rows: rows);

  test('windows count overs newest first and skip missing stats', () {
    final depth = propDepth(
      data: data,
      playerId: 'wr1',
      metric: 'receiving_yards',
      line: 60.5,
      opponent: 'KC',
    );
    final byLabel = {for (final w in depth.windows) w.label: w};
    // Newest five are weeks 10..6: weeks 6 and 7 cleared.
    expect(byLabel['Last 5']!.overs, 2);
    expect(byLabel['Last 10']!.overs, 7);
    expect(byLabel['2026 season']!.decided, 10);
    expect(depth.vsOpponent!.overs, 2);
    expect(depth.lastSeason, isNull);
    // Shrunk toward 50%: (7 + 2) / (10 + 4).
    expect(depth.historyOver, closeTo(9 / 14, 1e-9));
  });

  test('defense vs position ranks the softest defense first', () {
    final kc = defenseVsPosition(
      rows,
      opponent: 'KC',
      position: 'WR',
      metric: 'receiving_yards',
      season: 2026,
    )!;
    final nyj = defenseVsPosition(
      rows,
      opponent: 'NYJ',
      position: 'WR',
      metric: 'receiving_yards',
      season: 2026,
    )!;
    expect(kc.rank, lessThan(nyj.rank));
    expect(nyj.allowedPerGame, 30);
  });

  test('market view removes the fee per book and finds the best price', () {
    final depth = propDepth(
      data: data,
      playerId: 'wr1',
      metric: 'receiving_yards',
      line: 60.5,
      quotes: [
        quote('a', 'Over', 60.5, 1.87),
        quote('a', 'Under', 60.5, 1.95),
        quote('b', 'Over', 60.5, 1.91),
        quote('b', 'Under', 60.5, 1.91),
        quote('c', 'Over', 70.5, 2.5),
      ],
    );
    final market = depth.market!;
    expect(market.books, 2);
    expect(market.bestOver!.bookId, 'b');
    expect(market.bestUnder!.bookId, 'a');
    expect(market.fairOver, closeTo(0.5 * (0.5104 + 0.5), 0.002));
    expect(depth.historyVersusMarket, isNotNull);
  });

  test('a player with no record says so instead of inventing rates', () {
    final depth = propDepth(
      data: data,
      playerId: 'nobody',
      metric: 'receiving_yards',
      line: 50.5,
    );
    expect(depth.historyOver, isNull);
    expect(depth.notes.single, contains('No recorded'));
  });
}
