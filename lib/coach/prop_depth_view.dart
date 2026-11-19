import 'package:flutter/material.dart';

import '../domain/eastern.dart';
import '../domain/odds.dart';
import '../domain/prop_depth.dart';
import '../theme/coach_theme.dart';

/// One compact card for a player prop: record against the line by window,
/// the matchup, and what the saved prices imply. Every figure is history or
/// a fee-free market price; nothing here is a validated forecast.
class PropDepthView extends StatelessWidget {
  const PropDepthView({
    super.key,
    required this.depth,
    required this.metricLabel,
  });
  final PropDepth depth;
  final String metricLabel;

  String _pct(double value) => '${(value * 100).round()}%';
  String _line(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

  @override
  Widget build(BuildContext context) {
    final rows = [...depth.windows, ?depth.vsOpponent];
    final market = depth.market;
    final defense = depth.defense;
    final gap = depth.historyVersusMarket;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CoachColors.surface,
        border: Border.all(color: CoachColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$metricLabel over ${_line(depth.line)} · record',
            style: CoachType.label.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Table(
            columnWidths: const {
              0: FlexColumnWidth(1.6),
              1: FlexColumnWidth(1),
              2: FlexColumnWidth(1),
              3: FlexColumnWidth(1),
            },
            children: [
              TableRow(
                children: [
                  for (final h in ['Window', 'Over', 'Hit rate', 'Average'])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        h,
                        style: CoachType.label.copyWith(fontSize: 11),
                      ),
                    ),
                ],
              ),
              for (final w in rows)
                TableRow(
                  key: ValueKey('prop-window-${w.label}'),
                  children: [
                    Text(w.label, style: CoachType.body),
                    Text('${w.overs}/${w.decided}', style: CoachType.body),
                    Text(
                      w.decided == 0 ? '—' : _pct(w.overs / w.decided),
                      style: CoachType.body.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      w.average == null ? '—' : w.average!.toStringAsFixed(1),
                      style: CoachType.body,
                    ),
                  ],
                ),
            ],
          ),
          if (defense != null) ...[
            const SizedBox(height: 10),
            Text(
              '${defense.opponent} allows ${defense.allowedPerGame.toStringAsFixed(1)} '
              '${metricLabel.toLowerCase()} a game to ${defense.position}s, '
              '${_ordinal(defense.rank)} most of ${defense.teams} defenses '
              '(${defense.games} games this season)'
              '${defense.soft
                  ? '. A soft matchup.'
                  : defense.tough
                  ? '. A tough matchup.'
                  : '.'}',
              style: CoachType.body,
            ),
          ],
          if (market != null) ...[
            const SizedBox(height: 10),
            Text(
              [
                if (market.bestOver != null)
                  'Best over ${americanLabel(market.bestOver!.decimal)} at ${market.bestOver!.book}',
                if (market.bestUnder != null)
                  'best under ${americanLabel(market.bestUnder!.decimal)} at ${market.bestUnder!.book}',
              ].join(', '),
              style: CoachType.body,
            ),
            if (market.fairOver != null)
              Text(
                'Market chance of the over, fee removed: ${_pct(market.fairOver!)} '
                'across ${market.books} ${market.books == 1 ? 'book' : 'books'}.',
                style: CoachType.body,
              ),
            if (gap != null)
              Text(
                gap.abs() < 3
                    ? 'History and the market agree within 3 points.'
                    : 'History (shrunk toward 50%) is ${gap.abs().round()} points '
                          '${gap > 0 ? 'above' : 'below'} the market on the over.',
                style: CoachType.body.copyWith(fontWeight: FontWeight.w600),
              ),
            if (market.bestOver != null)
              Text(
                'Saved ${formatEastern(market.bestOver!.sourceAt)} · confirm the current price.',
                style: CoachType.label.copyWith(
                  color: CoachColors.warn,
                  fontSize: 11,
                ),
              ),
          ],
          for (final note in depth.notes)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                note,
                style: CoachType.label.copyWith(
                  color: CoachColors.warn,
                  fontSize: 11,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Past results and market prices, not a validated forecast.',
              style: CoachType.label.copyWith(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

String _ordinal(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
  return '$n${const {1: 'st', 2: 'nd', 3: 'rd'}[n % 10] ?? 'th'}';
}
