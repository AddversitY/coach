import 'dart:convert';

import 'coach_telemetry.dart';
import 'odds.dart';

class GameOutlook {
  GameOutlook._(this.raw, this.event, this.createdAt);
  final Map<String, dynamic> raw;
  final SportEvent event;
  final DateTime createdAt;
  String get summary => raw['summary'] as String;
  String get basis => raw['basis'] as String;
  Map<String, dynamic> get score => Map<String, dynamic>.from(raw['score']);
  List<Map<String, dynamic>> get categories => [
    for (final row in raw['categories']) Map<String, dynamic>.from(row),
  ];
  List<Map<String, dynamic>> get projections => [
    for (final row in raw['projections']) Map<String, dynamic>.from(row),
  ];
  factory GameOutlook.fromJson(Map<String, dynamic> raw) {
    if (raw['schemaVersion'] != 1 ||
        raw['available'] != true ||
        raw['hasEdge'] != false ||
        raw['recommendationsReady'] != false ||
        raw['summary'] is! String ||
        raw['summary'].length > 2000 ||
        raw['event'] is! Map ||
        raw['score'] is! Map ||
        raw['categories'] is! List ||
        raw['categories'].length != 4 ||
        raw['projections'] is! List ||
        raw['projections'].length > 60) {
      throw const FormatException('Invalid game analysis');
    }
    final event = SportEvent.fromJson(Map<String, dynamic>.from(raw['event']));
    final at = DateTime.parse(raw['createdAt'] as String).toUtc();
    final brief = raw['decision'];
    if (brief != null &&
        (brief is! Map ||
            brief['hasEdge'] != false ||
            brief['recommendationsReady'] != false)) {
      throw const FormatException('Invalid decision status');
    }
    final context = raw['context'];
    if (context != null &&
        (context is! Map ||
            context['schemaVersion'] != 1 ||
            context['adjustmentsApplied'] != false ||
            context['teams'] is! List ||
            context['teams'].length > 2)) {
      throw const FormatException('Invalid role context');
    }
    bool finite(dynamic value) => value is num && value.isFinite;
    final trial = raw['workloadTrial'];
    if (trial != null) {
      if (trial is! Map ||
          trial['hasEdge'] != false ||
          trial['forecasts'] is! List ||
          trial['forecasts'].length > 80 ||
          (trial['available'] == true &&
              (trial['adopted'] != false ||
                  trial['status'] != 'shadow_only'))) {
        throw const FormatException('Invalid workload trial');
      }
      for (final row in trial['forecasts']) {
        if (row is! Map ||
            !{'attempts', 'carries', 'targets'}.contains(row['metric']) ||
            !finite(row['prediction']) ||
            row['prediction'] < 0 ||
            row['prediction'] > 100 ||
            !finite(row['incumbent']) ||
            row['incumbent'] < 0) {
          throw const FormatException('Invalid workload estimate');
        }
        final interval = row['interval'];
        if (interval != null &&
            (interval is! List ||
                interval.length != 2 ||
                !interval.every(finite) ||
                interval[0] < 0 ||
                interval[1] < interval[0] ||
                interval[1] > 100)) {
          throw const FormatException('Invalid workload range');
        }
      }
    }
    final score = raw['score'] as Map;
    final production = raw['productionTrial'];
    if (production != null) {
      if (production is! Map ||
          production['hasEdge'] != false ||
          production['forecasts'] is! List ||
          production['forecasts'].length > 80 ||
          production['rows'] is! List ||
          production['rows'].length > 150 ||
          (production['available'] == true &&
              (production['adopted'] != false ||
                  production['status'] != 'shadow_only'))) {
        throw const FormatException('Invalid production trial');
      }
      for (final row in production['forecasts']) {
        if (row is! Map ||
            !{
              'passing_yards',
              'rushing_yards',
              'receiving_yards',
              'receptions',
            }.contains(row['metric']) ||
            !finite(row['prediction']) ||
            row['prediction'] < -999 ||
            row['prediction'] > 999 ||
            row['interval'] is! List ||
            row['interval'].length != 2 ||
            !row['interval'].every(finite) ||
            row['interval'][0] < -999 ||
            row['interval'][1] > 999 ||
            row['interval'][1] < row['interval'][0]) {
          throw const FormatException('Invalid production forecast');
        }
      }
      for (final row in production['rows']) {
        if (row is! Map ||
            row['selection'] is! Map ||
            row['selection']['eventId'] != event.id ||
            row['hasEdge'] != false ||
            row['modelValidated'] != false ||
            !finite(row['decimal']) ||
            row['decimal'] <= 1 ||
            row['decimal'] > 1001 ||
            !finite(row['servingWin']) ||
            row['servingWin'] < 0 ||
            row['servingWin'] > 1 ||
            !['win', 'push', 'loss'].every(
              (key) => finite(row[key]) && row[key] >= 0 && row[key] <= 1,
            ) ||
            (row['win'] + row['push'] + row['loss'] - 1).abs() > .0001) {
          throw const FormatException('Invalid production price comparison');
        }
      }
    }
    for (final key in [
      'home',
      'away',
      'homeWin',
      'tie',
      'marginMedian',
      'totalMedian',
    ]) {
      if (!finite(score[key])) {
        throw const FormatException('Invalid score forecast');
      }
    }
    if (score['home'] < 0 ||
        score['away'] < 0 ||
        score['homeWin'] < 0 ||
        score['tie'] < 0 ||
        score['homeWin'] + score['tie'] > 1.00001) {
      throw const FormatException('Invalid score probability');
    }
    final names = <String>{};
    for (final category in raw['categories']) {
      if (category is! Map ||
          !{'spreads', 'totals', 'h2h', 'props'}.contains(category['market']) ||
          !names.add(category['market']) ||
          category['rows'] is! List ||
          category['rows'].length > 200) {
        throw const FormatException('Invalid market coverage');
      }
      for (final row in category['rows']) {
        if (row is! Map ||
            row['selection'] is! Map ||
            row['selection']['eventId'] != event.id ||
            row['hasEdge'] != false ||
            row['modelValidated'] != false ||
            !finite(row['decimal']) ||
            row['decimal'] <= 1 ||
            row['decimal'] > 1001) {
          throw const FormatException('Invalid quoted candidate');
        }
        for (final key in ['win', 'push', 'loss']) {
          if (!finite(row[key]) || row[key] < 0 || row[key] > 1) {
            throw const FormatException('Invalid candidate probability');
          }
        }
        if ((row['win'] + row['push'] + row['loss'] - 1).abs() > 0.0001) {
          throw const FormatException('Inconsistent candidate probability');
        }
      }
    }
    return GameOutlook._(raw, event, at);
  }
}

