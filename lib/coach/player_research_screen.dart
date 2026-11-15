import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/eastern.dart';
import '../domain/game_research.dart';
import '../domain/injury_report.dart';
import '../domain/matchup.dart';
import '../domain/odds.dart';
import '../domain/player_stats.dart';
import '../domain/research_changes.dart';
import '../theme/edge_theme.dart';
import '../ui/evidence_data_note.dart';
import '../ui/research_changes.dart';

class PlayerResearchScreen extends StatefulWidget {
  const PlayerResearchScreen({
    super.key,
    required this.event,
    required this.now,
    required this.data,
    required this.player,
    this.matchup,
    this.injuries,
    this.priceBoard,
    this.quotePlayerIds = const {},
  });
  final SportEvent event;
  final DateTime now;
  final PlayerStatsDataset data;
  final GameResearchPlayer player;
  final MatchupContext? matchup;
  final InjuryReport? injuries;
  final OddsBoard? priceBoard;
  final Map<String, String> quotePlayerIds;

  @override
  State<PlayerResearchScreen> createState() => _PlayerResearchScreenState();
}

class _PlayerResearchScreenState extends State<PlayerResearchScreen> {
  late ResearchMetric metric = widget.player.metrics.first;
  late DateTime displayNow = widget.now;
  late DateTime clockSeed = widget.now;
  DateTime openedAt = DateTime.now().toUtc();
  Timer? priceClock;

  @override
  void initState() {
    super.initState();
    _startClock();
  }

  void _startClock() {
    priceClock?.cancel();
    clockSeed = displayNow.isAfter(widget.now) ? displayNow : widget.now;
    displayNow = clockSeed;
    openedAt = DateTime.now().toUtc();
    if (widget.priceBoard?.demo == false &&
        widget.priceBoard!.quotes.isNotEmpty) {
      priceClock = Timer.periodic(const Duration(seconds: 15), (timer) {
        final elapsed = Duration(seconds: timer.tick * 15);
        final wall = DateTime.now().toUtc().difference(openedAt);
        if (mounted) {
          setState(
            () => displayNow = clockSeed.add(wall > elapsed ? wall : elapsed),
          );
        }
      });
    }
  }

