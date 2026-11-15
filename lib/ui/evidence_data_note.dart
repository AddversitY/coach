import 'package:flutter/material.dart';

import '../domain/eastern.dart';
import '../domain/injury_report.dart';
import '../domain/matchup.dart';
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
        if (matchup != null)
          Text(
            'Stored context ${matchup!.reportedSeason ?? 'season unknown'} · snaps ${_week(matchup!.snapThroughWeek)} · injuries ${_week(matchup!.injuryThroughWeek)}${matchup!.cutoff == null ? ' · date unknown' : ''}',
            style: EdgeType.label.copyWith(fontSize: 11),
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

  String _contextCoverage(int? week) {
    final season = matchup?.reportedSeason;
    return '${season == null ? 'Season unknown' : '$season season'} · ${week == null ? 'recorded week unknown' : 'recorded through Week $week'}. '
        '${_coverage(matchup?.cutoff)} ${_retrieval(matchup?.retrievedAt)}';
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
                    : _contextCoverage(matchup!.snapThroughWeek),
              ),
              _section(
                'Stored injury context',
                matchup == null
                    ? 'No stored matchup context is loaded.'
                    : _contextCoverage(matchup!.injuryThroughWeek),
              ),
              _section('Current availability', _availability()),
              if (matchup?.sourceName != null)
                Text(
                  'Stored context source: ${matchup!.sourceName}',
                  style: EdgeType.label,
                ),
              if (matchup?.snapSource != null)
                SelectableText(matchup!.snapSource!, style: EdgeType.label),
              if (matchup?.injurySource != null)
                SelectableText(matchup!.injurySource!, style: EdgeType.label),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(String title, String detail) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: EdgeType.label),
        const SizedBox(height: 4),
        Text(detail, style: EdgeType.body),
      ],
    ),
  );
}
