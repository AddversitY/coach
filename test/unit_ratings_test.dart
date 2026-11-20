import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/unit_ratings.dart';

PlayerGame game({
  required String team,
  required String opponent,
  required int week,
  required double passYards,
  required double attempts,
}) {
  return PlayerGame(
    playerId: 'qb-$team',
    name: 'Passer $team',
    position: 'QB',
    team: team,
    opponent: opponent,
    season: 2026,
    week: week,
    date: DateTime.utc(2026, 9, week),
    seasonType: 'REG',
    stats: {'passing_yards': passYards, 'attempts': attempts, 'sacks_suffered': 2},
  );
}

void main() {
  test('a rating for a week ignores that week and later weeks', () {
    const clubs = ['A', 'B', 'C', 'D'];
    final rows = <PlayerGame>[];
    for (var week = 1; week <= 6; week++) {
      for (var i = 0; i < clubs.length; i++) {
        final team = clubs[i];
        final opponent = clubs[(i + 1) % clubs.length];
        final yards = team == 'A' && week >= 5 ? 400.0 : team == 'A' ? 100.0 : 220.0;
        rows.add(
          game(
            team: team,
            opponent: opponent,
            week: week,
            passYards: yards,
            attempts: 30,
          ),
        );
      }
    }
    final book = RatingBook.build(rows);
    final beforeFive = book.before(season: 2026, week: 5);
    final after = book.before(season: 2026, week: 7);
    final early = beforeFive.lookup('A', UnitKey.pass, offense: true);
    final later = after.lookup('A', UnitKey.pass, offense: true);
    expect(early, isNotNull);
    expect(later, isNotNull);
    expect(early!.versusLeague, isNot(closeTo(later!.versusLeague!, 0.05)));
    expect(early.games, 4);
    expect(later.games, 6);
    final ranked = [
      for (final club in clubs)
        beforeFive.lookup(club, UnitKey.pass, offense: false),
    ].whereType<UnitRating>().where((row) => row.ranked).toList();
    expect(ranked.where((row) => row.tier == UnitTier.elite), isNotEmpty);
    expect(ranked.where((row) => row.tier == UnitTier.weak), isNotEmpty);
  });
}
