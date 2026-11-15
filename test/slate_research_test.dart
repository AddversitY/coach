import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/coach/game_research_screen.dart';
import 'package:odds_edge/coach/player_research_screen.dart';
import 'package:odds_edge/coach/slate_research_screen.dart';
import 'package:odds_edge/domain/matchup.dart';
import 'package:odds_edge/domain/odds.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/theme/edge_theme.dart';

void main() {
  final now = DateTime.utc(2026, 11, 15, 12);
  final events = [
    SportEvent(
      'expired',
      'Chicago Bears',
      'Green Bay Packers',
      DateTime.utc(2026, 11, 14, 18),
    ),
    SportEvent(
      'buf-kc',
      'Buffalo Bills',
      'Kansas City Chiefs',
      DateTime.utc(2026, 11, 15, 18),
    ),
    SportEvent(
      'dal-phi',
      'Dallas Cowboys',
      'Philadelphia Eagles',
      DateTime.utc(2026, 11, 16, 1, 20),
    ),
    SportEvent(
      'gb-det',
      'Green Bay Packers',
      'Detroit Lions',
      DateTime.utc(2026, 11, 16, 18),
    ),
  ];
  final data = _fixture();
  const context = MatchupContext(
    injuries: [],
    snaps: [],
    note: 'Stored context',
    season: 2026,
  );

  Widget frame({
    List<SportEvent>? games,
    DateTime? at,
    double scale = 1,
    Future<PlayerStatsDataset> Function()? load,
  }) => MaterialApp(
    theme: edgeTheme(),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: SlateResearchScreen(
          board: OddsBoard(
            events: games ?? events,
            quotes: const [],
            fetchedAt: at ?? now,
            demo: false,
          ),
          now: at ?? now,
          loadPlayers: load ?? () async => data,
          loadMatchup: () async => context,
        ),
      ),
    ),
  );

  Finder gameScroll() => find
      .descendant(
        of: find.byKey(const Key('game-research')),
        matching: find.byType(Scrollable),
      )
      .first;

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(target, 250, scrollable: gameScroll());
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, String id, String label) async {
    final picker = find.byKey(ValueKey('research-game-picker-$id'));
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'actual schedule opens the selected stable player ID without sample prices',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(frame());
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<GameResearchScreen>(find.byType(GameResearchScreen))
            .event
            .id,
        'buf-kc',
      );
      expect(
        find.byKey(const ValueKey('research-game-picker-expired')),
        findsNothing,
      );
      expect(find.text('Sample props'), findsNothing);
      expect(find.text('EXAMPLE'), findsNothing);

      // The two opposing players deliberately share a display name.
      final receiver = find.byKey(const ValueKey('game-research-player-kc-wr'));
      await reveal(tester, receiver);
      await tester.tap(receiver);
      await tester.pumpAndSettle();
      final opened = tester.widget<PlayerResearchScreen>(
        find.byType(PlayerResearchScreen),
      );
      expect(opened.player.id, 'kc-wr');
      expect(opened.player.team, 'KC');
      expect(opened.event.id, 'buf-kc');
      expect(opened.priceBoard, isNull);
      expect(find.byKey(const Key('player-research')), findsOneWidget);
      expect(find.text('Sample props'), findsNothing);
      expect(find.text('EXAMPLE'), findsNothing);

      await tester.scrollUntilVisible(
        find.byKey(const Key('research-prices-unavailable')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Prices unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changing the game resets search, team and position filters', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(frame());
    await tester.pumpAndSettle();
    final search = find.byKey(const Key('game-player-search'));
    await reveal(tester, search);
    await tester.enterText(search, 'Taylor');
    await tester.tap(find.byKey(const ValueKey('research-team-BUF')));
    await tester.tap(find.widgetWithText(FilterChip, 'QB'));
    await tester.pumpAndSettle();
    await reveal(
      tester,
      find.byKey(const ValueKey('game-research-player-buf-qb')),
    );
    expect(
      find.byKey(const ValueKey('game-research-player-kc-wr')),
      findsNothing,
    );

    await pick(tester, 'buf-kc', 'DAL at PHI');
    expect(
      tester
          .widget<GameResearchScreen>(find.byType(GameResearchScreen))
          .event
          .id,
      'dal-phi',
    );
    await reveal(tester, find.byKey(const Key('game-player-search')));
    final editable = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('game-player-search')),
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.controller.text, isEmpty);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('research-team-All')))
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'All positions'))
          .selected,
      isTrue,
    );
    expect(find.byKey(const ValueKey('research-team-BUF')), findsNothing);
    expect(find.byKey(const ValueKey('research-team-DAL')), findsOneWidget);
    await reveal(
      tester,
      find.byKey(const ValueKey('game-research-player-phi-rb')),
    );
    expect(
      find.byKey(const ValueKey('game-research-player-phi-rb')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('game-research-player-kc-wr')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an expired selected game falls back to the next kickoff and then a truthful empty state',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(frame());
      await tester.pumpAndSettle();
      await pick(tester, 'buf-kc', 'DAL at PHI');
      await tester.pumpWidget(frame(at: DateTime.utc(2026, 11, 16, 2)));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('research-game-picker-gb-det')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<GameResearchScreen>(find.byType(GameResearchScreen))
            .event
            .id,
        'gb-det',
      );
      await tester.pumpWidget(frame(at: DateTime.utc(2026, 11, 16, 19)));
      await tester.pumpAndSettle();
      expect(find.text('No upcoming games in this schedule.'), findsOneWidget);
      expect(find.byType(GameResearchScreen), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.text('EXAMPLE'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty schedule does not load or invent player evidence', (
    tester,
  ) async {
    var loads = 0;
    await tester.pumpWidget(
      frame(
        games: [],
        load: () async {
          loads++;
          return data;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(loads, 0);
    expect(find.text('No upcoming games in this schedule.'), findsOneWidget);
    expect(find.byType(PlayerResearchScreen), findsNothing);
    expect(find.text('Prices unavailable'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('390px research remains navigable at 1.8 text scale', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(frame(scale: 1.8));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('game-research-player-buf-qb'));
    await reveal(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-research')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('research-prices-unavailable')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Prices unavailable'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Recorded games'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Recorded games'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

PlayerStatsDataset _fixture() {
  const dates = [
    '2026-10-04',
    '2026-10-11',
    '2026-10-18',
    '2026-11-01',
    '2026-11-08',
    '2026-11-12',
  ];
  const players = [
    ('buf-qb', 'Taylor Example', 'BUF', 'QB'),
    ('kc-wr', 'Taylor Example', 'KC', 'WR'),
    ('dal-wr', 'Dallas Receiver', 'DAL', 'WR'),
    ('phi-rb', 'Philadelphia Runner', 'PHI', 'RB'),
    ('gb-qb', 'Green Bay Quarterback', 'GB', 'QB'),
    ('det-te', 'Detroit Tight End', 'DET', 'TE'),
  ];
  return PlayerStatsDataset(
    rows: [
      for (final player in players)
        for (final (index, day) in dates.indexed)
          PlayerGame(
            playerId: player.$1,
            name: player.$2,
            team: player.$3,
            position: player.$4,
            opponent: 'MIA',
            season: 2026,
            week: index + 5,
            date: DateTime.parse('${day}T00:00:00Z'),
            seasonType: 'REG',
            stats: {
              'passing_yards': 180 + index * 10,
              'attempts': 20 + index,
              'rushing_yards': 20 + index,
              'carries': 8 + index,
              'receiving_yards': 40 + index * 7,
              'targets': 4 + index,
              'receptions': 2 + index,
            },
          ),
    ],
    metadata: const {
      'currentSeason': 2026,
      'cutoff': '2026-11-12',
      'retrievedAt': '2026-11-13T12:00:00Z',
    },
  );
}
