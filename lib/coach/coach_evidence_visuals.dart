import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/coach_theme.dart';

/// Interactive recorded evidence, kept separate from forecast probabilities.
class CoachEvidenceVisuals extends StatefulWidget {
  const CoachEvidenceVisuals({super.key, required this.data});
  final Map<String, dynamic> data;
  @override
  State<CoachEvidenceVisuals> createState() => _CoachEvidenceVisualsState();
}

class _CoachEvidenceVisualsState extends State<CoachEvidenceVisuals> {
  String? team, metric;
  @override
  Widget build(BuildContext context) {
    final players = (widget.data['players'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final teams = (widget.data['teams'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final player = widget.data['focus'] == 'player' && players.isNotEmpty
        ? players.first
        : null;
    final series = (player?['series'] as List? ?? []).whereType<Map>().toList();
    final selected =
        series
            .where((s) => s['metric'] == (metric ?? player?['metric']))
            .firstOrNull ??
        series.firstOrNull;
    final chosen =
        teams
            .where((t) => t['name'] == (team ?? widget.data['selectedTeam']))
            .firstOrNull ??
        teams.firstOrNull;
    final sampleData = player != null ? selected : chosen;
    final samples = (sampleData?['samples'] as List? ?? [])
        .whereType<Map>()
        .take(10)
        .toList();
    final line =
        player != null &&
            selected?['metric'] == player['metric'] &&
            player['line'] is num
        ? (player['line'] as num).toDouble()
        : null;
    final values = samples
        .map((s) => s['value'])
        .whereType<num>()
        .where((v) => v.isFinite)
        .toList();
    final against = samples
        .map((s) => s['secondary'])
        .whereType<num>()
        .where((v) => v.isFinite)
        .toList();
    String average(List<num> v) => v.isEmpty
        ? '—'
        : (v.reduce((a, b) => a + b) / v.length).toStringAsFixed(1);
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
          Text(
            player != null
                ? 'THE PLAYER / RECENT FORM'
                : 'THE MATCHUP / RECENT FORM',
            style: CoachType.label.copyWith(fontSize: 9, letterSpacing: 1.4),
          ),
          const SizedBox(height: 10),
          Text(
            '${player?['name'] ?? chosen?['name'] ?? 'Recorded results'}',
            style: CoachType.title.copyWith(fontSize: 25),
          ),
          if (player == null && teams.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final t in teams)
                    ChoiceChip(
                      label: Text('${t['code'] ?? t['name']}'),
                      selected: t['name'] == chosen?['name'],
                      onSelected: (_) =>
                          setState(() => team = t['name'] as String),
                    ),
                ],
              ),
            ),
          if (player != null && series.isNotEmpty)
            DropdownButton<String>(
              isExpanded: true,
              value: selected?['metric'] as String?,
              items: [
                for (final s in series)
                  DropdownMenuItem(
                    value: s['metric'] as String,
                    child: Text('${s['label']}', style: CoachType.body),
                  ),
              ],
              onChanged: (value) => setState(() => metric = value),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 28,
            runSpacing: 12,
            children: [
              _stat(
                player != null ? 'Recorded average' : 'Scored / game',
                average(values),
              ),
              if (player == null) _stat('Allowed / game', average(against)),
              if (player == null)
                _stat(
                  'Record',
                  '${samples.where((s) => s['value'] is num && s['secondary'] is num && s['value'] > s['secondary']).length}W · ${samples.where((s) => s['value'] is num && s['secondary'] is num && s['value'] < s['secondary']).length}L · ${samples.where((s) => s['value'] is num && s['secondary'] is num && s['value'] == s['secondary']).length}T',
                ),
              if (line != null)
                _stat(
                  '${player?['lineSource'] ?? 'Comparison line'}',
                  _number(line),
                ),
              if (line != null)
                _stat(
                  'Above / below / equal',
                  '${values.where((v) => v > line).length} / ${values.where((v) => v < line).length} / ${values.where((v) => v == line).length}',
                ),
            ],
          ),
          const SizedBox(height: 18),
          if (values.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 25),
              child: Text(
                'No recorded results available for this chart.',
                style: CoachType.label,
              ),
            )
          else
            _bars(samples, line: line, paired: player == null),
          const SizedBox(height: 10),
          Text(
            player == null
                ? 'Dark = points scored · Stone = points allowed'
                : '${selected?['label'] ?? 'Recorded value'}${line == null ? '' : ' · Dashed rule = comparison line'}',
            style: CoachType.label.copyWith(fontSize: 10),
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('View recorded values', style: CoachType.label),
            children: [
              for (final sample in samples)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${sample['date']}${sample['opponent'] == null ? '' : ' vs ${sample['opponent']}'} · ${sample['value'] is num ? _number(sample['value']) : 'Missing'}${player == null ? ' scored / ${sample['secondary'] is num ? _number(sample['secondary']) : 'Missing'} allowed' : ''}',
                      style: CoachType.label,
                    ),
                  ),
                ),
            ],
          ),
          Text(
            'Source · nflverse recorded box scores',
            style: CoachType.label.copyWith(fontSize: 9),
          ),
          const SizedBox(height: 6),
          Text(
            'Oldest → newest · ${samples.length} recorded games · Through ${widget.data['cutoff'] ?? 'dated records'}',
            style: CoachType.label.copyWith(fontSize: 10),
          ),
          Text(
            player != null
                ? 'Missing values stay blank. Counts against this comparison line are historical, not a prediction or past sportsbook win rate.'
                : 'Different prior opponents. Recent scoring is descriptive, not opponent-adjusted or a forecast.',
            style: CoachType.label.copyWith(fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: CoachType.number.copyWith(fontSize: 22)),
      Text(label, style: CoachType.label.copyWith(fontSize: 10)),
    ],
  );
  String _number(num n) =>
      n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);
  Widget _bars(List<Map> samples, {double? line, required bool paired}) {
    final numbers = [
      for (final s in samples) ...[s['value'], if (paired) s['secondary']],
      ?line,
    ].whereType<num>().where((v) => v.isFinite);
    final low = math.min(
      0.0,
      numbers.fold<double>(0, (a, b) => math.min(a, b.toDouble())) * 1.15,
    );
    final high = math.max(
      1.0,
      numbers.fold<double>(0, (a, b) => math.max(a, b.toDouble())) * 1.15,
    );
    double y(num v) => 32 + (high - v) / (high - low) * 128;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 30,
          height: 160,
          child: Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final v in [high, (high + low) / 2, low])
                  Text(
                    v.round().toString(),
                    style: CoachType.label.copyWith(fontSize: 9),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              SizedBox(
                height: 160,
                child: Stack(
                  children: [
                    for (final v in [high, (high + low) / 2, low])
                      Positioned(
                        left: 0,
                        right: 0,
                        top: y(v).clamp(0, 159),
                        child: const Divider(
                          height: 1,
                          color: CoachColors.border,
                        ),
                      ),
                    if (low < 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: y(0),
                        child: const Divider(
                          height: 1,
                          color: CoachColors.textSecondary,
                        ),
                      ),
                    if (line != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: y(line),
                        child: CustomPaint(
                          size: const Size(double.infinity, 1),
                          painter: const _DashedRule(),
                        ),
                      ),
                    Row(
                      children: [
                        for (final sample in samples)
                          Expanded(child: _bar(sample, y, paired)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final sample in samples)
                    Expanded(
                      child: Text(
                        '${sample['label'] ?? ''}',
                        textAlign: TextAlign.center,
                        style: CoachType.label.copyWith(fontSize: 9),
                        maxLines: 1,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bar(Map s, double Function(num) y, bool paired) {
    final v = s['value'], other = s['secondary'];
    final label =
        '${s['date']}${s['opponent'] == null ? '' : ' vs ${s['opponent']}'}: ${v is num ? _number(v) : 'missing'}${paired ? ' scored, ${other is num ? _number(other) : 'missing'} allowed' : ''}';
    return Tooltip(
      message: label,
      triggerMode: TooltipTriggerMode.tap,
      child: Semantics(
        label: label,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: LayoutBuilder(
            builder: (context, c) {
              final width = (c.maxWidth - (paired ? 2 : 0)) / (paired ? 2 : 1);
              Widget rect(num value, double left, Color color) => Positioned(
                left: left,
                width: width,
                top: math.min(y(value), y(0)),
                height: math.max(1, (y(value) - y(0)).abs()),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: value < 0 ? CoachColors.warn : color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              );
              return SizedBox(
                height: 160,
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: Text(
                        v is num ? _number(v) : '—',
                        textAlign: TextAlign.center,
                        style: CoachType.number.copyWith(fontSize: 10),
                      ),
                    ),
                    if (v is num && v.isFinite) rect(v, 0, CoachColors.accent),
                    if (paired && other is num && other.isFinite)
                      rect(other, width + 2, CoachColors.border),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DashedRule extends CustomPainter {
  const _DashedRule();
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = CoachColors.warn
      ..strokeWidth = 1.5;
    for (double x = 0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, 0), Offset(math.min(x + 4, size.width), 0), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
