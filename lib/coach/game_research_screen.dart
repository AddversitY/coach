import 'package:flutter/material.dart';

import '../data/nfl_assets.dart';
import '../domain/eastern.dart';
import '../domain/game_research.dart';
import '../domain/injury_report.dart';
import '../domain/matchup.dart';
import '../domain/odds.dart';
import '../domain/player_stats.dart';
import '../domain/research_changes.dart';
import '../theme/edge_theme.dart';
import 'player_research_screen.dart';

class GameResearchScreen extends StatefulWidget {
  const GameResearchScreen({
    super.key,
    required this.event,
    required this.now,
    this.loadPlayers,
    this.loadMatchup,
    this.injuries,
    this.embedded = false,
    this.priceBoard,
    this.quotePlayerIds = const {},
  });
  final SportEvent event;
  final DateTime now;
  final Future<PlayerStatsDataset> Function()? loadPlayers;
  final Future<MatchupContext> Function()? loadMatchup;
  final InjuryReport? injuries;
  final bool embedded;
  final OddsBoard? priceBoard;
  final Map<String, String> quotePlayerIds;

  @override
  State<GameResearchScreen> createState() => _GameResearchScreenState();
}

class _GameResearchScreenState extends State<GameResearchScreen> {
  late Future<(PlayerStatsDataset, MatchupContext?)> source = _load();
  String team = 'All', position = 'All', query = '';
  final search = TextEditingController();
  PlayerStatsDataset? cachedData;
  SportEvent? cachedEvent;
  DateTime? cachedAt;
  GameResearchSnapshot? cachedResearch;

  GameResearchSnapshot _research(PlayerStatsDataset data) {
    if (!identical(data, cachedData) || !identical(widget.event, cachedEvent) || cachedAt != widget.now) {
      cachedData = data;
      cachedEvent = widget.event;
      cachedAt = widget.now;
      cachedResearch = buildGameResearch(data: data, event: widget.event, now: widget.now);
    }
    return cachedResearch!;
  }

