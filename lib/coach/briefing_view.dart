import 'package:flutter/material.dart';

import '../data/source_link.dart';
import '../domain/book_link.dart';
import '../domain/coach_briefing.dart';
import '../domain/rematch.dart';
import '../domain/unit_ratings.dart';
import '../theme/coach_theme.dart';

/// One sentence and a tier badge. The table, the rematch, and the prop
/// list open underneath.
class BriefingView extends StatelessWidget {
  const BriefingView({super.key, required this.brief});
  final CoachBrief brief;

  @override
  Widget build(BuildContext context) {
    final lead = brief.ratings.isEmpty ? null : brief.ratings.first;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CoachColors.surface,
        border: Border.all(color: CoachColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(brief.text, style: CoachType.body)),
              if (lead != null) ...[
                const SizedBox(width: 8),
                _TierBadge(tier: lead.tier, label: lead.tierLabel),
              ],
            ],
          ),
          if (brief.ratings.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final rating in brief.ratings.take(4))
                    _TierBadge(
                      tier: rating.tier,
                      label: '${rating.team} ${rating.tierLabel}',
                    ),
                ],
              ),
            ),
          if (brief.change != null) _change(brief.change!),
          if (brief.splits != null) _splits(),
          if (brief.ratings.length > 1 || brief.formNotes.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('Unit ratings and form', style: CoachType.label),
              children: [
                for (final rating in brief.ratings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _TierBadge(tier: rating.tier, label: rating.tierLabel),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(rating.sentence, style: CoachType.label),
                        ),
                      ],
                    ),
                  ),
                for (final note in brief.formNotes)
                  Text(note, style: CoachType.label),
              ],
            ),
          if (brief.props != null) _props(brief.props!),
        ],
      ),
    );
  }

  Widget _change(ChangeReport report) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text('Since the earlier meeting', style: CoachType.label),
      children: [
        for (final line in report.details)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(line, style: CoachType.label),
          ),
        for (final line in report.unavailable)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              line,
              style: CoachType.label.copyWith(color: CoachColors.warn),
            ),
          ),
        Text(report.sources, style: CoachType.label.copyWith(fontSize: 11)),
      ],
    );
  }

  Widget _splits() {
    final splits = brief.splits!;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Elite, average, and weak', style: CoachType.label),
          for (final row in splits.tiers)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TierBadge(tier: row.tier, label: row.tier.name),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${row.games} games, '
                      '${row.rawAverage?.toStringAsFixed(1) ?? '—'} raw'
                      '${row.shrunkAverage == null ? '' : ', ${row.shrunkAverage!.toStringAsFixed(1)} shrunk'}'
                      '${splits.line == null ? '' : ', ${row.overs} over of ${row.games}'}',
                      style: CoachType.body,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _props(PropBoard board) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(board.summary, style: CoachType.label),
        for (final row in board.rows)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Expanded(child: Text(row.label, style: CoachType.body)),
                Text('${row.price} ${row.book}', style: CoachType.body),
                const SizedBox(width: 8),
                Text(row.implied, style: CoachType.label),
                if (permittedBookLink(row.link, row.bookId) != null)
                  TextButton(
                    onPressed: () => openSourceLink(
                      Uri.parse(permittedBookLink(row.link, row.bookId)!),
                    ),
                    child: const Text('Open'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _TierBadge extends StatelessWidget {
  const _TierBadge({required this.tier, required this.label});
  final UnitTier tier;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = switch (tier) {
      UnitTier.elite => CoachColors.accent,
      UnitTier.weak => CoachColors.warn,
      UnitTier.unavailable => CoachColors.bad,
      UnitTier.average => CoachColors.textSecondary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: CoachType.label.copyWith(color: color, fontSize: 11),
      ),
    );
  }
}
