import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/coach/game_research_screen.dart';
import 'package:odds_edge/coach/games_screen.dart';
import 'package:odds_edge/coach/player_research_screen.dart';
import 'package:odds_edge/domain/game_research.dart';
import 'package:odds_edge/domain/matchup.dart';
import 'package:odds_edge/domain/odds.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/theme/edge_theme.dart';

final now = DateTime.utc(2026, 11, 15, 15);
final event = SportEvent(
  'actual-game',
  'Buffalo Bills',
  'Kansas City Chiefs',
  DateTime.utc(2026, 11, 16, 20),
);

PlayerGame recorded({
  String id = 'qb-1',
  String name = 'Recorded Quarterback',
  String team = 'BUF',
  String position = 'QB',
  int week = 10,
  String date = '2026-11-08',
  int season = 2026,
  Map<String, num?> stats = const {
    'passing_yards': 250,
    'attempts': 30,
    'rushing_yards': 15,
  },
}) => PlayerGame(
  playerId: id,
  name: name,
  position: position,
  team: team,
  opponent: 'KC',
  season: season,
  week: week,
  date: DateTime.parse('${date}T00:00:00Z'),
  seasonType: 'REG',
  stats: stats,
);

PlayerStatsDataset dataWith(
  List<PlayerGame> rows, {
  String cutoff = '2026-11-12',
  String retrieved = '2026-11-15T10:00:00Z',
  int season = 2026,
}) => PlayerStatsDataset(
  rows: rows,
  metadata: {
    'currentSeason': season,
    'cutoff': cutoff,
    'retrievedAt': retrieved,
  },
);

PlayerStatsDataset fixtureData() => dataWith([
  for (final (index, day) in [
    '2026-09-27',
    '2026-10-04',
    '2026-10-11',
    '2026-10-18',
    '2026-11-01',
    '2026-11-08',
  ].indexed)
    recorded(
      week: index + 5,
      date: day,
      stats: {
        'passing_yards': 180 + index * 20,
        'attempts': 20 + index * 3,
        'rushing_yards': index == 0 ? -2 : index * 4,
      },
    ),
  recorded(
    id: 'wr-1',
    name: 'Recorded Receiver',
    team: 'KC',
    position: 'WR',
    stats: const {'receiving_yards': 90, 'receptions': 6, 'targets': 10},
  ),
]);

final emptyMatchup = MatchupContext(
  injuries: const [],
  snaps: const [],
  note: 'Stored context',
);

