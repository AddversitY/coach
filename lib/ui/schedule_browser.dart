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
        SingleChildScrollView(
          key: const Key('schedule-date-strip'),
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _DateButton(
                key: const Key('schedule-day-all'),
                label: 'All',
                selected: selectedDay == null,
                onTap: () => setState(() => selectedDay = null),
              ),
              for (final day in days)
                _DateButton(
                  key: ValueKey('schedule-day-$day'),
                  label: _shortDay(_wallDay(groups[day]!.first.startsAt)),
                  selected: selectedDay == day,
                  onTap: () => setState(() => selectedDay = day),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
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
          const SizedBox(height: 22),
          _DayHeading(
            day: _wallDay(groups[day]!.first.startsAt),
            count: groups[day]!.length,
          ),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns =
                  constraints.maxWidth >= 820 &&
                      MediaQuery.textScalerOf(context).scale(1) <= 1.3
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - 32 * (columns - 1)) / columns;
              return Wrap(
                spacing: 32,
                children: [
                  for (final event in groups[day]!)
                    SizedBox(
                      width: width,
                      child: _ScheduleGameRow(
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

class _DateButton extends StatelessWidget {
  const _DateButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: label,
    onTap: onTap,
    excludeSemantics: true,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        excludeFromSemantics: true,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 58),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected
                    ? EdgeColors.accent
                    : EdgeColors.border.withValues(alpha: .5),
                width: selected ? 2 : 1,
              ),
            ),
          ),
          child: Text(
            label,
            style: EdgeType.label.copyWith(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? EdgeColors.text : EdgeColors.textTertiary,
            ),
          ),
        ),
      ),
    ),
  );
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
            style: EdgeType.title.copyWith(fontSize: 17, letterSpacing: -.3),
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

class _ScheduleGameRow extends StatelessWidget {
  const _ScheduleGameRow({super.key, required this.event, this.onOpen});
  final SportEvent event;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final kickoff = formatEastern(event.startsAt).split(' · ').last;
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final teams = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TeamRow(name: event.away),
        const SizedBox(height: 10),
        _TeamRow(name: event.home),
      ],
    );
    final time = Text(
      kickoff,
      style: EdgeType.label.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: EdgeColors.textTertiary,
      ),
    );
    const arrow = Icon(
      Icons.chevron_right_rounded,
      size: 18,
      color: EdgeColors.textTertiary,
    );
    return Semantics(
      container: true,
      button: onOpen != null,
      onTap: onOpen,
      label:
          '${event.away} at ${event.home}. ${formatEastern(event.startsAt, year: true)}${onOpen == null ? '' : '. Open game research'}',
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onOpen,
            child: Container(
              constraints: const BoxConstraints(minHeight: 104),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: EdgeColors.border.withValues(alpha: .5),
                  ),
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: 17),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (largeText) ...[
                    Row(
                      children: [
                        Expanded(child: time),
                        if (onOpen != null) arrow,
                      ],
                    ),
                    const SizedBox(height: 12),
                    teams,
                  ] else
                    Row(
                      children: [
                        Expanded(child: teams),
                        const SizedBox(width: 12),
                        time,
                        if (onOpen != null) ...[
                          const SizedBox(width: 8),
                          arrow,
                        ],
                      ],
                    ),
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
  const _TeamRow({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Container(
        width: 27,
        height: 27,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: EdgeColors.surfaceHigh,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              canonicalTeam(name) ?? 'NFL',
              style: EdgeType.number.copyWith(
                fontSize: 9,
                letterSpacing: 0,
                color: EdgeColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          name,
          style: EdgeType.body.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            height: 1.25,
          ),
        ),
      ),
    ],
  );
}

class _ScheduleEmpty extends StatelessWidget {
  const _ScheduleEmpty({required this.title, required this.detail});
  final String title, detail;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: 28),
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
