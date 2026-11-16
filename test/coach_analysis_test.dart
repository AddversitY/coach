import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/coach_analysis.dart';
import 'package:odds_edge/domain/coach_telemetry.dart';
import 'package:odds_edge/domain/game_research.dart';
import 'package:odds_edge/domain/history.dart';
import 'package:odds_edge/domain/odds.dart';

import 'game_research_test.dart' show recorded, dataWith, event, now;

void main() {
  final current = [
    for (var i = 0; i < 6; i++) ...[
      recorded(
        week: i + 4,
        date: '2026-10-${(i * 3 + 1).toString().padLeft(2, '0')}',
        stats: {'passing_yards': 200 + i * 20, 'attempts': 30 + i},
      ),
      recorded(
        id: 'wr-1',
        name: 'Recorded Receiver',
        team: 'KC',
        position: 'WR',
        week: i + 4,
        date: '2026-10-${(i * 3 + 1).toString().padLeft(2, '0')}',
        stats: {'receiving_yards': 40 + i * 10, 'targets': 5 + i},
      ),
    ],
    recorded(week: 10, stats: const {'passing_yards': 260, 'attempts': 34}),
    recorded(
      id: 'wr-1',
      name: 'Recorded Receiver',
      team: 'KC',
      position: 'WR',
      week: 10,
      stats: const {'receiving_yards': 90, 'targets': 9},
    ),
  ];
  final old = [
    for (var i = 0; i < 18; i++) ...[
      recorded(
        season: 2025,
        week: i + 1,
        date: '2025-09-${(i + 1).toString().padLeft(2, '0')}',
        stats: {'passing_yards': 180 + i * 8, 'attempts': 30},
      ),
      recorded(
        id: 'wr-1',
        name: 'Recorded Receiver',
        team: 'KC',
        position: 'WR',
        season: 2025,
        week: i + 1,
        date: '2025-09-${(i + 1).toString().padLeft(2, '0')}',
        stats: {'receiving_yards': 30 + i * 3, 'targets': 6},
      ),
    ],
  ];
  final data = dataWith([...old, ...current]);
  final scores = [
    for (var i = 0; i < 18; i++)
      HistoricalGame(
        season: 2025,
        week: i + 1,
        date: DateTime.utc(2025, 9, i + 1),
        home: 'BUF',
        away: 'KC',
        homeScore: 20 + i,
        awayScore: 17,
      ),
  ];
  final board = OddsBoard(events: [event], quotes: const [], fetchedAt: now);
  const engine = CoachAnalysisEngine();
  final validation = <String, dynamic>{
    'uniqueGames': 628,
    'adopted': false,
    'hasEdge': false,
  };
  final question =
      'Recorded Quarterback over 245.5 passing yards and Recorded Receiver over 65.5 receiving yards';
  List<AnalysisLeg> legs() =>
      engine.parse(question, board: board, data: data, now: now);
  CoachAnalysis run({bool stress = false}) => engine.run(
    legs: legs(),
    prices: board,
    data: data,
    scores: scores,
    validation: validation,
    now: now,
    stress: stress,
  );

  test('joint tool uses actual copula, seeded draws, and never claims a validated edge', () {
    final result = run();
    expect(result.simulation!.draws, 10000);
    expect(result.simulation!.joint, inInclusiveRange(0, 1));
    expect(result.simulation!.training.single.beforeSeason, 2026);
    expect(result.toEvidence()['hasEdge'], false);
    expect(result.toEvidence()['experimental'], true);
    expect(result.conditionalEv, isNull);
    expect(run().simulation!.joint, result.simulation!.joint);
  });
  test('whole-number pushes, duplicate exposures and unspecified markets fail closed', () {
    expect(
      () => engine.parse(
        question.replaceFirst('245.5', '245'),
        board: board,
        data: data,
        now: now,
      ),
      throwsArgumentError,
    );
    expect(
      () => engine.parse(
        'Recorded Quarterback over 245.5',
        board: board,
        data: data,
        now: now,
      ),
      throwsArgumentError,
    );
    expect(
      () => engine.parse(
        '$question and Recorded Quarterback over 245.5 passing yards',
        board: board,
        data: data,
        now: now,
      ),
      throwsArgumentError,
    );
  });
  test('stress grid includes adverse shocks on both over and under; quote is never synthesized', () {
    final result = run(stress: true);
    expect(result.rows, hasLength(9));
    final chances = result.rows.map((r) => r['chance'] as double).toList();
    expect(chances.reduce((a, b) => a < b ? a : b), lessThan(chances.first));
    expect(result.ticketPrice, isNull);
    final conditional = engine.run(
      legs: legs(),
      prices: board,
      data: data,
      scores: scores,
      validation: validation,
      now: now,
      ticketPrice: 3.5,
    );
    expect(conditional.conditionalEv, isNotNull);
    expect(conditional.toEvidence()['hasEdge'], false);
  });
  test('bounded optimizer ranks worst-case consistency rather than headline payout', () {
    final p = buildGameResearch(
      data: data,
      event: event,
      now: now,
    ).players.first;
    final safer = AnalysisLeg(
      player: p,
      event: event,
      metric: passingResearch,
      line: 100.5,
      over: true,
    );
    final ranking = engine.rank(
      candidates: [
        [legs().first],
        [safer],
      ],
      prices: board,
      data: data,
      scores: scores,
      validation: validation,
      now: now,
    );
    expect(ranking.first.legs.single.line, 100.5);
    expect(ranking.first.rows.length, 9);
  });
  test('changed prices, scratch reports, stale feeds and kickoff invalidate old results', () {
    final result = run();
    final price = OddsQuote(
      selection: Selection(
        eventId: event.id,
        market: 'player_pass_yds',
        participant: 'Recorded Quarterback',
        outcome: 'Over',
        point: 245.5,
      ),
      bookId: 'book',
      book: 'Book',
      provider: 'fixture',
      decimal: 1.91,
      sourceAt: now,
      collectedAt: now,
    );
    expect(
      checkAnalysis(
        analysis: result,
        prices: OddsBoard(events: [event], quotes: [price], fetchedAt: now),
        data: data,
        now: now,
      )!.recompute,
      true,
    );
    final report = CoachTelemetry(
      checkedAt: now,
      observations: [
        TelemetryObservation(
          id: 'out',
          kind: 'injury',
          eventId: event.id,
          playerId: 'qb-1',
          source: 'Official fixture',
          observedAt: now,
          confirmed: true,
          value: const {'status': 'Out'},
        ),
      ],
      sources: const [],
    );
    expect(
      checkAnalysis(
        analysis: result,
        prices: board,
        data: data,
        now: now,
        after: report,
      )!.reason,
      contains('withdrawn'),
    );
    expect(
      checkAnalysis(
        analysis: result,
        prices: OddsBoard(events: [event], quotes: [price], fetchedAt: now),
        data: data,
        now: now,
        after: report,
      )!.recompute,
      false,
    ); // A simultaneous price update must not override a scratch.

    expect(
      checkAnalysis(
        analysis: result,
        prices: board,
        data: data,
        now: now.add(const Duration(minutes: 6)),
        after: report,
      )!.reason,
      contains('stale'),
    );
    expect(
      checkAnalysis(
        analysis: result,
        prices: board,
        data: data,
        now: event.startsAt,
      )!.reason,
      contains('Kickoff'),
    );
  });
  test('a revised recorded stat invalidates even if metadata timestamps are unchanged', () {
    final result = run();
    final revised = dataWith([
      ...old,
      ...current.where((r) => !(r.playerId == 'qb-1' && r.week == 10)),
      recorded(week: 10, stats: const {'passing_yards': 300, 'attempts': 34}),
    ]);
    expect(
      checkAnalysis(
        analysis: result,
        prices: board,
        data: revised,
        now: now,
      )!.recompute,
      true,
    );
  });
}
