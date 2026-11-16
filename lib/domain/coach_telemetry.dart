import 'dart:convert';

import 'coach_analysis.dart';
import 'odds.dart';
import 'player_stats.dart';

class TelemetryObservation {
  const TelemetryObservation({
    required this.id,
    required this.kind,
    required this.eventId,
    required this.source,
    required this.observedAt,
    required this.value,
    this.playerId,
    this.confirmed = false,
  });
  final String id, kind, eventId, source;
  final String? playerId;
  final DateTime observedAt;
  final Map<String, dynamic> value;
  final bool confirmed;
  String get signature =>
      jsonEncode([id, kind, eventId, playerId, source, confirmed, value]);
  factory TelemetryObservation.fromJson(Map<String, dynamic> json) {
    final time = DateTime.parse(json['observedAt'] as String).toUtc();
    if (!{'injury', 'weather', 'market', 'news'}.contains(json['kind']) ||
        json['source'] is! String ||
        (json['source'] as String).isEmpty ||
        json['value'] is! Map) {
      throw const FormatException('Invalid telemetry observation');
    }
    return TelemetryObservation(
      id: json['id'] as String,
      kind: json['kind'] as String,
      eventId: json['eventId'] as String,
      playerId: json['playerId'] as String?,
      source: json['source'] as String,
      observedAt: time,
      confirmed: json['confirmed'] == true,
      value: Map<String, dynamic>.from(json['value'] as Map),
    );
  }
}

class CoachTelemetry {
  const CoachTelemetry({
    required this.checkedAt,
    required this.observations,
    required this.sources,
  });
  final DateTime checkedAt;
  final List<TelemetryObservation> observations;
  final List<Map<String, dynamic>> sources;
  bool fresh(DateTime now) =>
      !checkedAt.isAfter(now) &&
      now.difference(checkedAt) <= const Duration(minutes: 5);
  factory CoachTelemetry.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 ||
        json['observations'] is! List ||
        (json['observations'] as List).length > 1000 ||
        json['sources'] is! List) {
      throw const FormatException('Invalid telemetry');
    }
    return CoachTelemetry(
      checkedAt: DateTime.parse(json['checkedAt'] as String).toUtc(),
      observations: [
        for (final row in json['observations'] as List)
          TelemetryObservation.fromJson(Map<String, dynamic>.from(row as Map)),
      ],
      sources: [
        for (final row in json['sources'] as List)
          Map<String, dynamic>.from(row as Map),
      ],
    );
  }
}

class AnalysisInvalidation {
  const AnalysisInvalidation(this.reason, {this.recompute = false});
  final String reason;
  final bool recompute;
}

AnalysisInvalidation? checkAnalysis({
  required CoachAnalysis analysis,
  required OddsBoard prices,
  required PlayerStatsDataset data,
  required DateTime now,
  CoachTelemetry? before,
  CoachTelemetry? after,
}) {
  if (analysis.legs.any((l) => !l.event.startsAt.isAfter(now))) {
    return const AnalysisInvalidation(
      'Kickoff has passed. Pregame analysis is no longer current.',
    );
  }
  if (after != null) {
    if (!after.fresh(now)) {
      return const AnalysisInvalidation(
        'Availability telemetry is stale. Refresh before treating this analysis as current.',
      );
    }
    final prior = {
      for (final item in before?.observations ?? <TelemetryObservation>[])
        item.id: item,
    };
    for (final item in after.observations) {
      if (item.observedAt.isAfter(now) ||
          !analysis.eventIds.contains(item.eventId)) {
        continue;
      }
      if (item.playerId != null &&
          !analysis.playerIds.contains(item.playerId) &&
          item.kind != 'injury') {
        continue;
      }
      final status = '${item.value['status'] ?? ''}'.toLowerCase();
      if (item.kind == 'injury' &&
          {'out', 'inactive', 'injured reserve', 'doubtful'}.contains(status) &&
          (analysis.playerIds.contains(item.playerId) ||
              before == null ||
              prior[item.id]?.signature != item.signature)) {
        return AnalysisInvalidation(
          '${item.confirmed ? 'Confirmed' : 'Reported'} $status status from ${item.source}. Analysis withdrawn pending a verified availability update.',
        );
      }
      if (before != null && prior[item.id]?.signature != item.signature) {
        return AnalysisInvalidation(
          '${item.kind} input changed at ${item.source}. Review the new evidence before using the previous result.',
        );
      }
    }
  }
  if (analysisFingerprint(analysis.legs, prices, data) !=
      analysis.fingerprint) {
    return const AnalysisInvalidation(
      'A price or evidence input changed. Recomputing the research estimate.',
      recompute: true,
    );
  }
  return null;
}
