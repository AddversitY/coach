import 'package:flutter/material.dart';

import '../domain/edge_gap.dart';
import '../domain/value_check.dart';
import '../theme/edge_theme.dart';

Color wordColor(ValueWord word, {bool overpriced = false}) => switch (word) {
  ValueWord.bet => EdgeColors.good,
  ValueWord.lean => EdgeColors.warn,
  ValueWord.skip => overpriced ? EdgeColors.bad : EdgeColors.textSecondary,
};

/// Our chance against the book's no-vig chance, with the gap drawn as a
/// rail. This is the mark on every prop, every leg, and the ticket.
class ValueCheck extends StatelessWidget {
  const ValueCheck({
    super.key,
    required this.word,
    required this.ourChance,
    required this.bookChance,
    this.ourLabel = 'Our chance',
    this.bookLabel = "Book's no-vig",
    this.note,
    this.compact = false,
    this.overpriced = false,
  });

  final ValueWord word;
  final double? ourChance;
  final double? bookChance;
  final String ourLabel;
  final String bookLabel;
  final String? note;
  final bool compact;
  final bool overpriced;

  @override
  Widget build(BuildContext context) {
    final gap = edgePoints(ourChance, bookChance);
    final color = wordColor(word, overpriced: overpriced);
    final numberSize = compact ? 18.0 : 26.0;
    return Column(
      key: const Key('value-check'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!compact) ...[
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 12,
            runSpacing: 8,
            children: [
              Text(
                'VALUE CHECK',
                style: EdgeType.label.copyWith(
                  fontSize: 11,
                  letterSpacing: 1.1,
                  color: EdgeColors.textTertiary,
                ),
              ),
              _GapChip(label: edgePointsLabel(gap), color: color),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _word(word),
            style: EdgeType.display.copyWith(
              fontSize: 32,
              color: color,
              fontStyle: FontStyle.normal,
            ),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: _Chance(
                value: chanceLabel(ourChance),
                label: ourLabel,
                color: ourChance == null
                    ? EdgeColors.textSecondary
                    : EdgeColors.text,
                size: numberSize,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _Chance(
                value: chanceLabel(bookChance),
                label: bookLabel,
                color: EdgeColors.text,
                size: numberSize,
              ),
            ),
            if (compact) ...[
              const SizedBox(width: 8),
              _GapChip(label: edgePointsLabel(gap), color: color),
            ],
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: compact ? 4 : 6,
          width: double.infinity,
          child: CustomPaint(
            painter: _RailPainter(
              our: ourChance,
              book: bookChance,
              color: EdgeColors.accent.withValues(alpha: .7),
            ),
          ),
        ),
        if (note != null && note!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            note!,
            style: EdgeType.label.copyWith(
              fontWeight: FontWeight.w500,
              height: 1.35,
              color: EdgeColors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }

  static String _word(ValueWord word) => switch (word) {
    ValueWord.bet => 'Review',
    ValueWord.lean => 'Thin margin',
    ValueWord.skip => 'Pass',
  };
}

class WordPill extends StatelessWidget {
  const WordPill({super.key, required this.word, this.overpriced = false});

  final ValueWord word;
  final bool overpriced;

  @override
  Widget build(BuildContext context) {
    final color = wordColor(word, overpriced: overpriced);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        ValueCheck._word(word),
        style: EdgeType.label.copyWith(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _GapChip extends StatelessWidget {
  const _GapChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: EdgeType.number.copyWith(
          fontFamily: EdgeFont.sans,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: color,
          letterSpacing: -0.2,
        ),
      ),
    );
  }
}

class _Chance extends StatelessWidget {
  const _Chance({
    required this.value,
    required this.label,
    required this.color,
    required this.size,
  });

  final String value;
  final String label;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: EdgeType.number.copyWith(fontSize: size, color: color),
        ),
        const SizedBox(height: 2),
        Text(
          label.toUpperCase(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: EdgeType.label.copyWith(
            fontSize: 9,
            height: 1.15,
            letterSpacing: 0.2,
            color: EdgeColors.textTertiary,
          ),
        ),
      ],
    );
  }
}

class _RailPainter extends CustomPainter {
  _RailPainter({required this.our, required this.book, required this.color});

  final double? our;
  final double? book;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final track = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height),
    );
    canvas.drawRRect(
      track,
      Paint()..color = Colors.white.withValues(alpha: .08),
    );
    final ours = our;
    if (ours == null) return;
    final fillWidth = (ours.clamp(0.0, 1.0)) * size.width;
    if (fillWidth > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, fillWidth, size.height),
          Radius.circular(size.height),
        ),
        Paint()..color = color.withValues(alpha: .9),
      );
    }
    final books = book;
    if (books == null) return;
    final x = (books.clamp(0.0, 1.0)) * size.width;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x - 1.2, -2, 2.4, size.height + 4),
        const Radius.circular(2),
      ),
      Paint()..color = EdgeColors.text,
    );
  }

  @override
  bool shouldRepaint(covariant _RailPainter oldDelegate) =>
      oldDelegate.our != our ||
      oldDelegate.book != book ||
      oldDelegate.color != color;
}

class EdgeSegments extends StatelessWidget {
  const EdgeSegments({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: EdgeColors.border.withValues(alpha: .5)),
        ),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Material(
                  color: Colors.transparent,
                  child: Semantics(
                    key: ValueKey('edge-segment-${labels[i]}'),
                    container: true,
                    button: true,
                    selected: i == index,
                    label: labels[i],
                    excludeSemantics: true,
                    onTap: () => onChanged(i),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      excludeFromSemantics: true,
                      onTap: () => onChanged(i),
                      child: Container(
                        constraints: const BoxConstraints(
                          minHeight: EdgeSpace.tap,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: i == index
                                  ? EdgeColors.accent
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 10,
                          ),
                          child: Center(
                            heightFactor: 1,
                            child: Text(
                              labels[i],
                              textAlign: TextAlign.center,
                              style: EdgeType.label.copyWith(
                                color: i == index
                                    ? EdgeColors.text
                                    : EdgeColors.textSecondary,
                                fontWeight: i == index
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
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

class EmptyNote extends StatelessWidget {
  const EmptyNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: EdgeColors.border, width: 2)),
      ),
      child: Text(text, style: EdgeType.body),
    );
  }
}
