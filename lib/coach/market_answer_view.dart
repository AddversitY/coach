import 'package:flutter/material.dart';

import '../domain/eastern.dart';
import '../domain/market_math.dart';
import '../domain/market_question.dart';
import '../domain/odds.dart';
import '../domain/stake_split.dart';
import '../theme/coach_theme.dart';
import 'stake_calculator.dart';

/// Price shopping inside the conversation: best prices, fee-free market
/// chances, two-book crosses and middle windows from the saved snapshot.
class MarketAnswerView extends StatelessWidget {
  const MarketAnswerView({super.key, required this.answer});
  final MarketAnswer answer;

  String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

  Widget _card(List<Widget> children) => Container(
    margin: const EdgeInsets.only(top: 10),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: CoachColors.surface,
      border: Border.all(color: CoachColors.border),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  void _explain(BuildContext context, String text) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(text, style: CoachType.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _market(BuildContext context, PricedMarket m) => _card([
    Text(
      '${m.matchup} · ${m.detail}',
      style: CoachType.label.copyWith(fontWeight: FontWeight.w600),
    ),
    const SizedBox(height: 6),
    for (final side in m.sides)
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Expanded(child: Text(sideLabel(side), style: CoachType.body)),
            Text(
              '${americanLabel(side.best!.decimal)} ${side.best!.book}',
              style: CoachType.body.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    Text(
      [
        for (final side in m.sides)
          if (side.fairProbability != null)
            '${sideLabel(side)} ${_pct(side.fairProbability!)} fee-free'
                '${side.marketEv != null && side.marketEv! > 0 ? ' (+${_pct(side.marketEv!)} at best price)' : ''}',
        if (m.bestHold != null) 'Fee at best prices ${_pct(m.bestHold!)}',
        '${m.booksAveraged} ${m.booksAveraged == 1 ? 'book' : 'books'} averaged',
      ].join(' · '),
      style: CoachType.label.copyWith(fontSize: 11),
    ),
    if (m.sides.isNotEmpty && m.sides.first.best != null)
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () => _explain(
            context,
            impliedProbabilityNote(m.sides.first.best!.decimal),
          ),
          child: const Text('What implied probability means'),
        ),
      ),
    if (m.rulesUnverified)
      Text(
        'House rules not independently verified.',
        style: CoachType.label.copyWith(color: CoachColors.warn, fontSize: 11),
      ),
  ]);

  Widget _arb(ArbitrageOpportunity a) => _card([
    Text(
      '${a.matchup} · ${a.detail}',
      style: CoachType.label.copyWith(fontWeight: FontWeight.w600),
    ),
    for (final leg in a.legs)
      Text(
        '${leg.quote.selection.outcome} ${leg.quote.selection.point ?? ''} '
        '${americanLabel(leg.quote.decimal)} at ${leg.quote.book}: '
        '\$${(leg.share * 100).toStringAsFixed(0)} of \$100',
        style: CoachType.body,
      ),
    Text(
      'Return ${_pct(a.roi)} if both bets are accepted at these prices. Not guaranteed: prices move and books can limit or void bets.',
      style: CoachType.label.copyWith(fontSize: 11),
    ),
    StakeCalculator(
      legs: [
        for (final leg in a.legs)
          (
            label: leg.quote.selection.outcome,
            book: leg.quote.book,
            decimal: leg.quote.decimal,
          ),
      ],
    ),
  ]);

  Widget _middle(MiddleOpportunity m) => _card([
    Text(
      '${m.matchup} · ${m.market} · ${m.window}',
      style: CoachType.label.copyWith(fontWeight: FontWeight.w600),
    ),
    Text(
      '${m.first.selection.outcome} ${m.first.selection.point} ${americanLabel(m.first.decimal)} at ${m.first.book}; '
      '${m.second.selection.outcome} ${m.second.selection.point} ${americanLabel(m.second.decimal)} at ${m.second.book}',
      style: CoachType.body,
    ),
    Text(middlePayoffSummary(m), style: CoachType.label.copyWith(fontSize: 11)),
    StakeCalculator(
      legs: [
        (
          label: '${m.first.selection.outcome} ${m.first.selection.point ?? ''}',
          book: m.first.book,
          decimal: m.first.decimal,
        ),
        (
          label: '${m.second.selection.outcome} ${m.second.selection.point ?? ''}',
          book: m.second.book,
          decimal: m.second.decimal,
        ),
      ],
    ),
  ]);

  @override
  Widget build(BuildContext context) {
    final a = answer;
    final empty = a.markets.isEmpty && a.arbitrage.isEmpty && a.middles.isEmpty;
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
        for (final m in a.markets) _market(context, m),
        for (final arb in a.arbitrage) _arb(arb),
        for (final m in a.middles) _middle(m),
        if (empty && a.emptyReason != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(a.emptyReason!, style: CoachType.label),
          ),
      ],
    );
  }
}
