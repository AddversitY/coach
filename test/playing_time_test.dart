import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/history.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/playing_time.dart';
import 'package:odds_edge/domain/playing_time_eval.dart';
import 'package:odds_edge/domain/prop_context.dart';
import 'package:odds_edge/domain/prop_projection.dart';

void main() {
  test('names fold the same way as the prop card', () {
    expect(playingTimeName("A.J. Brown"), normalizePropName("A.J. Brown"));
    expect(playingTimeName('D.K. Metcalf'), 'dk metcalf');
  });

  test('a later snap does not change the earlier projection', () {
    final book = _book(
      snaps: {for (var week = 1; week <= 8; week++) week: 0.50},
      laterSnap: 0.05,
    );
    final move = book.move(
      playerId: 'wr',
      metric: 'receiving_yards',
      team: 'HOU',
      position: 'WR',
      season: 2025,
      week: 9,
    );
    expect(move.factor, 1);
    expect(move.basis, PlayingTimeBasis.snap);
  });

  test(
    'a snap share that already rose moves the next week part of the way',
    () {
      final snaps = <int, double>{
        for (var week = 1; week <= 5; week++) week: 0.30,
        for (var week = 6; week <= 8; week++) week: 0.80,
      };
      final move = _book(snaps: snaps).move(
        playerId: 'wr',
        metric: 'receiving_yards',
        team: 'HOU',
        position: 'WR',
        season: 2025,
        week: 9,
      );
      expect(move.factor, closeTo(playingTimeRoleCeil, 1e-9));
      expect(move.basis, PlayingTimeBasis.snap);
      expect(move.detail, contains('Snap share'));
      expect(move.detail, contains('unavailable'));
    },
  );

  test('route share is used for receivers when earlier weeks have it', () {
    final book = _book(
      snaps: {for (var week = 1; week <= 8; week++) week: 0.90},
      routes: {
        for (var week = 1; week <= 5; week++) week: 0.40,
        for (var week = 6; week <= 8; week++) week: 0.80,
      },
    );
    final move = book.move(
      playerId: 'wr',
      metric: 'receptions',
      team: 'HOU',
      position: 'WR',
      season: 2025,
      week: 9,
    );
    expect(move.factor, closeTo(playingTimeRoleCeil, 1e-9));
    expect(move.basis, PlayingTimeBasis.route);
    expect(move.routeUnavailable, isFalse);
  });

  test('a starter listed Out raises the teammate who is still playing', () {
    final book = _offense();
    final boosted = book.move(
      playerId: 'other',
      metric: 'receiving_yards',
      team: 'HOU',
      position: 'WR',
      season: 2025,
      week: 9,
    );
    expect(boosted.factor, greaterThan(1));
    expect(boosted.factor, lessThanOrEqualTo(playingTimeInjuryCeil));
    expect(boosted.detail, contains('Blake Wide'));
    expect(boosted.detail, contains('targets'));
    expect(boosted.detail, contains('shrunk'));

    final alreadyOut = book.move(
      playerId: 'other',
      metric: 'receiving_yards',
      team: 'HOU',
      position: 'WR',
      season: 2025,
      week: 10,
    );
    expect(alreadyOut.factor, 1);
  });

  test('a returning starter pulls the recent share back', () {
    final book = _offense(returning: true);
    final back = book.move(
      playerId: 'other',
      metric: 'receiving_yards',
      team: 'HOU',
      position: 'WR',
      season: 2025,
      week: 9,
    );
    expect(back.factor, lessThan(1));
    expect(back.factor, greaterThanOrEqualTo(playingTimeReturnFloor));
    expect(back.detail, contains('no longer listed Out'));
  });

  test('the other quarterback moves up when the starter is newly out', () {
    final book = _quarterbacks();
    final backup = book.move(
      playerId: 'backup',
      metric: 'passing_yards',
      team: 'HOU',
      position: 'QB',
      season: 2025,
      week: 9,
    );
    expect(backup.factor, greaterThan(1.5));
    expect(backup.factor, lessThanOrEqualTo(playingTimeQbCeil));
    expect(backup.detail, contains('Quinn Passer'));
    expect(backup.detail, contains('shrunk'));
    final starter = book.move(
      playerId: 'starter',
      metric: 'passing_yards',
      team: 'HOU',
      position: 'QB',
      season: 2025,
      week: 9,
    );
    expect(starter.factor, 1);
  });

  test('missing snap and route shares stay unavailable', () {
    final games = [
      for (var week = 1; week <= 8; week++)
        _game('wr', 'Alex Wide', 'WR', week, targets: 6),
    ];
    final book = PlayingTimeBook.build(
      games: games,
      shares: UsageBook.fromJson({
        'keys': ['id', 'season', 'week', 'snap', 'route'],
        'rows': <List<dynamic>>[],
      }),
      outs: const [],
    );
    final move = book.move(
      playerId: 'wr',
      metric: 'receiving_yards',
      team: 'HOU',
      position: 'WR',
      season: 2025,
      week: 9,
    );
    expect(move.factor, 1);
    expect(move.basis, PlayingTimeBasis.unavailable);
    expect(move.detail, contains('unavailable'));
  });

  test('walk-forward keeps playing time only when both seasons improve', () {
    final report = scorePlayingTime(
      players: _players(),
      scores: _history(),
      shares: UsageBook.fromJson(_json('assets/prop-usage.json')),
      outs: [
        for (final row in (_json('assets/nfl-outs.json')['outs'] as List))
          if (row is List) List<dynamic>.from(row),
      ],
    );
    // ignore: avoid_print
    print(report.text);
    expect(report.sameChance, greaterThan(1000));
    expect(report.current[2025]!.n, greaterThanOrEqualTo(1000));
    expect(report.current[2026]!.n, greaterThanOrEqualTo(1000));
    expect(report.playingTime[2025]!.n, report.current[2025]!.n);
    expect(report.playingTime[2026]!.n, report.current[2026]!.n);
    expect(playingTimeAdopted, report.beatsCurrent);
  }, timeout: const Timeout(Duration(minutes: 20)));
}

