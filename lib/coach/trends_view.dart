import 'package:flutter/material.dart';

import '../domain/team_trends.dart';
import '../theme/coach_theme.dart';

/// Spread and total records for one matchup, notable ones first, each with
/// its sample size so a 3-0 run never reads like a rule.
class TrendsView extends StatelessWidget {
  const TrendsView({super.key, required this.trends});
  final MatchupTrends trends;

  @override
  Widget build(BuildContext context) {
    final notable = trends.notable;
    final rest = [
      for (final t in trends.trends)
        if (!notable.contains(t) && t.decided > 0) t,
    ];
    if (notable.isEmpty && rest.isEmpty) return const SizedBox.shrink();
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
          Text(
            'Trends against the closing line',
            style: CoachType.label.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          for (final t in notable)
            Text(
              t.sentence,
              style: CoachType.body.copyWith(fontWeight: FontWeight.w600),
            ),
          for (final t in rest) Text(t.sentence, style: CoachType.body),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'From nflverse closing lines in ${trends.games} completed games. Records describe the past; they are not a forecast.',
              style: CoachType.label.copyWith(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}