  @override
  void didUpdateWidget(PlayerResearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.priceBoard != widget.priceBoard ||
        oldWidget.now != widget.now) {
      _startClock();
    }
  }

  @override
  void dispose() {
    priceClock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final research = buildGameResearch(
      data: widget.data,
      event: widget.event,
      now: displayNow,
    );
    final player = research.players
        .where((row) => row.id == widget.player.id)
        .firstOrNull;
    if (player == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Player research')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            research.notice ?? 'No recent player evidence matches this game.',
            style: EdgeType.label,
          ),
        ),
      );
    }
    final games = player.games;
    final recent = games.take(3).toList();
    final changes = recentResearchChanges(
      data: widget.data,
      playerId: player.id,
      market: metric.market,
      team: player.team,
      now: displayNow,
      eventAt: widget.event.startsAt,
      eventTeams: {widget.event.away, widget.event.home},
    );
    return Scaffold(
      key: const Key('player-research'),
      backgroundColor: EdgeColors.background,
      appBar: AppBar(
        title: Text(
          'Player research',
          style: EdgeType.label.copyWith(fontSize: 13),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
            children: [
              Text(
                '${player.position} / ${player.team}',
                style: EdgeType.label.copyWith(fontSize: 12, letterSpacing: 1),
              ),
              const SizedBox(height: 10),
              Text(
                player.name,
                style: EdgeType.display.copyWith(
                  fontSize: 34,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${widget.event.away} at ${widget.event.home}',
                style: EdgeType.label,
              ),
              Text(
                formatEastern(widget.event.startsAt),
                style: EdgeType.label.copyWith(fontSize: 12),
              ),
              const SizedBox(height: 16),
              Text(
                'Box scores through ${_date(research.coverage!)} · participation unconfirmed',
                style: EdgeType.label.copyWith(fontSize: 11),
              ),
              if (research.notice != null) ...[
                const SizedBox(height: 8),
                Text(
                  research.notice!,
                  style: EdgeType.label.copyWith(color: EdgeColors.warn),
                ),
              ],
              const SizedBox(height: 28),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in player.metrics)
                    ChoiceChip(
                      key: ValueKey('research-metric-${option.key}'),
                      label: Text(option.shortLabel),
                      selected: metric.key == option.key,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => metric = option),
                    ),
                ],
              ),
              const SizedBox(height: 28),
              Text(metric.label, style: EdgeType.title),
              const SizedBox(height: 22),
              _Averages(games: games, recent: recent, metric: metric),
              const SizedBox(height: 28),
              _ProductionChart(games: games.take(10).toList(), metric: metric),
              const SizedBox(height: 28),
              _Prices(
                event: widget.event,
                now: displayNow,
                observedAt: widget.now,
                player: player,
                metric: metric,
                board: widget.priceBoard,
                quotePlayerIds: widget.quotePlayerIds,
              ),
              if (changes.isNotEmpty) ...[
                const SizedBox(height: 28),
                ResearchChangesCard(changes: changes),
              ],
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Recorded games',
                      style: EdgeType.title.copyWith(fontSize: 20),
                    ),
                  ),
                  Text(
                    '${player.latest.season} ${player.latest.seasonType}',
                    style: EdgeType.label.copyWith(fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final game in games.take(20)) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'vs ${game.opponent}',
                              style: EdgeType.body.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${_date(game.date)} · Week ${game.week}',
                              style: EdgeType.label.copyWith(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        _value(game.stats[metric.key]),
                        style: EdgeType.number.copyWith(fontSize: 22),
                      ),
                    ],
                  ),
                ),
                Divider(color: EdgeColors.border.withValues(alpha: .4)),
              ],
              const SizedBox(height: 24),
              Text(
                'Box-score appearances are not a complete participation or DNP record. These averages describe recorded games; no price or forecast is assumed.',
                style: EdgeType.label.copyWith(fontSize: 12),
              ),
              const SizedBox(height: 16),
              EvidenceDataNote(
                now: displayNow,
                boxScores: widget.data.metadata,
                matchup: widget.matchup,
                injuries: widget.injuries,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Prices extends StatelessWidget {
  const _Prices({
    required this.event,
    required this.now,
    required this.observedAt,
    required this.player,
    required this.metric,
    required this.board,
    required this.quotePlayerIds,
  });
  final SportEvent event;
  final DateTime now, observedAt;
  final GameResearchPlayer player;
  final ResearchMetric metric;
  final OddsBoard? board;
  final Map<String, String> quotePlayerIds;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<OddsQuote>>{};
    for (final quote in deduplicateQuotes(
      board?.quotes ?? const <OddsQuote>[],
    )) {
      final selection = quote.selection;
      if (board?.demo == true ||
          board!.fetchedAt.isAfter(observedAt) ||
          quote.demo ||
          !event.startsAt.isAfter(now) ||
          selection.eventId != event.id ||
          selection.participant != player.name ||
          quotePlayerIds[selection.participant] != player.id ||
          selection.market != metric.market ||
          selection.period != 'full_game' ||
          selection.point == null ||
          !{'over', 'under'}.contains(selection.outcome.toLowerCase()) ||
          quote.status != 'open' ||
          quote.sourceAt.isAfter(now) ||
          quote.collectedAt.isAfter(now) ||
          quote.sourceAt.isAfter(board!.fetchedAt) ||
          quote.collectedAt.isAfter(board!.fetchedAt) ||
          quote.collectedAt.isBefore(quote.sourceAt) ||
          now.difference(quote.sourceAt) > const Duration(hours: 18) ||
          now.difference(quote.collectedAt) > const Duration(hours: 18)) {
        continue;
      }
      (groups[selection.key] ??= []).add(quote);
    }
    if (groups.isEmpty) {
      return Text(
        'Prices unavailable',
        key: const Key('research-prices-unavailable'),
        style: EdgeType.label.copyWith(fontSize: 12),
      );
    }
    final selections = groups.values.toList()
      ..sort((a, b) {
        final point = a.first.selection.point!.compareTo(
          b.first.selection.point!,
        );
        return point == 0
            ? a.first.selection.outcome.compareTo(b.first.selection.outcome)
            : point;
      });
    return Column(
      key: const Key('research-prices'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Saved prices', style: EdgeType.title.copyWith(fontSize: 20)),
        const SizedBox(height: 6),
        Text(
          'Pregame snapshots · settlement rules unverified',
          style: EdgeType.label.copyWith(fontSize: 12),
        ),
        for (final quotes in selections) ...[
          const SizedBox(height: 12),
          Builder(
            builder: (_) {
              final ranked = [...quotes]
                ..sort((a, b) => b.decimal.compareTo(a.decimal));
              final best = ranked.first;
              final age = now.difference(best.collectedAt);
              final ageLabel = age.inMinutes < 1
                  ? 'just now'
                  : age.inHours < 1
                  ? '${age.inMinutes}m ago'
                  : '${age.inHours}h ago';
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      metric.label,
                      style: EdgeType.label.copyWith(fontSize: 12),
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      children: [
                        Text(
                          '${americanLabel(best.decimal)} at ${best.book}',
                          style: EdgeType.body.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          'Highest saved price · checked $ageLabel',
                          style: EdgeType.label.copyWith(fontSize: 11),
                        ),
                      ],
                    ),
                    Text(
                      quotes.every((q) => q.eligible(now))
                          ? 'Recent snapshot · may have changed'
                          : 'Older snapshot · compare timestamps before use',
                      style: EdgeType.label.copyWith(
                        fontSize: 11,
                        color: quotes.every((q) => q.eligible(now))
                            ? EdgeColors.textTertiary
                            : EdgeColors.warn,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: Text(
              '${quotes.first.selection.outcome} ${_value(quotes.first.selection.point)}',
              style: EdgeType.body.copyWith(fontWeight: FontWeight.w500),
            ),
            subtitle: Text(
              '${quotes.length} ${quotes.length == 1 ? 'book' : 'books'} · source timestamps below',
              style: EdgeType.label.copyWith(fontSize: 12),
            ),
            children: [
              for (final quote
                  in quotes..sort((a, b) => b.decimal.compareTo(a.decimal)))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(quote.book, style: EdgeType.body),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            americanLabel(quote.decimal),
                            style: EdgeType.number.copyWith(fontSize: 21),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Source ${formatEastern(quote.sourceAt, year: true)} · ${quote.eligible(now) ? 'recent snapshot' : 'outdated snapshot'}',
                        style: EdgeType.label.copyWith(fontSize: 11),
                      ),
                      Text(
                        'Checked ${formatEastern(quote.collectedAt, year: true)} · may have changed',
                        style: EdgeType.label.copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          Divider(color: EdgeColors.border.withValues(alpha: .4)),
        ],
      ],
    );
  }
}

class _Averages extends StatelessWidget {
  const _Averages({
    required this.games,
    required this.recent,
    required this.metric,
  });
  final List<PlayerGame> games, recent;
  final ResearchMetric metric;
  @override
  Widget build(BuildContext context) {
    final windows = [
      ('Last 3 recorded', recent),
      ('Current club season', games),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            constraints.maxWidth >= 320 &&
                MediaQuery.textScalerOf(context).scale(1) <= 1.3
            ? 2
            : 1;
        return Wrap(
          spacing: 24,
          runSpacing: 22,
          children: [
            for (final window in windows)
              SizedBox(
                width: (constraints.maxWidth - (columns - 1) * 24) / columns,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      window.$1,
                      style: EdgeType.label.copyWith(fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      researchAverage(window.$2, metric.key) == null
                          ? '—'
                          : formatResearchAverage(
                              researchAverage(window.$2, metric.key)!,
                            ),
                      style: EdgeType.number.copyWith(
                        fontSize: 42,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${window.$2.where((game) => game.stats[metric.key] != null).length} observed games',
                      style: EdgeType.label.copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ProductionChart extends StatelessWidget {
  const _ProductionChart({required this.games, required this.metric});
  final List<PlayerGame> games;
  final ResearchMetric metric;
  @override
  Widget build(BuildContext context) {
    final chronological = games.reversed.toList();
    final values = chronological
        .map((game) => game.stats[metric.key])
        .whereType<num>()
        .toList();
    final maximum = values.fold<double>(
      1,
      (value, next) => next > value ? next.toDouble() : value,
    );
    final minimum = values.fold<double>(
      0,
      (value, next) => next < value ? next.toDouble() : value,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Recent production', style: EdgeType.label),
        const SizedBox(height: 16),
        SizedBox(
          height: 150,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final game in chronological)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Tooltip(
                      message:
                          '${_date(game.date)} vs ${game.opponent}: ${_value(game.stats[metric.key])} ${metric.label.toLowerCase()}',
                      child: Semantics(
                        label:
                            '${_date(game.date)} against ${game.opponent}, ${_value(game.stats[metric.key])} ${metric.label.toLowerCase()}',
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, box) {
                                  final value = game.stats[metric.key];
                                  final scale =
                                      box.maxHeight / (maximum - minimum);
                                  final baseline = maximum * scale;
                                  final height = value == null
                                      ? 0.0
                                      : (value.abs() * scale)
                                            .clamp(2, box.maxHeight)
                                            .toDouble();
                                  return Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Positioned(
                                        top: (baseline - 1).clamp(
                                          0,
                                          box.maxHeight - 1,
                                        ),
                                        left: 0,
                                        right: 0,
                                        child: Container(
                                          height: 1,
                                          color: EdgeColors.border,
                                        ),
                                      ),
                                      if (value == null)
                                        Align(
                                          alignment: Alignment.bottomCenter,
                                          child: Text(
                                            '—',
                                            style: EdgeType.label,
                                          ),
                                        )
                                      else
                                        Positioned(
                                          top:
                                              (value >= 0
                                                      ? baseline - height
                                                      : baseline)
                                                  .clamp(
                                                    0,
                                                    box.maxHeight - height,
                                                  ),
                                          left: 0,
                                          right: 0,
                                          child: Container(
                                            height: height,
                                            decoration: BoxDecoration(
                                              color: EdgeColors.accent
                                                  .withValues(alpha: .8),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 8),
                            ExcludeSemantics(
                              child: Text(
                                'W${game.week}',
                                style: EdgeType.label.copyWith(fontSize: 9),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Oldest to newest · missing values stay blank',
          style: EdgeType.label.copyWith(fontSize: 11),
        ),
      ],
    );
  }
}

String _date(DateTime day) => day.toIso8601String().substring(0, 10);
String _value(num? value) => value == null
    ? '—'
    : value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(1);