PlayingTimeBook _book({
  required Map<int, double> snaps,
  Map<int, double> routes = const {},
  double? laterSnap,
}) {
  final weeks = snaps.keys.toList()..sort();
  final games = [
    for (final week in weeks) _game('wr', 'Alex Wide', 'WR', week, targets: 6),
    if (laterSnap != null) _game('wr', 'Alex Wide', 'WR', 9, targets: 6),
  ];
  final rows = [
    for (final week in weeks)
      ['wr', 2025, week, 'WR', snaps[week], routes[week], null, null],
    if (laterSnap != null) ['wr', 2025, 9, 'WR', laterSnap, null, null, null],
  ];
  return PlayingTimeBook.build(
    games: [
      ...games,
      for (final week in {1, 2, 3, 4, 5, 6, 7, 8, if (laterSnap != null) 9})
        _game('qb', 'Quinn Passer', 'QB', week, attempts: 32),
    ],
    shares: _shares(rows),
    outs: const [],
  );
}

PlayingTimeBook _offense({bool returning = false}) {
  final games = <PlayerGame>[];
  final rows = <List<dynamic>>[];
  for (var week = 1; week <= 9; week++) {
    final starTargets = week == 8 && returning ? 0.0 : 10.0;
    final otherTargets = week == 8 && returning ? 10.0 : 4.0;
    if (week <= 8) {
      games.add(_game('star', 'Blake Wide', 'WR', week, targets: starTargets));
      rows.add(['star', 2025, week, 'WR', 0.85, 0.80, null, null]);
    }
    games.add(_game('other', 'Alex Wide', 'WR', week, targets: otherTargets));
    rows.add(['other', 2025, week, 'WR', 0.70, 0.55, null, null]);
    games.add(_game('qb', 'Quinn Passer', 'QB', week, attempts: 32));
    rows.add(['qb', 2025, week, 'QB', 0.98, null, null, null]);
  }
  if (!returning) {
    games.add(_game('other', 'Alex Wide', 'WR', 10, targets: 8));
    rows.add(['other', 2025, 10, 'WR', 0.70, 0.55, null, null]);
    games.add(_game('qb', 'Quinn Passer', 'QB', 10, attempts: 32));
  }
  final outs = returning
      ? [
          [2025, 8, 'HOU', 'Blake Wide', 'WR'],
        ]
      : [
          [2025, 9, 'HOU', 'Blake Wide', 'WR'],
          [2025, 10, 'HOU', 'Blake Wide', 'WR'],
        ];
  return PlayingTimeBook.build(games: games, shares: _shares(rows), outs: outs);
}

PlayingTimeBook _quarterbacks() {
  final games = <PlayerGame>[];
  final rows = <List<dynamic>>[];
  for (var week = 1; week <= 8; week++) {
    games.add(_game('starter', 'Quinn Passer', 'QB', week, attempts: 30));
    rows.add(['starter', 2025, week, 'QB', 0.95, null, null, null]);
    games.add(_game('backup', 'Sam Backup', 'QB', week, attempts: 2));
    rows.add(['backup', 2025, week, 'QB', 0.05, null, null, null]);
  }
  return PlayingTimeBook.build(
    games: games,
    shares: _shares(rows),
    outs: [
      [2025, 9, 'HOU', 'Quinn Passer', 'QB'],
    ],
  );
}

UsageBook _shares(List<List<dynamic>> rows) {
  return UsageBook.fromJson({
    'keys': ['id', 'season', 'week', 'position', 'snap', 'route', 'air', 'rz'],
    'rows': rows,
  });
}

PlayerGame _game(
  String id,
  String name,
  String position,
  int week, {
  double targets = 0,
  double attempts = 0,
  double carries = 0,
}) {
  return PlayerGame(
    playerId: id,
    name: name,
    position: position,
    team: 'HOU',
    opponent: 'IND',
    season: 2025,
    week: week,
    date: DateTime.utc(2025, 9, week.clamp(1, 28)),
    seasonType: 'REG',
    stats: {
      'targets': targets,
      'carries': carries,
      'attempts': attempts,
      'receiving_yards': targets * 8,
      'passing_yards': attempts * 7,
      'rushing_yards': carries * 4,
      'receptions': targets * 0.65,
    },
  );
}

List<PlayerGame> _players() {
  return PlayerStatsDataset.fromJson(_json('assets/nfl-player-stats.json'))
      .rows;
}

List<HistoricalGame> _history() {
  final games = _json('assets/nfl-history.json')['games'];
  if (games is! List) return const [];
  return [
    for (final row in games)
      if (row is Map) HistoricalGame.fromJson(Map<String, dynamic>.from(row)),
  ];
}

Map<String, dynamic> _json(String path) {
  return jsonDecode(File(path).readAsStringSync().replaceFirst('\uFEFF', ''))
      as Map<String, dynamic>;
}
