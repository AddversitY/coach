import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/coach/prop_detail_screen.dart';
import 'package:odds_edge/data/demo.dart';
import 'package:odds_edge/domain/coach_board.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/prop_history.dart';
import 'package:odds_edge/domain/research_changes.dart';
import 'package:odds_edge/theme/edge_theme.dart';
import 'package:odds_edge/ui/research_changes.dart';

void main() {
  final now = DateTime.utc(2026, 11, 15, 12);
  Map<String, dynamic> metadata() => {
    'currentSeason': 2026,
    'cutoff': '2026-11-09',
    'retrievedAt': '2026-11-13T02:00:00Z',
  };
  PlayerGame game(
    int index, {
    String name = 'Example Receiver',
    String team = 'LA',
    String seasonType = 'REG',
    int season = 2026,
    DateTime? date,
    num? targets,
    bool missingTarget = false,
    num? receivingYards,
  }) => PlayerGame(
    playerId: 'player-1',
    name: name,
    position: 'WR',
    team: team,
    opponent: 'SEA',
    season: season,
    week: 10 - index,
    date: date ?? DateTime.utc(2026, 11, 9).subtract(Duration(days: index * 7)),
    seasonType: seasonType,
    stats: {
      'targets': missingTarget ? null : targets ?? (index < 3 ? 9 : 6),
      'receiving_yards': receivingYards ?? (index < 3 ? 90 : 60),
      'receptions': index < 3 ? 7 : 4,
      'carries': index < 3 ? 3 : 1,
      'rushing_yards': index < 3 ? 21 : 6,
      'attempts': index < 3 ? 35 : 28,
      'passing_yards': index < 3 ? 280 : 210,
    },
  );
  List<PlayerGame> rows() => List.generate(6, game);
  List<ResearchChange> compare({
    List<PlayerGame>? records,
    Map<String, dynamic>? meta,
    DateTime? at,
    DateTime? eventAt,
    String market = 'player_reception_yds',
    Set<String> teams = const {'Los Angeles Rams', 'Seattle Seahawks'},
  }) => recentResearchChanges(
    data: PlayerStatsDataset(
      rows: records ?? rows(),
      metadata: meta ?? metadata(),
    ),
    playerId: 'player-1',
    market: market,
    team: 'LAR',
    now: at ?? now,
    eventAt: eventAt,
    eventTeams: teams,
  );

  test(
    'compares disjoint fixed three-game windows with dates and team aliases',
    () {
      final changes = compare();
      expect(changes.map((change) => change.metric), [
        'targets',
        'receiving_yards',
      ]);
      expect(changes.first.recentAverage, 9);
      expect(changes.first.previousAverage, 6);
      expect(changes.first.recentDates, [
        DateTime.utc(2026, 11, 9),
        DateTime.utc(2026, 11, 2),
        DateTime.utc(2026, 10, 26),
      ]);
      expect(changes.first.previousDates.length, 3);
      expect(changes.first.previousDates.first, DateTime.utc(2026, 10, 19));
      expect(changes.first.summary, contains('last 3 recorded games'));
    },
  );

  test('selects workload appropriate to each supported prop', () {
    expect(compare(market: 'player_pass_yds').first.metric, 'attempts');
    expect(compare(market: 'player_rush_yds').first.metric, 'carries');
    expect(compare(market: 'player_receptions').first.metric, 'targets');
    expect(compare(market: 'unknown'), isEmpty);
  });

  test('missing metrics do not become zero or reach for an older game', () {
    final records = rows()..[0] = game(0, missingTarget: true);
    records.add(game(6));
    final changes = compare(records: records);
    expect(changes.map((change) => change.metric), ['receiving_yards']);
    expect(compare(records: rows().take(5).toList()), isEmpty);
  });

  test('zeroes are valid observations and nonfinite values are omitted', () {
    final records = List.generate(6, (i) => game(i, targets: i < 3 ? 0 : 6));
    expect(compare(records: records).first.recentAverage, 0);
    records[0] = game(0, targets: double.nan);
    expect(compare(records: records).map((change) => change.metric), [
      'receiving_yards',
    ]);
  });

  test('does not bridge a trade, a postseason boundary or a season', () {
    final trade = rows()..[2] = game(2, team: 'BUF');
    expect(compare(records: trade), isEmpty);
    final post = rows()..[2] = game(2, seasonType: 'POST');
    expect(compare(records: post), isEmpty);
    final priorSeason = rows()..[2] = game(2, season: 2025);
    expect(compare(records: priorSeason), isEmpty);
    expect(compare(teams: {'Buffalo Bills', 'Seattle Seahawks'}), isEmpty);
  });

  test('rejects unknown, malformed, future and stale source metadata', () {
    for (final meta in [
      metadata()..remove('cutoff'),
      metadata()..remove('retrievedAt'),
      metadata()..['cutoff'] = '2026-02-31',
      metadata()..['retrievedAt'] = '2026-11-13T02:00:00',
      metadata()..['retrievedAt'] = '2026-11-01T02:00:00Z',
      metadata()..['retrievedAt'] = '2026-11-16T02:00:00Z',
      metadata()..['cutoff'] = '2026-11-16',
      metadata()..['cutoff'] = '2026-10-20',
      metadata()..['currentSeason'] = 2025,
      metadata()..['currentSeason'] = '2026',
    ]) {
      expect(compare(meta: meta), isEmpty, reason: '$meta');
    }
  });

  test(
    'expires when player coverage is old despite a freshly retrieved dataset',
    () {
      final records = List.generate(
        6,
        (i) => game(
          i,
          date: DateTime.utc(2026, 10, 20).subtract(Duration(days: 7 * i)),
        ),
      );
      expect(compare(records: records), isEmpty);
      expect(compare(at: DateTime.utc(2026, 11, 30, 12)), hasLength(2));
      expect(compare(at: DateTime.utc(2026, 12, 1, 12)), isEmpty);
    },
  );

  test(
    'excludes actual research day and future records on Eastern calendar',
    () {
      // 00:30 UTC Monday is still Sunday in Eastern time.
      final at = DateTime.utc(2026, 11, 16, 0, 30);
      final records = rows()
        ..add(game(-1, date: DateTime.utc(2026, 11, 15), targets: 99))
        ..add(game(-2, date: DateTime.utc(2026, 11, 16), targets: 99));
      final changes = compare(
        records: records,
        at: at,
        meta: metadata()
          ..['cutoff'] = '2026-11-15'
          ..['retrievedAt'] = '2026-11-16T00:00:00Z',
      );
      expect(changes.first.latestGame, DateTime.utc(2026, 11, 9));
      expect(changes.first.recentAverage, 9);
    },
  );

  test(
    'excludes selected event day even when it is earlier than actual now',
    () {
      expect(compare(eventAt: DateTime.utc(2026, 11, 9, 1)), isEmpty);
      final records = rows()..add(game(6));
      final changes = compare(
        records: records,
        eventAt: DateTime.utc(2026, 11, 9, 1),
      );
      expect(changes.first.latestGame, DateTime.utc(2026, 11, 2));
    },
  );

  test('omits rounded-flat comparisons instead of creating activity', () {
    final records = List.generate(
      6,
      (i) => game(i, targets: 6, receivingYards: 60),
    );
    expect(compare(records: records), isEmpty);
  });

  test('keeps January games in the preceding NFL season', () {
    final records = List.generate(
      6,
      (i) => game(
        i,
        date: DateTime.utc(2027, 1, 10).subtract(Duration(days: i * 7)),
      ),
    );
    final meta = metadata()
      ..['cutoff'] = '2027-01-10'
      ..['retrievedAt'] = '2027-01-11T12:00:00Z';
    expect(
      compare(records: records, meta: meta, at: DateTime.utc(2027, 1, 15, 12)),
      hasLength(2),
    );
  });

  test(
    'duplicate game dates and unknown clubs cannot support a comparison',
    () {
      final duplicateDates = rows()
        ..[2] = game(2, date: DateTime.utc(2026, 11, 2));
      expect(compare(records: duplicateDates), isEmpty);
      expect(
        recentResearchChanges(
          data: PlayerStatsDataset(
            rows: List.generate(6, (i) => game(i, team: 'Unknown')),
            metadata: metadata(),
          ),
          playerId: 'player-1',
          market: 'player_reception_yds',
          team: 'Unknown',
          now: now,
        ),
        isEmpty,
      );
    },
  );

  testWidgets('phone card wraps at 1.8 text scale and discloses window dates', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: edgeTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ResearchChangesCard(changes: compare()),
            ),
          ),
        ),
      ),
    );
    expect(find.text('What changed'), findsOneWidget);
    expect(find.textContaining('not a forecast'), findsNothing);
    await tester.ensureVisible(find.text('Compare the windows'));
    await tester.tap(find.text('Compare the windows'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.textContaining('not a forecast'));
    expect(find.text('Last 3: 2026-10-26 – 2026-11-09'), findsOneWidget);
    expect(find.text('Previous 3: 2026-10-05 – 2026-10-19'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('matched prop detail includes the dated comparison', (
    tester,
  ) async {
    final board = demoBoard(now);
    final cards = propCards(board, now);
    final card = cards.firstWhere(
      (card) =>
          card.player == 'CeeDee Lamb' && card.market == 'player_reception_yds',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: edgeTheme(),
        home: PropDetailScreen(
          card: card,
          cards: cards,
          board: board,
          now: now,
          directory: PlayerDirectory(
            PlayerStatsDataset(
              metadata: metadata(),
              rows: List.generate(
                6,
                (i) => game(i, name: 'CeeDee Lamb', team: 'DAL'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('What changed'), 250);
    expect(find.byKey(const Key('research-changes')), findsOneWidget);
    expect(find.textContaining('Targets averaged 9.0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
