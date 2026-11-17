import 'eastern.dart';
import 'game_research.dart';
import 'nfl_teams.dart';
import 'odds.dart';
import 'player_stats.dart';
import 'research_changes.dart';
import 'coach_conversation.dart';

enum CoachIntent {
  briefing,
  players,
  prices,
  evidence,
  changes,
  challenge,
  history,
  clarify,
  live,
  gameAnalysis,
  evaluation,
}

class CoachAnswer {
  const CoachAnswer({
    required this.title,
    required this.text,
    required this.intent,
    this.event,
    this.player,
    this.metric = passingResearch,
    this.games = const [],
    this.players = const [],
    this.quotes = const [],
    this.changes = const [],
    this.coverage,
    this.line,
    this.evidenceNotice,
  });
  final String title, text;
  final CoachIntent intent;
  final SportEvent? event;
  final GameResearchPlayer? player;
  final ResearchMetric metric;
  final List<SportEvent> games;
  final List<GameResearchPlayer> players;
  final List<OddsQuote> quotes;
  final List<ResearchChange> changes;
  final DateTime? coverage;
  final double? line;
  final String? evidenceNotice;

  Map<String, dynamic> modelPayload(String question, DateTime now) => {
    'question': question,
    'mode': intent == CoachIntent.challenge ? 'challenge' : 'explain',
    'teamEvidence': [
      {
        'researchAt': now.toUtc().toIso8601String(),
        'summary': text,
        'scope': 'NFL research only. No verified injury, weather or current roster feed. No calibrated prop forecast supplied.',
        if (event != null) 'game': '${event!.away} at ${event!.home}',
        'upcoming': games
            .take(5)
            .map((g) => '${g.away} at ${g.home}, ${formatEastern(g.startsAt)}')
            .toList(),
      },
    ],
    'playerEvidence': player == null
        ? <Map<String, dynamic>>[]
        : [
            {
              'playerId': player!.id,
              'name': player!.name,
              'metric': metric.label,
              'recordedThrough': coverage?.toIso8601String(),
              'participation':
                  'Historical appearances; current participation unconfirmed',
              'recentAverage': researchAverage(
                player!.games.take(3),
                metric.key,
              ),
              'seasonAverage': researchAverage(player!.games, metric.key),
              'changes': changes.map((c) => c.summary).join(' '),
              'savedPrices': quotes
                  .take(10)
                  .map(
                    (q) =>
                        '${q.selection.outcome} ${q.selection.point}: ${americanLabel(q.decimal)} at ${q.book}, source ${q.sourceAt.toIso8601String()}, checked ${q.collectedAt.toIso8601String()}; may have changed; rules unverified',
                  )
                  .toList(),
              'notice': evidenceNotice ?? 'Recorded performance describes history, not future probability.',
            },
          ],
  };
}

/// Explicit subject context and verified retrieval; no generated facts or bets.
class CoachSession {
  String? eventId, playerId;
  ResearchMetric? metric;
  double? line;

