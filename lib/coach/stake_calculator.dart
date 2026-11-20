import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/stake_split.dart';
import '../theme/coach_theme.dart';

/// A stake split that is not saved. The amount starts at [initial] and
/// can be changed. Nothing is written to a bankroll or a bet log.
class StakeCalculator extends StatefulWidget {
  const StakeCalculator({
    super.key,
    required this.legs,
    this.initial = 100,
  });

  final List<({String label, String book, double decimal})> legs;
  final double initial;

  @override
  State<StakeCalculator> createState() => _StakeCalculatorState();
}

class _StakeCalculatorState extends State<StakeCalculator> {
  late final amount = TextEditingController(
    text: widget.initial.toStringAsFixed(0),
  );

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = double.tryParse(amount.text);
    StakeSplit? split;
    String? error;
    if (total == null) {
      error = 'Enter a dollar amount.';
    } else {
      try {
        split = hedgeSplit(total: total, legs: widget.legs);
      } on ArgumentError catch (e) {
        error = '${e.message}';
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Stake split. Nothing is saved.',
            style: CoachType.label.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              isDense: true,
              prefixText: '\$',
              labelText: 'Combined stake',
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (error != null)
            Text(error, style: CoachType.label.copyWith(color: CoachColors.warn))
          else if (split != null) ...[
            for (final leg in split.legs)
              Text(
                '${leg.label} at ${leg.book}: \$${leg.stake.toStringAsFixed(2)}',
                style: CoachType.body,
              ),
            Text(
              'If every leg wins, the result is \$${split.result(wins: [for (final _ in split.legs) true]).toStringAsFixed(2)}. A lost leg is not covered. This is not a guaranteed profit.',
              style: CoachType.label.copyWith(fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}
