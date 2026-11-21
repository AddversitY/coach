import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/coach_telemetry.dart';
import 'package:odds_edge/domain/report_stamp.dart';

void main() {
  final now = DateTime.utc(2026, 11, 20, 21, 10);

  test('a current check names the Eastern clock', () {
    expect(easternClock(now), 'Fri 4:10 PM ET');
    final stamp = injuryReportStamp(checkedAt: now, now: now);
    expect(stamp.freshness, ReportFreshness.current);
    expect(stamp.sentence, 'Injury report as of Fri 4:10 PM ET.');
    expect(
      forecastStamp(
        checkedAt: now.subtract(const Duration(minutes: 40)),
        now: now,
      ).sentence,
      'Forecast stale. Last check Fri 3:30 PM ET.',
    );
    expect(
      injuryReportStamp(checkedAt: null, now: now).sentence,
      'Injury report unavailable.',
    );
    expect(
      injuryReportStamp(checkedAt: now, now: now, live: false).sentence,
      'Injury report unavailable.',
    );
  });

  test('an injury answer names the check, and a missing forecast stays unavailable', () {
    final feed = CoachTelemetry(
      checkedAt: now,
      observations: [
        TelemetryObservation(
          id: 'out',
          kind: 'injury',
          eventId: 'game',
          source: 'ESPN injury feed (unofficial)',
          observedAt: now.subtract(const Duration(minutes: 4)),
          value: const {'status': 'Out'},
        ),
      ],
      sources: const [],
    );
    final result = liveResearch(
      question: 'injury report for the Texans',
      now: now,
      telemetry: feed,
      eventId: 'game',
    );
    expect(result.summary, contains('Injury report as of Fri 4:06 PM ET.'));
    expect(result.summary, contains('Forecast unavailable.'));
    final weather = liveResearch(
      question: 'weather for the Texans',
      now: now,
      telemetry: feed,
      eventId: 'game',
    );
    expect(weather.summary, contains('Forecast unavailable.'));
    expect(weather.summary, contains('does not confirm'));
  });
}
