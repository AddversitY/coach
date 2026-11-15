import 'package:flutter/material.dart';

import '../domain/research_changes.dart';
import '../theme/edge_theme.dart';

/// Dated historical changes belong in research detail, not on every feed card.
class ResearchChangesCard extends StatelessWidget {
  const ResearchChangesCard({super.key, required this.changes});
  final List<ResearchChange> changes;

  @override
  Widget build(BuildContext context) {
    if (changes.isEmpty) return const SizedBox.shrink();
    final first = changes.first;
    return Material(
      key: const Key('research-changes'),
      color: EdgeColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'What changed',
              style: EdgeType.body.copyWith(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Through ${_date(first.latestGame)} · recorded games',
              style: EdgeType.label.copyWith(fontSize: 12),
            ),
            for (final change in changes.take(2)) ...[
              const SizedBox(height: 14),
              Text(change.summary, style: EdgeType.body.copyWith(fontSize: 14)),
            ],
            const SizedBox(height: 8),
            ExpansionTile(
              key: const Key('research-change-windows'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: Text(
                'Compare the windows',
                style: EdgeType.label.copyWith(color: EdgeColors.accent),
              ),
              children: [
                Text(
                  'Last ${first.recentDates.length}: ${_range(first.recentDates)}',
                  style: EdgeType.label,
                ),
                const SizedBox(height: 6),
                Text(
                  'Previous ${first.previousDates.length}: ${_range(first.previousDates)}',
                  style: EdgeType.label,
                ),
                const SizedBox(height: 10),
                const Text(
                  'Same player, team and season segment. Missing stats leave that comparison blank. These are historical averages, not a forecast.',
                  style: EdgeType.label,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _date(DateTime date) => date.toIso8601String().substring(0, 10);
String _range(List<DateTime> dates) =>
    '${_date(dates.last)} – ${_date(dates.first)}';