void main() {
  test('actual teams open recorded skill players without any quote', () {
    final research = buildGameResearch(
      data: fixtureData(),
      event: event,
      now: now,
    );
    expect(research.players.map((player) => player.id), ['qb-1', 'wr-1']);
    expect(research.through, DateTime.utc(2026, 11, 12));
    expect(research.players.first.games.length, 6);
  });

  test('newest permitted club excludes traded players from their old game', () {
    final data = dataWith([
      recorded(id: 'traded', week: 9, date: '2026-11-01'),
      recorded(id: 'traded', week: 10, team: 'DAL'),
      recorded(id: 'future', week: 9, date: '2026-11-01'),
      recorded(id: 'future', week: 12, team: 'DAL', date: '2026-11-22'),
    ]);
    final research = buildGameResearch(data: data, event: event, now: now);
    expect(research.players.map((p) => p.id), ['future']);
  });

  test('past event and actual Eastern day both exclude same-day records', () {
    final data = dataWith([
      recorded(week: 8, date: '2026-10-25'),
      recorded(week: 9, date: '2026-11-01'),
    ]);
    final past = SportEvent(
      event.id,
      event.away,
      event.home,
      DateTime.utc(2026, 11, 2, 1),
    );
    final research = buildGameResearch(data: data, event: past, now: now);
    expect(research.through, DateTime.utc(2026, 10, 31));
    expect(research.players.single.latest.date, DateTime.utc(2026, 10, 25));
    final todayData = dataWith([
      recorded(week: 11, date: '2026-11-15'),
      recorded(),
    ], cutoff: '2026-11-15');
    expect(
      buildGameResearch(
        data: todayData,
        event: event,
        now: now,
      ).players.single.latest.date,
      DateTime.utc(2026, 11, 8),
    );
  });

  test('current-club games stop at a trade and do not pad the averages', () {
    final data = dataWith([
      recorded(week: 10),
      recorded(week: 9, date: '2026-11-01', team: 'DAL'),
      recorded(week: 8, date: '2026-10-25'),
    ]);
    expect(
      buildGameResearch(
        data: data,
        event: event,
        now: now,
      ).players.single.games,
      hasLength(1),
    );
  });

  test('unknown or future provenance cannot become game participants', () {
    for (final data in [
      PlayerStatsDataset(rows: [recorded()]),
      dataWith([recorded()], cutoff: '2026-11-16'),
      dataWith([recorded()], retrieved: '2026-11-16T10:00:00Z'),
      dataWith(
        [recorded()],
        cutoff: '2026-11-12',
        retrieved: '2026-11-10T10:00:00Z',
      ),
    ]) {
      expect(
        buildGameResearch(data: data, event: event, now: now).players,
        isEmpty,
      );
    }
  });

  test('stale evidence is labeled historical and old appearances expire', () {
    final research = buildGameResearch(
      data: dataWith([recorded(date: '2026-10-18')], cutoff: '2026-10-22'),
      event: event,
      now: now,
    );
    expect(research.stale, isTrue);
    expect(research.notice, contains('historical'));
    expect(research.players, hasLength(1));
    final tooOld = buildGameResearch(
      data: dataWith([recorded(date: '2026-10-04')], cutoff: '2026-10-04'),
      event: event,
      now: now,
    );
    expect(tooOld.players, isEmpty);
  });

  test(
    'another season, unknown clubs and ambiguous latest days stay absent',
    () {
      expect(
        buildGameResearch(
          data: dataWith([recorded(season: 2025)], season: 2025),
          event: event,
          now: now,
        ).players,
        isEmpty,
      );
      final data = dataWith([recorded(week: 9), recorded(week: 10)]);
      expect(
        buildGameResearch(data: data, event: event, now: now).players,
        isEmpty,
      );
      final bad = SportEvent(
        event.id,
        'Unknown team',
        event.home,
        event.startsAt,
      );
      expect(
        buildGameResearch(data: fixtureData(), event: bad, now: now).players,
        isEmpty,
      );
    },
  );

  test('averages preserve zero and skip missing records', () {
    final games = [
      recorded(stats: const {'passing_yards': 0}),
      recorded(id: 'another', stats: const {'passing_yards': null}),
    ];
    expect(researchAverage(games, 'passing_yards'), 0);
    expect(researchAverage(games, 'receptions'), isNull);
  });

  testWidgets('actual GamesScreen opens price-independent player research', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: edgeTheme(),
        home: Scaffold(
          body: GamesScreen(
            board: OddsBoard(events: [event], quotes: const [], fetchedAt: now),
            now: now,
            loadResearchPlayers: () async => fixtureData(),
            loadResearchMatchup: () async => emptyMatchup,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Buffalo Bills'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('game-research')), findsOneWidget);
    expect(
      find.text('Recent recorded participants · not a confirmed roster'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('game-research-player-qb-1')),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('game-research')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.byKey(const ValueKey('game-research-player-qb-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-research')), findsOneWidget);
    expect(find.text('Recorded Quarterback'), findsOneWidget);
    expect(find.text('Add to parlay'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search and actual-team filters use recorded participants', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: edgeTheme(),
        home: GameResearchScreen(
          event: event,
          now: now,
          loadPlayers: () async => fixtureData(),
          loadMatchup: () async => emptyMatchup,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('research-team-KC')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('game-research-player-qb-1')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const Key('game-player-search')),
      'Nobody',
    );
    await tester.pumpAndSettle();
    expect(find.text('No players match these filters.'), findsOneWidget);
  });

  testWidgets('missing player history has a useful empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: edgeTheme(),
        home: GameResearchScreen(
          event: event,
          now: now,
          loadPlayers: () async => dataWith([]),
          loadMatchup: () async => emptyMatchup,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('No recent player records match this game.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'embedded game changes clear incompatible search and team filters',
    (tester) async {
      Future<PlayerStatsDataset> load() async => fixtureData();
      Future<MatchupContext> context() async => emptyMatchup;
      Widget frame(SportEvent game) => MaterialApp(
        theme: edgeTheme(),
        home: GameResearchScreen(
          event: game,
          now: now,
          embedded: true,
          loadPlayers: load,
          loadMatchup: context,
        ),
      );
      await tester.pumpWidget(frame(event));
      await tester.pumpAndSettle();
      expect(find.text('Game research'), findsNothing);
      expect(find.text('Players'), findsNothing);
      expect(find.text(event.away), findsNothing);
      await tester.tap(find.byKey(const ValueKey('research-team-BUF')));
      await tester.enterText(
        find.byKey(const Key('game-player-search')),
        'Quarterback',
      );
      await tester.pumpAndSettle();
      final other = SportEvent(
        'another-game',
        'Dallas Cowboys',
        event.home,
        event.startsAt,
      );
      await tester.pumpWidget(frame(other));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('game-player-search')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        find.byKey(const ValueKey('game-research-player-wr-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('game-research-player-qb-1')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('player research and chart fit phone text at 1.8 scale', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = fixtureData();
    final player = buildGameResearch(
      data: data,
      event: event,
      now: now,
    ).players.first;
    await tester.pumpWidget(
      MaterialApp(
        theme: edgeTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
          child: PlayerResearchScreen(
            event: event,
            now: now,
            data: data,
            player: player,
            matchup: emptyMatchup,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Recent production'),
      250,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('player-research')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('What changed'),
      250,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('player-research')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('What changed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('game participant rows and filters fit enlarged phone text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: edgeTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
          child: GameResearchScreen(
            event: event,
            now: now,
            loadPlayers: () async => fixtureData(),
            loadMatchup: () async => emptyMatchup,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('game-research-player-qb-1')),
      250,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('game-research')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'saved prices require stable identity, exact selection and bounded age',
    (tester) async {
      final data = fixtureData();
      final player = buildGameResearch(
        data: data,
        event: event,
        now: now,
      ).players.first;
      OddsQuote quote({
        String id = 'book',
        String market = 'player_pass_yds',
        DateTime? at,
      }) => OddsQuote(
        selection: Selection(
          eventId: event.id,
          market: market,
          participant: player.name,
          outcome: 'Over',
          point: 245.5,
        ),
        bookId: id,
        book: 'Research Book',
        provider: 'provider',
        decimal: 1.91,
        sourceAt: at ?? now,
        collectedAt: at ?? now,
      );
      Future<void> frame(Map<String, String> mapping) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: edgeTheme(),
            home: PlayerResearchScreen(
              event: event,
              now: now,
              data: data,
              player: player,
              priceBoard: OddsBoard(
                events: [event],
                fetchedAt: now,
                quotes: [
                  quote(),
                  quote(
                    id: 'stale',
                    at: now.subtract(const Duration(hours: 19)),
                  ),
                  quote(id: 'other', market: 'player_rush_yds'),
                  quote(id: 'future', at: now.add(const Duration(minutes: 1))),
                ],
              ),
              quotePlayerIds: mapping,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text(mapping.isEmpty ? 'Prices unavailable' : 'Saved prices'),
          250,
          scrollable: find
              .descendant(
                of: find.byKey(const Key('player-research')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
      }

      await frame({});
      expect(find.byKey(const Key('research-prices')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await frame({player.name: player.id});
      expect(find.byKey(const Key('research-prices')), findsOneWidget);
      expect(find.text('1 book · source timestamps below'), findsOneWidget);
      expect(
        find.text('Pregame snapshots · settlement rules unverified'),
        findsOneWidget,
      );
      await tester.pump(const Duration(minutes: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('research-prices')), findsOneWidget);
      expect(find.textContaining('Highest saved price'), findsOneWidget);
      expect(find.textContaining('Older snapshot'), findsOneWidget);
      await Scrollable.ensureVisible(
        tester.element(find.text('Over 245.5')),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Over 245.5'));
      await tester.pumpAndSettle();
      expect(find.textContaining('outdated snapshot'), findsOneWidget);
      expect(find.textContaining('may have changed'), findsOneWidget);
      await tester.pump(const Duration(hours: 19));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('research-prices')), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Prices unavailable'),
        -250,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('player-research')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Prices unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('five-minute snapshots are disclosed and disappear at kickoff', (
    tester,
  ) async {
    final data = fixtureData();
    final soon = SportEvent(
      event.id,
      event.away,
      event.home,
      now.add(const Duration(seconds: 30)),
    );
    final player = buildGameResearch(
      data: data,
      event: soon,
      now: now,
    ).players.first;
    final checked = now.subtract(const Duration(minutes: 5));
    final quote = OddsQuote(
      selection: Selection(
        eventId: event.id,
        market: 'player_pass_yds',
        participant: player.name,
        outcome: 'Over',
        point: 245.5,
      ),
      bookId: 'saved',
      book: 'Saved Book',
      provider: 'provider',
      decimal: 1.91,
      sourceAt: checked,
      collectedAt: checked,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: edgeTheme(),
        home: PlayerResearchScreen(
          event: soon,
          now: now,
          data: data,
          player: player,
          priceBoard: OddsBoard(
            events: [soon],
            quotes: [quote],
            fetchedAt: checked,
          ),
          quotePlayerIds: {player.name: player.id},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Saved prices'),
      250,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('player-research')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      find.textContaining('Highest saved price · checked 5m ago'),
      findsOneWidget,
    );
    expect(find.textContaining('Older snapshot'), findsOneWidget);
    await Scrollable.ensureVisible(
      tester.element(find.text('Over 245.5')),
      alignment: .5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Over 245.5'));
    await tester.pumpAndSettle();
    expect(find.textContaining('outdated snapshot'), findsOneWidget);
    expect(find.textContaining('may have changed'), findsOneWidget);
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('research-prices')), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Prices unavailable'),
      -250,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('player-research')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Prices unavailable'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
