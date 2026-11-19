import 'package:flutter/material.dart';

import '../domain/bet_finder.dart';
import '../domain/eastern.dart';
import '../domain/odds.dart';
import '../theme/coach_theme.dart';

/// Straight bets and a cross-game parlay, each with the numbers behind it.
class BetIdeasView extends StatelessWidget {
  const BetIdeasView({super.key, required this.answer, this.onAsk});
  final BetFinderAnswer answer;

  /// Opens the full research for one idea, such as a player's prop card.
  final void Function(String question)? onAsk;

  String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
  String _signed(double v) => '${v >= 0 ? '+' : ''}${_pct(v)}';

  Widget _idea(BetIdea i, {bool showBook = true}) {
    final record = i.recordRate == null
        ? null
        : 'Record ${_pct(i.recordRate!)} over ${i.recordSample} games'
              '${i.signal == RecordSignal.agrees
                  ? ', agrees'
                  : i.signal == RecordSignal.disagrees
                  ? ', disagrees'
                  : ''}';
    final player = i.side.selection.participant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  i.label,
                  style: CoachType.body.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${americanLabel(i.price.decimal)}${showBook ? ' ${i.price.book}' : ''}',
                style: CoachType.body.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          Text(
            [
              i.market.matchup,
              if ((i.estimate - i.fair).abs() >= .0005)
                'Coach ${_pct(i.estimate)} vs market ${_pct(i.fair)}'
              else
                'market ${_pct(i.fair)}',
              '${_signed(i.edge)} per dollar',
              ?record,
            ].join(' · '),
            style: CoachType.label.copyWith(
              fontSize: 11,
              color: i.signal == RecordSignal.disagrees
                  ? CoachColors.warn
                  : null,
            ),
          ),
          if (player.isNotEmpty && onAsk != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 28),
                ),
                onPressed: () => onAsk!(
                  '$player ${i.market.detail.split(' · ').last.replaceAll(RegExp(r'\s*[\d.]+$'), '').toLowerCase()} '
                  '${i.side.selection.outcome.toLowerCase()} ${i.side.selection.point}',
                ),
                child: const Text('See the record'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _card(String title, List<Widget> children) => Container(
    margin: const EdgeInsets.only(top: 10),
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
          title,
          style: CoachType.label.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final a = answer;
    final parlay = a.parlay;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Saved ${formatEastern(a.snapshotAt)} · confirm current prices',
          style: CoachType.label.copyWith(
            color: CoachColors.warn,
            fontSize: 11,
          ),
        ),
        if (parlay != null)
          _card(
            '${parlay.legs.length}-leg parlay at ${parlay.book} · ${americanLabel(parlay.decimal)}',
            [
              for (final leg in parlay.legs) _idea(leg, showBook: false),
              Text(
                'Market chance ${_pct(parlay.fair)}, ${_signed(parlay.edge)} per dollar. '
                'One leg per game, so the legs are not correlated. All legs at one book, because a parlay is placed at one book.',
                style: CoachType.label.copyWith(fontSize: 11),
              ),
            ],
          ),
        if (a.straight.isNotEmpty)
          _card(parlay == null ? 'Straight bets' : 'Best straight bets', [
            for (final i in a.straight.take(parlay == null ? 5 : 3)) _idea(i),
          ]),
        for (final note in a.notes)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(note, style: CoachType.label.copyWith(fontSize: 11)),
          ),
      ],
    );
  }
}
