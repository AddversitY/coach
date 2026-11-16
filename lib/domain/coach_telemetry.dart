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

bool currentObservation(TelemetryObservation item, DateTime now) {
  final limit = item.value['signalType'] == 'betting_splits'
      ? const Duration(minutes: 30)
      : switch (item.kind) {
          'injury' => const Duration(minutes: 12),
          'weather' => const Duration(minutes: 35),
          'news' => const Duration(minutes: 65),
          'market' => const Duration(hours: 18),
          _ => Duration.zero,
        };
  return !item.observedAt.isAfter(now) &&
      now.difference(item.observedAt) <= limit;
}

class LiveResearch {
  const LiveResearch({
    required this.title,
    required this.summary,
    required this.rows,
    required this.sources,
  });
  final String title, summary;
  final List<TelemetryObservation> rows;
  final List<Map<String, dynamic>> sources;
}

LiveResearch liveResearch({
  required String question,
  required DateTime now,
  CoachTelemetry? telemetry,
  String? playerId,
  String? eventId,
}) {
  final q = question.toLowerCase();
  final kinds = <String>{
    if (RegExp(r'injur|availab|inactive|scratch').hasMatch(q)) 'injury',
    if (RegExp(r'news|reporter|writer|headline').hasMatch(q)) 'news',
    if (RegExp(r'market|sharp|money|steam|movement|splits').hasMatch(q))
      'market',
    if (RegExp(r'weather|wind|forecast').hasMatch(q)) 'weather',
  };
  if (kinds.isEmpty) kinds.addAll({'injury', 'news', 'market', 'weather'});
  final rows = telemetry?.fresh(now) == true
      ? telemetry!.observations
            .where(
              (item) =>
                  kinds.contains(item.kind) &&
                  currentObservation(item, now) &&
                  (eventId == null || item.eventId == eventId) &&
                  (playerId == null ||
                      item.playerId == null && item.eventId == eventId ||
                      item.playerId == playerId),
            )
            .toList()
      : <TelemetryObservation>[];
  final newsLinks = <String>{};
  rows.removeWhere(
    (row) =>
        row.kind == 'news' &&
        row.value['url'] is String &&
        !newsLinks.add(row.value['url'] as String),
  );
  rows.sort((a, b) => b.observedAt.compareTo(a.observedAt));
  final title = kinds.length != 1
      ? 'Latest reports'
      : switch (kinds.single) {
          'injury' => 'Availability reports',
          'news' => 'From the reporters',
          'market' => 'Market observations',
          _ => 'Game weather',
        };
  final summary = telemetry?.fresh(now) != true
      ? 'Source checks are unavailable or stale. I cannot confirm current reports. Try checking again shortly.'
      : kinds.contains('market')
      ? 'I can show changes between saved prices when matching observations exist. Price movement and betting splits do not identify professional bettors. Verified sharp-money flow still needs a provider.'
      : rows.isEmpty
      ? 'No current matching report is available in the connected sources. That does not confirm a player is healthy, active, or starting.'
      : '${rows.length} matching ${rows.length == 1 ? 'report' : 'reports'} from connected sources. Check the original publication time: an injury listing or headline does not confirm availability for the next game.';
  final sourceIds = <String>{
    if (kinds.contains('injury')) ...{'injuries', 'official_inactives'},
    if (kinds.contains('news')) 'beat_writers',
    if (kinds.contains('market')) ...{
      'markets',
      'market_movement',
      'sharp_money',
    },
    if (kinds.contains('weather')) 'weather',
  };
  return LiveResearch(
    title: title,
    summary: summary,
    rows: rows,
    sources: [
      for (final source in telemetry?.sources ?? <Map<String, dynamic>>[])
        if (sourceIds.contains(source['id']) ||
            kinds.contains('weather') &&
                '${source['id']}'.startsWith('weather:'))
          source,
    ],
  );
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
      if (!currentObservation(item, now) ||
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