  CoachAnswer respond(
    String question, {
    required OddsBoard board,
    required OddsBoard prices,
    required PlayerStatsDataset data,
    required Map<String, String> playerIds,
    required DateTime now,
  }) {
    final scopeNotice = CoachConversation.unsupportedScope(question);
    if (scopeNotice != null) {
      eventId = null;
      playerId = null;
      metric = null;
      line = null;
      return CoachAnswer(
        title: 'That market scope is not supported yet',
        text: scopeNotice,
        intent: CoachIntent.clarify,
      );
    }
    final q = question.toLowerCase().trim();
    final upcoming = board.events.where((e) => e.startsAt.isAfter(now)).toList()
      ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    final intent =
        q.contains('challenge') || q.contains('against') || q.contains('risk')
        ? CoachIntent.challenge
        : q.contains('changed') || q.contains('trend')
        ? CoachIntent.changes
        : q.contains('recorded games') || q.contains('history')
        ? CoachIntent.history
        : q.contains('price') ||
              q.contains('odds') ||
              q.contains('line') ||
              RegExp(r'\b(over|under)\b').hasMatch(q)
        ? CoachIntent.prices
        : q.contains('evidence') ||
              q.contains('performance') ||
              q.contains('chart')
        ? CoachIntent.evidence
        : q.contains('player')
        ? CoachIntent.players
        : CoachIntent.briefing;
    if (upcoming.isEmpty) {
      return const CoachAnswer(
        title: 'Waiting for the next slate',
        text: 'No upcoming NFL games are available in this snapshot. Refresh the data to check for an updated schedule.',
        intent: CoachIntent.clarify,
      );
    }
    final research = {
      for (final e in upcoming)
        e.id: buildGameResearch(data: data, event: e, now: now),
    };
    final matches = <(SportEvent, GameResearchPlayer)>[];
    for (final e in upcoming) {
      for (final p in research[e.id]!.players) {
        final name = p.name.toLowerCase();
        if (RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(q)) {
          matches.add((e, p));
        }
      }
    }
    final teams = nflTeams.entries
        .where(
          (t) =>
              q.contains(t.key.toLowerCase()) ||
              RegExp(
                '\\b${RegExp.escape(t.key.split(' ').last.toLowerCase())}\\b',
              ).hasMatch(q) ||
              RegExp('\\b${t.value}\\b').hasMatch(question),
        )
        .map((t) => t.key)
        .toSet();
    final fullMatches = matches
        .where((m) => q.contains(m.$2.name.toLowerCase()))
        .toList();
    if (fullMatches.isNotEmpty) {
      matches.removeWhere(
        (m) => !fullMatches.any((full) => full.$2.id == m.$2.id),
      );
    }
    final namedGames = upcoming
        .where((e) => teams.contains(e.away) || teams.contains(e.home))
        .toList();
    final contextual = RegExp(
      r'^(?:what argues against it|what could go wrong|what changed|why(?: this| that)?|challenge(?: it| this)?|explain(?: it| this)?|(?:show|compare|check)(?: me)?(?: the)? (?:evidence|history|recorded games|prices|odds|chart)|check again|refresh|(?:over|under)(?:\s+-?\d+(?:\.\d+)?)?|passing yards|rushing yards|receiving yards|receptions)[?!.]*$',
    ).hasMatch(q);
    final globalSourceCommand = RegExp(
      r'^(?:show(?: me)? |check |get |give me )?(?:the )?(?:latest |current )?(?:nfl |reporter |beat writer )?(?:news|headlines|reports|injury updates|injuries|weather|latest updates)[?!.]*$',
    ).hasMatch(q);
    final globalCommand =
        globalSourceCommand ||
        const [
          'brief me',
          'show the slate',
          'find a player',
          'compare prices',
        ].contains(q);
    if (matches.isEmpty &&
        namedGames.isEmpty &&
        !contextual &&
        !globalCommand) {
      return CoachAnswer(
        title: 'I need a matching research subject',
        text: 'I couldn’t match that name to the recorded players in the upcoming NFL slate. Choose a game below; I won’t reuse a different player’s evidence.',
        intent: CoachIntent.clarify,
        games: upcoming.take(6).toList(),
      );
    }
    if (matches.map((m) => m.$2.id).toSet().length > 1) {
      final choices = {for (final m in matches) m.$2.id: m.$2};
      return CoachAnswer(
        title: 'Which player?',
        text: 'More than one recorded player matches. Choose a full name so I keep the evidence separate.',
        intent: CoachIntent.clarify,
        players: choices.values.toList(),
      );
    }
    SportEvent? event = upcoming.where((e) => e.id == eventId).firstOrNull;
    GameResearchPlayer? player;
    if (matches.isNotEmpty) {
      // A newly named subject is an explicit request. Contextual follow-ups
      // without a name can retain their line; a fresh named request cannot.
      line = null;
      final sameGame =
          matches.where((m) => m.$1.id == eventId).firstOrNull ?? matches.first;
      event = sameGame.$1;
      player = sameGame.$2;
      if (playerId != player.id) {
        metric = null;
        line = null;
      }
      playerId = player.id;
      eventId = event.id;
    } else if (namedGames.isNotEmpty) {
      event = namedGames.first;
      playerId = null;
      metric = null;
      line = null;
      eventId = event.id;
    }
    if (q == 'brief me' ||
        q == 'show the slate' ||
        q == 'find a player' ||
        q == 'compare prices' ||
        globalSourceCommand) {
      eventId = null;
      playerId = null;
      metric = null;
      line = null;
      event = null;
    }
    if (event == null) {
      return CoachAnswer(
        title: 'Let’s start with a game',
        text: board.demo
            ? 'This is example data, not real sportsbook prices. Choose a game to explore the research flow.'
            : 'Choose a game, or ask about a player by name. I can compare saved prices, explore recorded performance, and show what changed. Price coverage is limited; saved prices may have changed.',
        intent: CoachIntent.briefing,
        games: upcoming.take(6).toList(),
      );
    }
    final snapshot = research[event.id]!;
    player ??= snapshot.players.where((p) => p.id == playerId).firstOrNull;
    if (player == null) {
      return CoachAnswer(
        title: '${event.away} at ${event.home}',
        text:
            '${formatEastern(event.startsAt)}. Select a recorded player to compare a prop or explore the evidence. These appearances are not a confirmed roster.',
        intent: CoachIntent.players,
        event: event,
        players: snapshot.players.take(12).toList(),
        coverage: snapshot.coverage,
        evidenceNotice: snapshot.notice,
      );
    }
    final requestedMarket = CoachConversation.marketIn(q);
    final requested = requestedMarket == 'receptions'
        ? receptionsResearch
        : requestedMarket == 'receiving yards'
        ? receivingResearch
        : requestedMarket == 'rushing yards'
        ? rushingResearch
        : requestedMarket == 'passing yards'
        ? passingResearch
        : null;
    if (matches.isNotEmpty &&
        requested == null &&
        RegExp(r'\b(over|under)\b').hasMatch(q)) {
      return CoachAnswer(
        title: 'Which player stat should I compare?',
        text:
            'Include a supported stat, over or under, and its numerical line for ${player.name}.',
        intent: CoachIntent.clarify,
        event: event,
        player: player,
        metric: player.metrics.first,
        coverage: snapshot.coverage,
      );
    }
    if (requested != null &&
        !player.metrics.any((m) => m.key == requested.key)) {
      return CoachAnswer(
        title: 'Choose a recorded stat',
        text:
            'That stat is outside this player’s supported recorded research. Try ${player.metrics.map((m) => m.shortLabel).join(', ')}.',
        intent: CoachIntent.clarify,
        event: event,
        player: player,
      );
    }
    if (requested != null && requested.key != metric?.key) line = null;
    metric = requested ?? metric ?? player.metrics.first;
    final requestedSide = RegExp(r'\b(over|under)\b').firstMatch(q)?.group(1);
    final lineMatch = RegExp(r'\b(?:over|under|line)\s+(-?\d+(?:\.\d+)?)\b')
        .firstMatch(q);
    if (lineMatch != null) line = double.tryParse(lineMatch.group(1)!);
    if (requestedSide != null && line == null) {
      return CoachAnswer(
        title: 'Which line should I compare?',
        text:
            'Include the numerical $requestedSide line for ${player.name} ${metric!.label.toLowerCase()}. I won’t choose a saved line for you.',
        intent: CoachIntent.clarify,
        event: event,
        player: player,
        metric: metric!,
        coverage: snapshot.coverage,
      );
    }
    final available = deduplicateQuotes(prices.quotes)
        .where(
          (quote) =>
              !prices.demo &&
              !prices.fetchedAt.isAfter(now) &&
              !quote.demo &&
              quote.selection.eventId == event!.id &&
              quote.selection.participant == player!.name &&
              playerIds[quote.selection.participant] == player.id &&
              quote.selection.market == metric!.market &&
              quote.selection.period == 'full_game' &&
              quote.selection.point != null &&
              {
                'over',
                'under',
              }.contains(quote.selection.outcome.toLowerCase()) &&
              quote.status == 'open' &&
              !quote.sourceAt.isAfter(now) &&
              !quote.collectedAt.isAfter(prices.fetchedAt) &&
              !quote.collectedAt.isBefore(quote.sourceAt) &&
              now.difference(quote.sourceAt) <= const Duration(hours: 18) &&
              now.difference(quote.collectedAt) <= const Duration(hours: 18),
        )
        .toList();
    final recent = researchAverage(player.games.take(3), metric!.key);
    final season = researchAverage(player.games, metric!.key);
    final changes = recentResearchChanges(
      data: data,
      playerId: player.id,
      market: metric!.market,
      team: player.team,
      now: now,
      eventAt: event.startsAt,
      eventTeams: {event.away, event.home},
    );
    final chosen = available
        .where(
          (quote) =>
              (line == null || quote.selection.point == line) &&
              (requestedSide == null ||
                  quote.selection.outcome.toLowerCase() == requestedSide),
        )
        .toList();
    String text;
    if (q.contains('injur') ||
        q.contains('weather') ||
        q.contains('starting') ||
        q.contains('roster')) {
      text = 'I don’t have verified current injury, weather or starting-roster information in these inputs. Recorded appearances cannot confirm availability. I can show dated performance or saved prices instead.';
    } else if (intent == CoachIntent.challenge) {
      text = 'Recent averages don’t establish the chance of clearing a line. The sample may miss DNPs and role changes; current participation and injury status are unconfirmed. Saved prices may have moved, and settlement rules are unverified. I don’t have a validated prop forecast to establish an edge.';
    } else if (intent == CoachIntent.changes) {
      text = changes.isEmpty
          ? 'There aren’t enough recent, comparable records to establish a dated change. I won’t fill that gap with a trend claim.'
          : changes.map((c) => c.summary).join('\n\n');
    } else if (intent == CoachIntent.prices) {
      text = chosen.isEmpty
          ? 'No saved pregame prices match ${player.name}, ${metric!.label.toLowerCase()}${line == null ? '' : ', line $line'}. Recorded performance is still available. This does not mean every sportsbook is missing that market.'
          : 'Here are the saved ${metric!.label.toLowerCase()} prices for ${player.name}. Only identical lines, sides and rule sets are compared. Confirm the current price and settlement rules with the sportsbook.';
    } else {
      text =
          '${player.name} averaged ${_number(recent)} ${metric!.label.toLowerCase()} in the last ${player.games.take(3).length} recorded games, compared with ${_number(season)} across ${player.games.length} current-club records. This describes past production, not the probability of clearing a prop.';
    }
    return CoachAnswer(
      title: '${player.name} · ${metric!.shortLabel}',
      text: text,
      intent: intent == CoachIntent.briefing ? CoachIntent.evidence : intent,
      event: event,
      player: player,
      metric: metric!,
      quotes: chosen,
      changes: changes,
      coverage: snapshot.coverage,
      line: line,
      evidenceNotice: snapshot.notice,
    );
  }
}

String _number(double? value) =>
    value == null ? 'unknown' : value.toStringAsFixed(1);
