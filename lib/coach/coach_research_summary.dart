import 'package:flutter/material.dart';

import '../theme/coach_theme.dart';

/// An evidence checklist, never a probability or betting-strength score.
class CoachResearchSummary extends StatelessWidget {
  const CoachResearchSummary({
    super.key,
    required this.comparison,
    this.onFollow,
  });
  final Map<String, dynamic> comparison;
  final void Function(String)? onFollow;
  @override
  Widget build(BuildContext context) {
    final summary = comparison['summary'] as Map?;
    if (summary == null) return const SizedBox.shrink();
    final options = (comparison['options'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final leaders = summary['leadingMarkets'] as List? ?? [];
    final hasMarketEvidence = options.any(
      (option) => option['status'] != 'missing_price',
    );
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 20),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: CoachColors.surface,
        border: Border.all(color: CoachColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 6,
            children: [
              Text(
                'THE RESEARCH READ',
                style: CoachType.label.copyWith(
                  fontSize: 9,
                  letterSpacing: 1.4,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: CoachColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'PASS / RESEARCH ONLY',
                  style: CoachType.label,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '${summary['headline']}',
            style: CoachType.title.copyWith(fontSize: 24),
          ),
          const SizedBox(height: 10),
          Text('${summary['text']}', style: CoachType.body),
          const SizedBox(height: 14),
          if (hasMarketEvidence)
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 600 ? 2 : 1;
                final width =
                    (constraints.maxWidth - (columns - 1) * 8) / columns;
                return Wrap(
                  spacing: 8,
                  children: [
                    for (final option in options)
                      SizedBox(
                        width: width,
                        child: _market(
                          option,
                          leaders.contains(option['market']),
                        ),
                      ),
                  ],
                );
              },
            ),
          if ((summary['reasons'] as List? ?? []).isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('Why inspect it', style: CoachType.body),
            for (final reason in summary['reasons'] as List)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('• $reason', style: CoachType.label),
              ),
          ],
          if ((summary['blockers'] as List? ?? []).isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('What could undermine the read', style: CoachType.body),
            for (final risk in summary['blockers'] as List)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('• $risk', style: CoachType.label),
              ),
          ],
          if ((summary['followUps'] as List? ?? []).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  for (final follow in summary['followUps'] as List)
                    TextButton(
                      onPressed: onFollow == null
                          ? null
                          : () => onFollow!('${follow['query']}'),
                      child: Text('${follow['label']}'),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            hasMarketEvidence
                ? '${summary['notice']}'
                : 'No model has a demonstrated betting edge.',
            style: CoachType.label.copyWith(fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _market(Map option, bool leading) {
    final checks = (option['criteria'] as List? ?? [])
            .whereType<Map>()
            .toList(),
        coverage = option['coverage'] as Map?;
    final state =
        const {
          'reviewable': 'Ready to inspect',
          'review_lineup': 'Review lineup',
          'refresh_prices': 'Refresh prices',
          'incomplete_evidence': 'Incomplete evidence',
          'unavailable': 'Unavailable',
        }[option['researchState']] ??
        'Research only';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: leading ? CoachColors.surfaceHigh : CoachColors.surface,
        border: Border.all(color: CoachColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                '${option['label']}',
                style: CoachType.body.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(state, style: CoachType.label.copyWith(fontSize: 10)),
            ],
          ),
          if (checks.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                for (final check in checks)
                  Expanded(
                    child: Tooltip(
                      triggerMode: TooltipTriggerMode.tap,
                      message: '${check['label']}: ${check['state']}',
                      child: Semantics(
                        label: '${check['label']}: ${check['state']}',
                        child: Container(
                          height: 5,
                          margin: const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(
                            color: check['state'] == 'present'
                                ? CoachColors.accent
                                : check['state'] == 'review'
                                ? CoachColors.warn
                                : CoachColors.border,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              '${coverage?['present'] ?? 0}/${coverage?['total'] ?? checks.length} coverage checks observed · ${option['books'] ?? 0} matching books',
              style: CoachType.label.copyWith(fontSize: 10),
            ),
          ] else
            Text(
              '${option['reason']}',
              style: CoachType.label.copyWith(fontSize: 10),
            ),
          if ((option['equivalentSelections'] as num? ?? 0) > 1)
            Text(
              '${option['equivalentSelections']} selections have equal coverage. No preferred side is implied.',
              style: CoachType.label.copyWith(fontSize: 10),
            ),
        ],
      ),
    );
  }
}
