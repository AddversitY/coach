import 'eastern.dart';

/// How a live check is allowed to read in an answer.
enum ReportFreshness { current, stale, unavailable }

class ReportStamp {
  const ReportStamp(this.freshness, this.sentence);

  final ReportFreshness freshness;
  final String sentence;
}

/// "Fri 4:10 PM ET". The date is Eastern wall time.
String easternClock(DateTime instant) {
  final wall = easternWall(instant);
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final hour = wall.hour % 12 == 0 ? 12 : wall.hour % 12;
  final minute = wall.minute.toString().padLeft(2, '0');
  final suffix = wall.hour >= 12 ? 'PM' : 'AM';
  return '${days[wall.weekday - 1]} $hour:$minute $suffix ET';
}

/// A current check names the time. A missing check is unavailable.
/// A check older than [freshFor] is stale and keeps the last time.
ReportStamp reportStamp({
  required String label,
  required DateTime? checkedAt,
  required DateTime now,
  required Duration freshFor,
}) {
  final at = checkedAt?.toUtc();
  final clock = now.toUtc();
  if (at == null || at.isAfter(clock)) {
    return ReportStamp(
      ReportFreshness.unavailable,
      '$label unavailable.',
    );
  }
  final age = clock.difference(at);
  if (age > freshFor) {
    return ReportStamp(
      ReportFreshness.stale,
      '$label stale. Last check ${easternClock(at)}.',
    );
  }
  return ReportStamp(
    ReportFreshness.current,
    '$label as of ${easternClock(at)}.',
  );
}

const injuryFreshFor = Duration(minutes: 12);
const forecastFreshFor = Duration(minutes: 35);

ReportStamp injuryReportStamp({
  required DateTime? checkedAt,
  required DateTime now,
  bool live = true,
}) {
  if (!live) {
    return const ReportStamp(
      ReportFreshness.unavailable,
      'Injury report unavailable.',
    );
  }
  return reportStamp(
    label: 'Injury report',
    checkedAt: checkedAt,
    now: now,
    freshFor: injuryFreshFor,
  );
}

ReportStamp forecastStamp({
  required DateTime? checkedAt,
  required DateTime now,
}) => reportStamp(
  label: 'Forecast',
  checkedAt: checkedAt,
  now: now,
  freshFor: forecastFreshFor,
);
