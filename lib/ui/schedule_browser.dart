import 'package:flutter/material.dart';

import '../domain/eastern.dart';
import '../domain/nfl_teams.dart';
import '../domain/odds.dart';
import '../theme/edge_theme.dart';

/// A schedule for the research feed. Dates follow the NFL's Eastern calendar;
/// a kickoff that has passed is never presented as a future fixture.
class ScheduleBrowser extends StatefulWidget {
  const ScheduleBrowser({
    super.key,
    required this.events,
    required this.now,
    this.onOpenGame,
    this.sourceReady = true,
  });

  final List<SportEvent> events;
  final DateTime now;
  final ValueChanged<String>? onOpenGame;
  final bool sourceReady;

  @override
  State<ScheduleBrowser> createState() => _ScheduleBrowserState();
}

class _ScheduleBrowserState extends State<ScheduleBrowser> {
  String? selectedDay;

  @override
  void didUpdateWidget(ScheduleBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (selectedDay != null &&
        !widget.events.any(
          (event) =>
              event.startsAt.isAfter(widget.now) &&
              _dayKey(event.startsAt) == selectedDay,
        )) {
      selectedDay = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.sourceReady) {
      return const _ScheduleEmpty(
        title: 'Schedule not loaded',
        detail: 'Check the data status above or try refreshing the schedule.',
      );
    }
    final events =
        widget.events
            .where((event) => event.startsAt.isAfter(widget.now))
            .toList()
          ..sort((a, b) {
            final time = a.startsAt.compareTo(b.startsAt);
            return time == 0 ? a.id.compareTo(b.id) : time;
          });
    if (events.isEmpty) {
      return const _ScheduleEmpty(
        title: 'No upcoming games',
        detail: 'This snapshot has no future kickoffs. Check the schedule timestamp above.',
      );
    }
    final groups = <String, List<SportEvent>>{};
    for (final event in events) {
      (groups[_dayKey(event.startsAt)] ??= []).add(event);
    }
    final days = groups.keys.toList();
    final visibleDays = selectedDay == null ? days : [selectedDay!];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              key: const Key('schedule-day-all'),
              label: const Text('All'),
              selected: selectedDay == null,
              showCheckmark: false,
              onSelected: (_) => setState(() => selectedDay = null),
            ),
            for (final day in days)
              ChoiceChip(
                key: ValueKey('schedule-day-$day'),
                label: Text(_shortDay(_wallDay(groups[day]!.first.startsAt))),
                selected: selectedDay == day,
                showCheckmark: false,
                onSelected: (_) => setState(() => selectedDay = day),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          selectedDay == null
              ? '${events.length} upcoming ${events.length == 1 ? 'game' : 'games'} · all times ET'
              : '${groups[selectedDay]!.length} ${groups[selectedDay]!.length == 1 ? 'game' : 'games'} · all times ET',
          style: EdgeType.label.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: EdgeColors.textTertiary,
          ),
        ),
        for (final day in visibleDays) ...[
          const SizedBox(height: 24),
          _DayHeading(
            day: _wallDay(groups[day]!.first.startsAt),
            count: groups[day]!.length,
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 700 ? 2 : 1;
              final width =
                  (constraints.maxWidth - 12 * (columns - 1)) / columns;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final event in groups[day]!)
                    SizedBox(
                      width: width,
                      child: _ScheduleGameCard(
                        key: ValueKey('schedule-game-${event.id}'),
                        event: event,
                        onOpen: widget.onOpenGame == null
                            ? null
                            : () => widget.onOpenGame!(event.id),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }
}

DateTime _wallDay(DateTime instant) {
  final wall = easternWall(instant);
  return DateTime.utc(wall.year, wall.month, wall.day);
}

String _dayKey(DateTime instant) =>
    _wallDay(instant).toIso8601String().substring(0, 10);

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _shortDay(DateTime day) =>
    '${_weekdays[day.weekday - 1].substring(0, 3)} ${day.day} ${_months[day.month - 1]}';

class _DayHeading extends StatelessWidget {
  const _DayHeading({required this.day, required this.count});
  final DateTime day;
  final int count;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Expanded(
        child: Semantics(
          header: true,
          child: Text(
            '${_weekdays[day.weekday - 1]}, ${_months[day.month - 1]} ${day.day}',
            style: EdgeType.title.copyWith(fontSize: 19, letterSpacing: -.3),
          ),
        ),
      ),
      const SizedBox(width: 12),
      Text(
        '$count ${count == 1 ? 'game' : 'games'}',
        style: EdgeType.label.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
      ),
    ],
  );
}

class _ScheduleGameCard extends StatelessWidget {
  const _ScheduleGameCard({super.key, required this.event, this.onOpen});
  final SportEvent event;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final kickoff = formatEastern(event.startsAt).split(' · ').last;
    return Semantics(
      container: true,
      button: onOpen != null,
      onTap: onOpen,
      label:
          '${event.away} at ${event.home}. ${formatEastern(event.startsAt, year: true)}${onOpen == null ? '' : '. Open game research'}',
      child: ExcludeSemantics(
        child: Material(
          color: EdgeColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: EdgeColors.border.withValues(alpha: .7)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: Ink(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    EdgeColors.surfaceHigh.withValues(alpha: .35),
                    EdgeColors.surface,
                  ],
                ),
              ),
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.schedule_outlined,
                        size: 15,
                        color: EdgeColors.textTertiary,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          kickoff,
                          style: EdgeType.label.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                      if (onOpen != null)
                        const Icon(
                          Icons.arrow_outward_rounded,
                          size: 17,
                          color: EdgeColors.textSecondary,
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _TeamRow(name: event.away, home: false),
                  const SizedBox(height: 14),
                  _TeamRow(name: event.home, home: true),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TeamRow extends StatelessWidget {
  const _TeamRow({required this.name, required this.home});
  final String name;
  final bool home;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Container(
        width: 40,
        height: 40,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: EdgeColors.accent.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: EdgeColors.accent.withValues(alpha: .15)),
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              canonicalTeam(name) ?? 'NFL',
              style: EdgeType.number.copyWith(
                fontSize: 11,
                letterSpacing: .2,
                color: EdgeColors.accent,
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          name,
          style: EdgeType.body.copyWith(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            height: 1.25,
          ),
        ),
      ),
      if (home) ...[
        const SizedBox(width: 8),
        Text(
          'HOME',
          style: EdgeType.label.copyWith(
            fontSize: 9,
            letterSpacing: 1,
            fontWeight: FontWeight.w500,
            color: EdgeColors.textTertiary,
          ),
        ),
      ],
    ],
  );
}

class _ScheduleEmpty extends StatelessWidget {
  const _ScheduleEmpty({required this.title, required this.detail});
  final String title, detail;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: EdgeColors.surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: EdgeColors.border.withValues(alpha: .7)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.calendar_today_outlined,
          size: 24,
          color: EdgeColors.textTertiary,
        ),
        const SizedBox(height: 16),
        Text(title, style: EdgeType.title.copyWith(fontSize: 19)),
        const SizedBox(height: 8),
        Text(
          detail,
          style: EdgeType.label.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    ),
  );
}
