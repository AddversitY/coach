import 'package:flutter/material.dart';

import '../domain/accuracy_scorecard.dart';
import '../theme/coach_theme.dart';

/// Per-week and season comparison. The chat stays the home of the app.
class AccuracyScorecardScreen extends StatelessWidget {
  const AccuracyScorecardScreen({super.key, required this.scorecard});

  final AccuracyScorecard? scorecard;

  @override
  Widget build(BuildContext context) {
    final card = scorecard ?? AccuracyScorecard.empty;
    final weeks = card.weeks.reversed.toList();
    return Scaffold(
      backgroundColor: CoachColors.background,
      appBar: AppBar(
        backgroundColor: CoachColors.background,
        foregroundColor: CoachColors.text,
        elevation: 0,
        title: Text('Accuracy', style: CoachType.title.copyWith(fontSize: 22)),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              children: [
                Text(
                  card.season == null ? 'This season' : '${card.season} season',
                  style: CoachType.label.copyWith(letterSpacing: 1.2, fontSize: 11),
                ),
                const SizedBox(height: 12),
                Text(card.seasonToDate.sentence, style: CoachType.body),
                if (card.seasonToDate.scored) ...[
                  const SizedBox(height: 16),
                  _Counts(week: card.seasonToDate),
                ],
                const SizedBox(height: 28),
                Text('By week', style: CoachType.title.copyWith(fontSize: 22)),
                const SizedBox(height: 8),
                if (weeks.isEmpty)
                  const Text(
                    'The weekly scorecard is unavailable.',
                    style: CoachType.body,
                  )
                else
                  for (final week in weeks) ...[
                    const Divider(height: 28),
                    Text(
                      week.week == null ? 'Week' : 'Week ${week.week}',
                      style: CoachType.label,
                    ),
                    const SizedBox(height: 6),
                    Text(week.sentence, style: CoachType.body),
                    if (week.scored) ...[
                      const SizedBox(height: 10),
                      _Counts(week: week),
                    ],
                  ],
                const SizedBox(height: 28),
                Text(
                  'Lower is better. ${card.notice.isEmpty ? 'This compares chances with the closing price. It is not a pick.' : card.notice}',
                  style: CoachType.label,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Counts extends StatelessWidget {
  const _Counts({required this.week});

  final ScoreWeek week;

  @override
  Widget build(BuildContext context) {
    return Text(
      '${week.picks} lines. Coach closer ${week.coachCloser}. Books closer ${week.bookCloser}.',
      style: CoachType.label,
    );
  }
}