String? reviewGameContext(
  GameOutlook game,
  CoachTelemetry? telemetry,
  DateTime now,
) {
  final stored = [
    for (final key in ['availability', 'weather'])
      for (final row in game.raw[key] as List? ?? [])
        TelemetryObservation.fromJson(Map<String, dynamic>.from(row)),
  ];
  if (stored.any((o) => !currentObservation(o, now))) {
    return 'Availability or weather evidence has expired. Refresh this game before using the earlier read.';
  }
  if (telemetry?.fresh(now) != true ||
      telemetry!.checkedAt.isBefore(game.createdAt)) {
    return null;
  }
  final current = telemetry.observations.where(
    (o) =>
        o.eventId == game.event.id &&
        {'injury', 'weather'}.contains(o.kind) &&
        currentObservation(o, now),
  );
  Object? canonical(Object? value) => value is Map
      ? {
          for (final k
              in (value.keys.map((k) => k.toString()).toList()..sort()))
            k: canonical(value[k]),
        }
      : value is List
      ? value.map(canonical).toList()
      : value;
  String signature(TelemetryObservation o) => jsonEncode([
    o.id,
    o.kind,
    o.playerId,
    o.source,
    o.confirmed,
    canonical(o.value),
  ]);
  final before = stored.map(signature).toSet(),
      after = current.map(signature).toSet();
  if (before.length != after.length || !before.containsAll(after)) {
    return 'Availability or weather reports changed. Refresh this game to review the new evidence.';
  }
  return null;
}
