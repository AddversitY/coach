import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/history.dart';
import 'package:odds_edge/domain/team_trends.dart';

HistoricalGame g(
  String date,
  String home,
  String away,
  int hs,
  int as,
  double? spread,
  double? total,
) => HistoricalGame(
  season: 2026,
  date: DateTime.parse(date),
  home: home,
  away: away,
  homeScore: hs,
  awayScore: as,
  spreadLine: spread,
  totalLine: total,
);

void main() {
  test('covers use the team side of the closing line, pushes stay pushes', () {
    final history = [
      // KC favored by 3 at home, wins by 7: KC covers, BUF does not.
      g('2026-10-01', 'KC', 'BUF', 27, 20, 3, 44.5),
      // KC an underdog by 2.5 on the road, loses by 3: KC does not cover.
      g('2026-10-08', 'DEN', 'KC', 20, 17, 2.5, 40.5),
      // KC favored by 3 at home, wins by 3: push.
      g('2026-10-15', 'KC', 'LV', 23, 20, 3, 47),
      // No line published: ignored.
      g('2026-10-22', 'KC', 'NYJ', 30, 0, null, null),
      // After the cutoff: ignored.
      g('2026-12-01', 'KC', 'BUF', 0, 30, 3, 40),
    ];
    final trends = matchupTrends(
      history,
      home: 'KC',
      away: 'BUF',
      before: DateTime.utc(2026, 11, 20),
      homeSpread: -3,
    );
    final kc = trends.trends.firstWhere(
      (t) => t.team == 'KC' && t.label == 'against the spread, last 10',
    );
    expect([kc.wins, kc.losses, kc.pushes], [1, 1, 1]);
    expect(kc.smallSample, isTrue);
    expect(
      kc.sentence,
      'KC 1-1-1 cover/no cover against the spread, last 10 (small sample).',
    );
    final totals = trends.trends.firstWhere(
      (t) => t.team == 'KC' && t.label == 'on the total, last 10',
    );
    // 47 total vs 44.5 over; 37 vs 40.5 under; 43 vs 47 under.
    expect([totals.wins, totals.losses], [1, 2]);
    final h2h = trends.trends.last;
    expect(h2h.label, contains('vs KC'));
    expect([h2h.wins, h2h.losses], [0, 1]);
    expect(trends.games, 3);
  });

  test('bundled history carries closing lines for trends', () {
    final raw = jsonDecode(File('assets/nfl-history.json').readAsStringSync());
    final games = [
      for (final row in raw['games']) HistoricalGame.fromJson(row),
    ];
    final lined = games.where((game) => game.spreadLine != null).length;
    expect(lined / games.length, greaterThan(.95));
    final trends = matchupTrends(
      games,
      home: 'KC',
      away: 'BUF',
      before: DateTime.utc(2026, 11, 20),
    );
    expect(trends.trends.first.decided, greaterThanOrEqualTo(9));
  });
}
