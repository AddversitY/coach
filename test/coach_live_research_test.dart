import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/coach_telemetry.dart';

void main() {
  final now = DateTime.utc(2026, 11, 16, 12);
  TelemetryObservation row(
    String id,
    String kind, {
    String event = 'game',
    String? player,
    Duration age = Duration.zero,
  }) => TelemetryObservation(
    id: id,
    kind: kind,
    eventId: event,
    playerId: player,
    source: 'Test source',
    observedAt: now.subtract(age),
    value: const {'status': 'Out'},
  );
  CoachTelemetry feed(
    List<TelemetryObservation> rows, {
    Duration age = Duration.zero,
  }) => CoachTelemetry(
    checkedAt: now.subtract(age),
    observations: rows,
    sources: const [
      {'id': 'sharp_money', 'state': 'provider_required'},
    ],
  );

  test('each source keeps its own expiry rather than inheriting a fresh coordinator check', () {
    final result = liveResearch(
      question: 'latest updates',
      now: now,
      telemetry: feed([
        row('old injury', 'injury', age: const Duration(minutes: 13)),
        row('current injury', 'injury', age: const Duration(minutes: 10)),
        row('old news', 'news', age: const Duration(minutes: 66)),
        row('forecast', 'weather', age: const Duration(minutes: 30)),
      ]),
    );
    expect(result.rows.map((r) => r.id), ['current injury', 'forecast']);
    expect(
      liveResearch(
        question: 'news',
        now: now,
        telemetry: feed([row('news', 'news')], age: const Duration(minutes: 6)),
      ).rows,
      isEmpty,
    );
  });
  test('player and game scope cannot silently import an unrelated report', () {
    final data = feed([
      row('mine', 'injury', player: 'p'),
      row('other', 'injury', player: 'q'),
      row('global', 'news', event: 'nfl'),
      row('other game', 'injury', event: 'other', player: 'p'),
    ]);
    final result = liveResearch(
      question: 'injury reports',
      now: now,
      telemetry: data,
      playerId: 'p',
      eventId: 'game',
    );
    expect(result.rows.map((r) => r.id), ['mine']);
    expect(
      liveResearch(
        question: 'reporter news',
        now: now,
        telemetry: data,
      ).rows.single.id,
      'global',
    );
  });
  test('no matching report does not confirm health and market movement is not sharp money', () {
    expect(
      liveResearch(question: 'injuries', now: now, telemetry: feed([])).summary,
      contains('does not confirm'),
    );
    final market = liveResearch(
      question: 'sharp money',
      now: now,
      telemetry: feed([row('move', 'market')]),
    );
    expect(market.summary, contains('do not identify professional bettors'));
    expect(market.sources.single['state'], 'provider_required');
  });
}
