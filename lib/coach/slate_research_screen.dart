import 'package:flutter/material.dart';

import '../domain/eastern.dart';
import '../domain/injury_report.dart';
import '../domain/matchup.dart';
import '../domain/nfl_teams.dart';
import '../domain/odds.dart';
import '../domain/player_stats.dart';
import '../theme/edge_theme.dart';
import 'game_research_screen.dart';

/// Actual player research remains useful when no sportsbook price is available.
class SlateResearchScreen extends StatefulWidget {
  const SlateResearchScreen({
    super.key,
    required this.board,
    required this.now,
    this.prices,
    this.quotePlayerIds = const {},
    this.injuries,
    this.loadPlayers,
    this.loadMatchup,
  });
  final OddsBoard board;
  final OddsBoard? prices;
  final Map<String, String> quotePlayerIds;
  final DateTime now;
  final InjuryReport? injuries;
  final Future<PlayerStatsDataset> Function()? loadPlayers;
  final Future<MatchupContext> Function()? loadMatchup;

  @override
  State<SlateResearchScreen> createState() => _SlateResearchScreenState();
}

class _SlateResearchScreenState extends State<SlateResearchScreen> {
  String? selected;

  @override
  Widget build(BuildContext context) {
    final events =
        widget.board.events
            .where((event) => event.startsAt.isAfter(widget.now))
            .toList()
          ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    if (events.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No upcoming games in this schedule.',
            style: EdgeType.label,
          ),
        ),
      );
    }
    final event =
        events.where((event) => event.id == selected).firstOrNull ??
        events.first;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Players',
                    style: EdgeType.display.copyWith(fontSize: 28),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: ValueKey('research-game-picker-${event.id}'),
                    initialValue: event.id,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(
                        Icons.sports_football_outlined,
                        size: 18,
                      ),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    items: [
                      for (final game in events)
                        DropdownMenuItem(
                          value: game.id,
                          child: Text(
                            '${canonicalTeam(game.away) ?? game.away} at ${canonicalTeam(game.home) ?? game.home} · ${formatEastern(game.startsAt)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: EdgeType.label.copyWith(
                              color: EdgeColors.text,
                            ),
                          ),
                        ),
                    ],
                    onChanged: (id) => setState(() => selected = id),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GameResearchScreen(
                key: ValueKey('slate-players-${event.id}'),
                event: event,
                now: widget.now,
                embedded: true,
                priceBoard: widget.prices,
                quotePlayerIds: widget.quotePlayerIds,
                injuries: widget.injuries,
                loadPlayers: widget.loadPlayers,
                loadMatchup: widget.loadMatchup,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