  @override
  void didUpdateWidget(GameResearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.id != widget.event.id || oldWidget.event.away != widget.event.away || oldWidget.event.home != widget.event.home) {
      team = 'All';
      position = 'All';
      query = '';
      search.clear();
    }
    if (oldWidget.loadPlayers != widget.loadPlayers ||
        oldWidget.loadMatchup != widget.loadMatchup) {
      source = _load();
    }
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<(PlayerStatsDataset, MatchupContext?)> _load() async {
    final players = await (widget.loadPlayers ?? loadBundledNflPlayers)();
    MatchupContext? context;
    try {
      context = await (widget.loadMatchup ?? loadBundledMatchup)();
    } catch (_) {
      // Player box scores remain useful when stored matchup context is absent.
    }
    return (players, context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('game-research'),
    backgroundColor: EdgeColors.background,
    appBar: widget.embedded
        ? null
        : AppBar(
            title: Text(
              'Game research',
              style: EdgeType.label.copyWith(fontSize: 13),
            ),
          ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: FutureBuilder<(PlayerStatsDataset, MatchupContext?)>(
          future: source,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Player evidence is unavailable',
                      style: EdgeType.title,
                    ),
                    const SizedBox(height: 12),
                    const Text('The saved records could not be loaded.'),
                    TextButton(
                      onPressed: () => setState(() => source = _load()),
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snapshot.data!.$1;
            final matchup = snapshot.data!.$2;
            final research = _research(data);
            final teams = [
              researchClub(widget.event.away),
              researchClub(widget.event.home),
            ];
            final players = research.players
                .where(
                  (player) =>
                      (team == 'All' || researchClub(player.team) == team) &&
                      (position == 'All' || player.position == position) &&
                      ('${player.name} ${player.team} ${player.position}')
                          .toLowerCase()
                          .contains(query.trim().toLowerCase()),
                )
                .toList();
            return ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
              children: [
                if (!widget.embedded) ...[
                  Text(
                    'NFL · ${formatEastern(widget.event.startsAt)}',
                    style: EdgeType.label.copyWith(fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    widget.event.away,
                    style: EdgeType.display.copyWith(
                      fontSize: 30,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    'at ${widget.event.home}',
                    style: EdgeType.display.copyWith(
                      fontSize: 30,
                      fontWeight: FontWeight.w500,
                      color: EdgeColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 26),
                  Text('Players', style: EdgeType.title.copyWith(fontSize: 20)),
                  const SizedBox(height: 6),
                ],
                Text(
                  'Recent recorded participants · not a confirmed roster',
                  style: EdgeType.label.copyWith(fontSize: 12),
                ),
                if (research.coverage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Box scores through ${_date(research.coverage!)}',
                      style: EdgeType.label.copyWith(fontSize: 12),
                    ),
                  ),
                if (research.notice != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    research.notice!,
                    style: EdgeType.label.copyWith(color: EdgeColors.warn),
                  ),
                ],
                const SizedBox(height: 20),
                TextField(
                  key: const Key('game-player-search'),
                  controller: search,
                  decoration: const InputDecoration(
                    hintText: 'Find a player',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (text) => setState(() => query = text),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final club in ['All', ...teams])
                      ChoiceChip(
                        key: ValueKey('research-team-$club'),
                        label: Text(club),
                        showCheckmark: false,
                        selected: team == club,
                        onSelected: (_) => setState(() => team = club),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final item in ['All', 'QB', 'RB', 'WR', 'TE'])
                      FilterChip(
                        label: Text(item == 'All' ? 'All positions' : item),
                        selected: position == item,
                        showCheckmark: false,
                        onSelected: (_) => setState(() => position = item),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                if (players.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      research.players.isEmpty
                          ? 'No recent player records match this game.'
                          : 'No players match these filters.',
                      style: EdgeType.label,
                    ),
                  ),
                for (final player in players) ...[
                  _PlayerRow(
                    player: player,
                    onOpen: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PlayerResearchScreen(
                          event: widget.event,
                          now: widget.now,
                          data: data,
                          player: player,
                          matchup: matchup,
                          injuries: widget.injuries,
                          priceBoard: widget.priceBoard,
                          quotePlayerIds: widget.quotePlayerIds,
                        ),
                      ),
                    ),
                  ),
                  Divider(color: EdgeColors.border.withValues(alpha: .4)),
                ],
                const SizedBox(height: 24),
                Text(
                  'Historical production is research context. Player participation and sportsbook prices are not confirmed here.',
                  style: EdgeType.label.copyWith(fontSize: 12),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow({required this.player, required this.onOpen});
  final GameResearchPlayer player;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final metric = player.metrics.first;
    final recent = player.games.take(3).toList();
    final average = researchAverage(recent, metric.key);
    final observed = recent
        .where((game) => game.stats[metric.key] != null)
        .length;
    final parts = player.name
        .split(' ')
        .where((part) => part.isNotEmpty)
        .toList();
    final initials = parts.isEmpty
        ? '?'
        : '${parts.first[0]}${parts.length > 1 ? parts.last[0] : ''}';
    return InkWell(
      key: ValueKey('game-research-player-${player.id}'),
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final details = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  player.name,
                  style: EdgeType.body.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  '${player.position} · ${player.team} · last game ${_date(player.latest.date)}',
                  style: EdgeType.label.copyWith(fontSize: 12),
                ),
              ],
            );
            final stat = average == null
                ? null
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        formatResearchAverage(average),
                        style: EdgeType.number.copyWith(fontSize: 22),
                      ),
                      Text(
                        '$observed-game avg · ${metric.shortLabel.toLowerCase()}',
                        style: EdgeType.label.copyWith(fontSize: 11),
                      ),
                    ],
                  );
            final compact =
                constraints.maxWidth < 450 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.2;
            return Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: EdgeColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    initials,
                    style: EdgeType.label.copyWith(
                      color: EdgeColors.text,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: compact
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            details,
                            if (average != null) ...[
                              const SizedBox(height: 6),
                              Text(
                                '${formatResearchAverage(average)} ${metric.shortLabel.toLowerCase()} · $observed-game average',
                                style: EdgeType.label.copyWith(fontSize: 12),
                              ),
                            ],
                          ],
                        )
                      : details,
                ),
                if (!compact && stat != null) ...[
                  const SizedBox(width: 16),
                  stat,
                ],
                const SizedBox(width: 14),
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: EdgeColors.textTertiary,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

String _date(DateTime day) => day.toIso8601String().substring(0, 10);
