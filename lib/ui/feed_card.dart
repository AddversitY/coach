import 'package:flutter/material.dart';

import '../coach/coach_widgets.dart';
import '../coach/prop_pricing.dart';
import '../domain/hit_rate.dart';
import '../domain/prop_history.dart';
import '../domain/odds.dart';
import '../theme/edge_theme.dart';
import 'value_check.dart';

class FeedPropCard extends StatelessWidget {
  const FeedPropCard({
    super.key,
    required this.shown,
    required this.onOpen,
    this.onSave,
  });

  final ShownProp shown;
  final VoidCallback onOpen;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final card = shown.card;
    final quote = card.best;
    final verdict = shown.verdict;
    final samples = _sparkSamples(shown.windows);
    return Material(
      color: EdgeColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Avatar(initials: playerInitials(card.player)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              card.player,
                              style: EdgeType.title.copyWith(
                                fontFamily: EdgeFont.display,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                letterSpacing: -0.3,
                              ),
                            ),
                            WordPill(
                              word: verdict.word,
                              overpriced: verdict.overpriced,
                            ),
                            if (shown.badge != null)
                              InjuryBadgePill(
                                label: shown.badge!.label,
                                severe: shown.badge!.severe,
                              ),
                          ],
                        ),
                        if (propMeta(shown).isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            propMeta(shown),
                            style: EdgeType.label.copyWith(
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              color: EdgeColors.textTertiary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (onSave != null)
                    IconButton(
                      tooltip: 'Save play',
                      visualDensity: VisualDensity.compact,
                      onPressed: onSave,
                      icon: const Icon(Icons.bookmark_add_outlined, size: 20),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              if (shown.dataWarning != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    shown.dataWarning!,
                    style: EdgeType.label.copyWith(
                      color: EdgeColors.warn,
                      fontSize: 12,
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final line = Text(
                    shortPropLine(card),
                    style: EdgeType.body.copyWith(
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                      letterSpacing: -0.3,
                    ),
                  );
                  final prices = Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        quote == null ? '—' : americanLabel(quote.decimal),
                        style: EdgeType.number.copyWith(
                          fontSize: 19,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        priceBlurb(card),
                        textAlign: TextAlign.right,
                        style: EdgeType.label.copyWith(
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: EdgeColors.textTertiary,
                        ),
                      ),
                    ],
                  );
                  if (MediaQuery.textScalerOf(context).scale(1) > 1.3) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [line, const SizedBox(height: 8), prices],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 5, child: line),
                      const SizedBox(width: 12),
                      Flexible(flex: 4, child: prices),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              ValueCheck(
                compact: true,
                word: verdict.word,
                overpriced: verdict.overpriced,
                ourChance: verdict.ourChance,
                bookChance: verdict.fairChance,
                ourLabel: 'Model estimate',
                bookLabel: shown.bookChanceLabel,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      children: [
                        _Hit('L5', shown.windows?.last5),
                        _Hit('L10', shown.windows?.last10),
                        _Hit('H2H', shown.windows?.headToHead),
                      ],
                    ),
                  ),
                  if (samples.isNotEmpty) _Sparkline(samples: samples),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.initials});

  final String initials;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: EdgeColors.surfaceHigh,
      ),
      child: Text(
        initials,
        style: EdgeType.label.copyWith(
          fontFamily: EdgeFont.display,
          color: EdgeColors.text,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _Hit extends StatelessWidget {
  const _Hit(this.label, this.rate);
  final String label;
  final HitRate? rate;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: EdgeType.label.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
        children: [
          TextSpan(text: '$label '),
          TextSpan(
            text: hitCount(rate),
            style: TextStyle(
              color: rate == null || rate!.observed == 0
                  ? EdgeColors.textTertiary
                  : EdgeColors.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

List<HitSample> _sparkSamples(PropWindows? windows) {
  final rate = windows?.last10 ?? windows?.last5;
  if (rate == null) return const [];
  final recorded = rate.samples
      .where((sample) => sample.value != null)
      .toList();
  if (recorded.isEmpty) return const [];
  final chronological = recorded.reversed.toList();
  if (chronological.length <= 10) return chronological;
  return chronological.sublist(chronological.length - 10);
}

class _Sparkline extends StatelessWidget {
  const _Sparkline({required this.samples});
  final List<HitSample> samples;

  @override
  Widget build(BuildContext context) {
    var peak = 0.0;
    for (final sample in samples) {
      final value = sample.value!.toDouble().abs();
      if (value > peak) peak = value;
    }
    if (peak <= 0) peak = 1;
    return SizedBox(
      width: 72,
      height: 22,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final sample in samples)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 0.6),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: (sample.value!.toDouble().abs() / peak).clamp(
                      0.15,
                      1.0,
                    ),
                    widthFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: sample.outcome == 'hit'
                            ? EdgeColors.good
                            : sample.outcome == 'miss'
                            ? EdgeColors.bad
                            : EdgeColors.textTertiary,
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
