import 'package:flutter/material.dart';

import '../domain/eastern.dart';
import '../domain/injury_report.dart';
import '../domain/matchup.dart';
import '../domain/report_stamp.dart';
import '../theme/edge_theme.dart';

/// Independent provenance for the evidence beneath a prop. The schedule's
/// publication/refresh time is deliberately not an input to this component.
class EvidenceDataNote extends StatelessWidget {
  const EvidenceDataNote({
    super.key,
    required this.now,
    this.boxScores,
    this.matchup,
    this.injuries,
  });
  final DateTime now;
  final Map<String, dynamic>? boxScores;
  final MatchupContext? matchup;
  final InjuryReport? injuries;

  DateTime get _researchDay {
    final wall = easternWall(now);
    return DateTime.utc(wall.year, wall.month, wall.day);
  }

  bool _futureDay(DateTime day) => day.isAfter(_researchDay);
  String _day(DateTime day) => day.toIso8601String().substring(0, 10);
  String _week(int? week) => week == null ? 'unknown' : 'W$week';

  String _contextSummary() {
    final snaps = matchup!.snapEvidence;
    final storedInjuries = matchup!.injuryEvidence;
    final sharedSeason = snaps.season == storedInjuries.season;
    final season = sharedSeason ? ' ${snaps.season ?? 'season unknown'}' : '';
    String source(String name, EvidenceSourceMetadata data) =>
        '$name ${sharedSeason ? '' : '${data.season ?? 'season unknown'} '}${_week(data.throughWeek)}';
    return 'Stored context$season · ${source('snaps', snaps)} · ${source('injuries', storedInjuries)}'
        '${snaps.refreshFailed || storedInjuries.refreshFailed
            ? ' · refresh incomplete'
            : snaps.cutoff == null || storedInjuries.cutoff == null
            ? ' · date unknown'
            : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final cutoff = parseEvidenceDay(boxScores?['cutoff']);
    final future = cutoff != null && _futureDay(cutoff);
    final title = cutoff == null
        ? 'Box-score cutoff unknown'
        : future
        ? 'Box-score cutoff is after this research date'
        : 'Box scores through ${_day(cutoff)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          key: const Key('evidence-data-details'),
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            alignment: Alignment.centerLeft,
          ),
          onPressed: () => _showDetails(context),
          icon: Icon(
            Icons.info_outline,
            size: 16,
            color: future ? EdgeColors.warn : EdgeColors.textSecondary,
          ),
          label: Text(
            '$title · Data sources',
            style: EdgeType.label.copyWith(
              fontSize: 12,
              color: future ? EdgeColors.warn : EdgeColors.textSecondary,
            ),
          ),
        ),
        Text(
          injuryReportStamp(
            checkedAt: injuries == null
                ? null
                : (injuries!.checkedAt ?? injuries!.fetchedAt),
            now: now,
            live: injuries?.live ?? false,
          ).sentence,
          style: EdgeType.label.copyWith(
            fontSize: 12,
            color: EdgeColors.textSecondary,
          ),
        ),
        if (matchup != null)
          Text(
            _contextSummary(),
            style: EdgeType.label.copyWith(
              fontSize: 11,
              color:
                  matchup!.snapEvidence.refreshFailed ||
                      matchup!.injuryEvidence.refreshFailed
                  ? EdgeColors.warn
                  : EdgeColors.textSecondary,
            ),
          ),
      ],
    );
  }

  String _coverage(DateTime? day) {
    if (day == null) {
      return 'Cutoff date unknown. No calendar date is inferred from the stored week.';
    }
    if (_futureDay(day)) {
      return 'Cutoff ${_day(day)} is after the research date; it does not establish available historical coverage.';
    }
    final age = _researchDay.difference(day).inDays;
    return 'Coverage through ${_day(day)}${age == 0 ? '' : ' · $age ${age == 1 ? 'day' : 'days'} before the research date'}. Historical coverage is not live data.';
  }

  String _retrieval(DateTime? at) {
    if (at == null) return 'Retrieval timestamp unknown.';
    if (at.isAfter(now.toUtc())) {
      return 'Retrieval timestamp ${at.toIso8601String()} is after the research time; freshness is unverified.';
    }
    return 'Retrieved ${formatEastern(at, year: true)}. Retrieval time is separate from coverage.';
  }

  String _contextCoverage(EvidenceSourceMetadata source) {
    final status = switch (source.status) {
      'retained' => 'Latest refresh failed. Previous records retained. ',
      'unavailable' =>
        'Source unavailable. No refreshed records are available. ',
      'undated' => 'Source coverage is undated. ',
      'stale' => 'Source coverage is older than the refresh window. ',
      _ => source.error != null ? 'Latest refresh failed. ' : '',
    };
    final attempt = source.lastAttemptAt == null
        ? ''
        : source.lastAttemptAt!.isAfter(now.toUtc())
        ? ' Last attempt timestamp is after the research time; it does not establish freshness.'
        : ' Last attempt ${formatEastern(source.lastAttemptAt!, year: true)}.';
    return '$status${source.season == null ? 'Season unknown' : '${source.season} season'} · ${source.throughWeek == null ? 'recorded week unknown' : 'recorded through Week ${source.throughWeek}'}. '
        '${_coverage(source.cutoff)} ${_retrieval(source.retrievedAt)}$attempt';
  }

  String _availability() {
    final report = injuries;
    if (report == null) return 'No current availability report is loaded.';
    if (!report.live) {
      return 'Stored report only; current availability has not been checked.';
    }
    final at = report.checkedAt ?? report.fetchedAt;
    if (at.isAfter(now.toUtc())) {
      return 'The report check time is after the research time; current availability is unverified.';
    }
    final age = now.toUtc().difference(at);
    return 'Checked ${formatEastern(at, year: true)}. ${age >= const Duration(hours: 24) ? 'This check is at least 24 hours old; current availability is unverified.' : 'This is a report check, not confirmation that a player will participate.'}';
  }

  void _showDetails(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: .8,
          child: ListView(
            key: const Key('evidence-source-list'),
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Text('Evidence dates and sources', style: EdgeType.title),
              const SizedBox(height: 8),
              const Text(
                'Schedule checks, historical coverage and availability checks are independent. A freshly checked schedule does not refresh these evidence files.',
                style: EdgeType.body,
              ),
              _section(
                'Player box scores',
                '${_coverage(parseEvidenceDay(boxScores?['cutoff']))} ${_retrieval(parseEvidenceTimestamp(boxScores?['retrievedAt']))}',
              ),
              _section(
                'Stored snap counts',
                matchup == null
                    ? 'No stored matchup context is loaded.'
                    : _contextCoverage(matchup!.snapEvidence),
                sourceUrl: matchup?.snapEvidence.sourceUrl,
              ),
              _section(
                'Stored injury context',
                matchup == null
                    ? 'No stored matchup context is loaded.'
                    : _contextCoverage(matchup!.injuryEvidence),
                sourceUrl: matchup?.injuryEvidence.sourceUrl,
              ),
              _section('Current availability', _availability()),
              if (matchup?.sourceName != null)
                Text(
                  'Stored context source: ${matchup!.sourceName}',
                  style: EdgeType.label,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(String title, String detail, {String? sourceUrl}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: EdgeType.label),
        const SizedBox(height: 4),
        Text(detail, style: EdgeType.body),
        if (sourceUrl != null) ...[
          const SizedBox(height: 6),
          SelectableText(sourceUrl, style: EdgeType.label),
        ],
      ],
    ),
  );
}
