import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/coach_analysis.dart';
import '../domain/game_outlook.dart';
import '../domain/coach_telemetry.dart';
import '../domain/game_research.dart';
import '../domain/history.dart';

import 'package:flutter/material.dart';

import '../data/nfl_assets.dart';
import '../data/published_snapshot.dart';
import '../data/repository.dart';
import '../data/source_link.dart';
import '../domain/assistant.dart';
import '../domain/coach_session.dart';
import '../domain/eastern.dart';
import '../domain/odds.dart';
import '../domain/player_stats.dart';
import '../theme/coach_theme.dart';

class CoachWorkspace extends StatefulWidget {
  const CoachWorkspace({
    super.key,
    this.snapshotLoader,
    this.playerLoader,
    this.analysisHistoryLoader,
    this.validationLoader,
    this.telemetryLoader,
    this.gameAnalysisLoader,
    this.evaluationLoader,
    this.ask,
    this.clock,
  });
  final Future<PublishedSnapshot> Function()? snapshotLoader;
  final Future<PlayerStatsDataset> Function()? playerLoader;
  final Future<List<HistoricalGame>> Function()? analysisHistoryLoader;
  final Future<Map<String, dynamic>> Function()? validationLoader;
  final Future<CoachTelemetry> Function()? telemetryLoader;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  gameAnalysisLoader;
  final Future<Map<String, dynamic>> Function()? evaluationLoader;
  final Future<AssistantReply> Function(Map<String, dynamic>)? ask;
  final DateTime Function()? clock;
  @override
  State<CoachWorkspace> createState() => _CoachWorkspaceState();
}

class _Turn {
  _Turn(this.question, this.answer, this.at);
  final String question;
  final CoachAnswer answer;
  final DateTime at;
  final anchor = GlobalKey();
  AssistantReply? generated;
  bool aiFailed = false;
  CoachAnalysis? analysis;
  String? invalidation;
  GameOutlook? game;
  Map<String, dynamic>? evaluation;
  LiveResearch? live;
  String? liveNotice;
}

class _CoachWorkspaceState extends State<CoachWorkspace> {
  static const snapshotPath = String.fromEnvironment(
    'ODDS_SNAPSHOT_PATH',
    defaultValue: 'data/snapshot.json',
  );
  static const coachUrl = String.fromEnvironment('COACH_API_BASE_URL');
  final composer = TextEditingController();
  final scroll = ScrollController();
  final session = CoachSession();
  final turns = <_Turn>[];
  late final api = coachUrl.isEmpty ? null : BackendRepository(coachUrl);
  PublishedSnapshot? snapshot;
  PlayerStatsDataset? data;
  bool loading = true, busy = false;
  String? loadError;
  Timer? clockTimer;
  Timer? telemetryTimer;
  CoachTelemetry? telemetry;
  String? telemetryError;
  CoachAnalysis? lastAnalysis;
  List<HistoricalGame>? analysisScores;
  Map<String, dynamic>? analysisValidation;
  bool pollingTelemetry = false;
  Map<String, String> playerNames = {};
  String? selectedBookId;
  DateTime? lastSnapshotRefresh;
  final analysisEngine = const CoachAnalysisEngine();
  DateTime get now => widget.clock?.call().toUtc() ?? DateTime.now().toUtc();
  bool get aiConnected => widget.ask != null || api != null;

  @override
  void initState() {
    super.initState();
    _load();
    telemetryTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _pollTelemetry(),
    );
    clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        _expireAnalyses();
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    clockTimer?.cancel();
    telemetryTimer?.cancel();
    composer.dispose();
    scroll.dispose();
    api?.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final results = await Future.wait<Object>([
        (widget.snapshotLoader ??
            () => loadPublishedSnapshot(Uri.base.resolve(snapshotPath)))(),
        (widget.playerLoader ?? loadBundledNflPlayers)(),
      ]);
      if (!mounted) return;
      setState(() {
        snapshot = results[0] as PublishedSnapshot;
        data = results[1] as PlayerStatsDataset;
        playerNames = {for (final row in data!.rows) row.playerId: row.name};
        lastSnapshotRefresh = now;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => loadError = snapshot == null
              ? 'Research data could not load. Try again to start with verified records.'
              : 'Update failed. Retaining the previous snapshot with its original timestamps.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => loading = false);
        _reviewAnalyses(telemetry);
        unawaited(_pollTelemetry());
      }
    }
  }

  Future<void> _analysisSources() async {
    analysisScores ??=
        await (widget.analysisHistoryLoader ?? loadBundledHistoryGames)();
    analysisValidation ??= widget.validationLoader != null
        ? await widget.validationLoader!()
        : Map<String, dynamic>.from(
            jsonDecode(
              await rootBundle.loadString('assets/parlay-calibration.json'),
            ) as Map,
          );
  }

  void _expireAnalyses() {
    for (final turn in turns) {
      if (turn.live?.rows.any((row) => !currentObservation(row, now)) == true) {
        turn.liveNotice = 'This report snapshot has expired. Check the latest updates before using it.';
        turn.generated = null;
      }
      if (turn.game != null && !turn.game!.event.startsAt.isAfter(now)) {
        turn.invalidation =
            'Kickoff has passed. This pregame outlook is withdrawn.';
        turn.generated = null;
      }
      if (turn.analysis?.legs.any((l) => !l.event.startsAt.isAfter(now)) ==
          true) {
        turn.invalidation =
            'Kickoff has passed. This pregame result is withdrawn.';
        turn.generated = null;
      }
    }
  }

  Future<void> _pollTelemetry() async {
    if ((api == null && widget.telemetryLoader == null) ||
        pollingTelemetry ||
        !mounted) {
      return;
    }
    pollingTelemetry = true;
    try {
      final next = widget.telemetryLoader != null
          ? await widget.telemetryLoader!()
          : CoachTelemetry.fromJson(await api!.coachTelemetry());
      if (!mounted) return;
      final previous = telemetry;
      setState(() {
        telemetry = next;
        telemetryError = null;
      });
      _reviewLiveTurns();
      _reviewAnalyses(previous);
    } catch (_) {
      if (mounted) {
        setState(
          () => telemetryError = 'Availability checks are unavailable; saved timestamps have not been advanced.',
        );
      }
    } finally {
      pollingTelemetry = false;
    }
    if (mounted &&
        !busy &&
        !loading &&
        lastSnapshotRefresh != null &&
        now.difference(lastSnapshotRefresh!) > const Duration(minutes: 5)) {
      unawaited(_load());
    }
  }

  void _reviewLiveTurns() {
    for (final turn in turns) {
      if (turn.live == null) continue;
      final updated = liveResearch(
        question: turn.question,
        now: now,
        telemetry: telemetry,
        playerId: turn.answer.player?.id,
        eventId: turn.answer.event?.id,
      );
      final before = turn.live!.rows.map((row) => row.signature).toSet();
      final after = updated.rows.map((row) => row.signature).toSet();
      if (telemetry?.fresh(now) != true ||
          before.length != after.length ||
          !before.containsAll(after)) {
        turn.generated = null;
        turn.liveNotice = 'Source reports have changed. Check the latest updates for a fresh answer.';
      }
    }
  }

  void _reviewAnalyses(CoachTelemetry? previous) {
    if (snapshot == null || data == null) return;
    for (final turn in turns) {
      final analysis = turn.analysis;
      if (analysis == null) continue;
      if (analysis.legs.any(
        (leg) => !snapshot!.board.events.any(
          (event) =>
              event.id == leg.event.id &&
              event.startsAt == leg.event.startsAt &&
              event.home == leg.event.home &&
              event.away == leg.event.away,
        ),
      )) {
        turn.generated = null;
        turn.invalidation = 'The game schedule changed. Provide fresh selections before using this analysis.';
        continue;
      }
      final change = checkAnalysis(
        analysis: analysis,
        prices: snapshot!.props,
        data: data!,
        now: now,
        before: previous,
        after: telemetry,
      );
      if (change == null) continue;
      turn.generated = null;
      if (change.recompute &&
          analysis.kind != 'robust_rank' &&
          identical(analysis, lastAnalysis) &&
          analysisScores != null &&
          analysisValidation != null &&
          !busy) {
        try {
          final rebound = <AnalysisLeg>[];
          for (final leg in analysis.legs) {
            final event = snapshot!.board.events
                .where((e) => e.id == leg.event.id && e.startsAt.isAfter(now))
                .firstOrNull;
            if (event == null) throw StateError('Game unavailable');
            final player = buildGameResearch(
              data: data!,
              event: event,
              now: now,
            ).players.where((p) => p.id == leg.player.id).firstOrNull;
            if (player == null) throw StateError('Player unavailable');
            rebound.add(
              AnalysisLeg(
                player: player,
                event: event,
                metric: leg.metric,
                line: leg.line,
                over: leg.over,
              ),
            );
          }
          final updated = analysisEngine.run(
            legs: rebound,
            prices: snapshot!.props,
            data: data!,
            scores: analysisScores!,
            validation: analysisValidation!,
            now: now,
            stress: analysis.kind == 'stress_test',
            ticketPrice: null,
          );
          turn.analysis = updated;
          lastAnalysis = updated;
          turn.invalidation = null;
        } catch (_) {
          turn.invalidation = 'Changed inputs cannot be safely recomputed. Ask for a new analysis.';
        }
      } else {
        turn.invalidation = change.reason;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _send(String raw) async {
    final question = raw.trim();
    if (busy ||
        loading ||
        question.isEmpty ||
        question.length > 500 ||
        snapshot == null ||
        data == null) {
      return;
    }
    setState(() {
      busy = true;
      composer.clear();
    });
    final at = now;
    String resolved = question;
    String? planned;
    final directEvaluation = RegExp(
      r'coach.*perform|forecast results|model results|evaluation|benchmark',
    ).hasMatch(question.toLowerCase());
    if (api != null && !directEvaluation) {
      try {
        final plan = await api!
            .coachPlan({
              'question': question,
              'context': {
                'playerId': session.playerId,
                'eventId': session.eventId,
                'metric': session.metric?.key,
              },
            })
            .timeout(const Duration(seconds: 20));
        if (plan['query'] is String) {
          resolved = plan['query'] as String;
          planned = plan['tool'] as String?;
        }
      } catch (_) {
        /* A missing planner leaves explicit guided research available. */
      }
    }
    if (!mounted) return;
    CoachAnalysis? result;
    GameOutlook? game;
    Map<String, dynamic>? evaluation;
    LiveResearch? live;
    late CoachAnswer answer;
    final lower = resolved.toLowerCase();
    final wantsLive =
        planned != 'analyze_game' &&
        (planned == 'market_status' ||
            RegExp(
              r'injur|availab|inactive|scratch|news|reporter|beat writer|headline|weather|market|sharp|\bmoney\b|steam|movement|latest updates',
            ).hasMatch(lower));
    final wantsAnalysis =
        RegExp(
          r'\b(simulate|simulation|parlay|joint|stress|robust|rank|optimize)\b',
        ).hasMatch(lower) ||
        {'joint_probability', 'stress_test', 'robust_rank'}.contains(planned);
    final wantsEvaluation =
        directEvaluation ||
        RegExp(
          r'coach.*perform|forecast results|model results|evaluation|benchmark',
        ).hasMatch(lower);
    final wantsGame =
        (api != null || widget.gameAnalysisLoader != null) &&
        !wantsLive &&
        (planned == 'analyze_game' ||
            RegExp(
              r'\b(spreads?|totals?|moneyline|matchup|breakdown|analyze|explore|best bet|strongest|game outlook|forecast|projection|predict|wins?|winner|bet|bets)\b',
            ).hasMatch(lower));
    if (wantsEvaluation && (api != null || widget.evaluationLoader != null)) {
      try {
        evaluation =
            await (widget.evaluationLoader?.call() ??
                api!.forecastEvaluation());
        answer = CoachAnswer(
          title: 'Coach’s forecast record',
          text:
              '${evaluation['capturedGames'] ?? 0} games captured before kickoff; ${evaluation['gradedGames'] ?? 0} graded. This is automatic model evaluation, with no personal bet log. No proven edge or superiority is claimed.',
          intent: CoachIntent.evaluation,
        );
      } catch (_) {
        answer = const CoachAnswer(
          title: 'Evaluation unavailable',
          text: 'Forecast results could not be loaded. No performance figures are filled in.',
          intent: CoachIntent.clarify,
        );
      }
    } else if (wantsAnalysis) {
      try {
        await _analysisSources();
        final stress =
            lower.contains('stress') ||
            lower.contains('robust') ||
            lower.contains('rank') ||
            planned == 'stress_test' ||
            planned == 'robust_rank';
        final reuse =
            !RegExp(r'\b(over|under)\s+\d').hasMatch(lower) &&
            lastAnalysis != null;
        if (reuse &&
            turns.any(
              (t) =>
                  identical(t.analysis, lastAnalysis) && t.invalidation != null,
            )) {
          throw ArgumentError(
            'The previous inputs were withdrawn. Provide fresh explicit selections before running another analysis.',
          );
        }
        final ranking =
            lower.contains('rank') ||
            lower.contains('optimize') ||
            planned == 'robust_rank';
        final groups = ranking && !reuse
            ? resolved.split(
                RegExp(r'\bversus\b|\bvs\.?\s', caseSensitive: false),
              )
            : <String>[];
        final candidates = groups.length > 1
            ? [
                for (final group in groups)
                  analysisEngine.parse(
                    group,
                    board: snapshot!.board,
                    data: data!,
                    now: at,
                  ),
              ]
            : <List<AnalysisLeg>>[];
        final legs = reuse
            ? lastAnalysis!.legs
            : candidates.isNotEmpty
            ? candidates.expand((ticket) => ticket).toList()
            : analysisEngine.parse(
                resolved,
                board: snapshot!.board,
                data: data!,
                now: at,
              );
        if (!stress && legs.length < 2) {
          throw ArgumentError(
            'A joint-probability request needs at least two explicit legs. Use “stress test” for a single prop.',
          );
        }
        final quote = RegExp(
          r'ticket odds\s+(\d+(?:\.\d+)?)',
          caseSensitive: false,
        ).firstMatch(resolved);
        if (!ranking) {
          result = analysisEngine.run(
            legs: legs,
            prices: snapshot!.props,
            data: data!,
            scores: analysisScores!,
            validation: analysisValidation!,
            now: at,
            stress: stress,
            ticketPrice: quote == null ? null : double.parse(quote.group(1)!),
          );
        }
        if (ranking) {
          final ranked = analysisEngine.rank(
            candidates: candidates.isNotEmpty
                ? candidates
                : [
                    for (final leg in legs) [leg],
                  ],
            prices: snapshot!.props,
            data: data!,
            scores: analysisScores!,
            validation: analysisValidation!,
            now: at,
          );
          result = CoachAnalysis(
            legs: legs,
            createdAt: at,
            fingerprint: analysisFingerprint(legs, snapshot!.props, data!),
            kind: 'robust_rank',
            validation: analysisValidation!,
            summary: 'Research ranking by lowest chance across the SAME fixed stress scenarios. This is not a betting recommendation; high consistency does not imply positive EV.',
            rows: [
              for (final candidate in ranked)
                {
                  'scenario': candidate.legs
                      .map((leg) => leg.label)
                      .join(' + '),
                  'chance': candidate.rows.first['chance'],
                  'floor': candidate.rows
                      .map((r) => (r['chance'] as num).toDouble())
                      .reduce((a, b) => a < b ? a : b),
                },
            ],
          );
        }
        if (result == null) throw StateError('No analysis produced');
        lastAnalysis = result;
        answer = CoachAnswer(
          title: result.kind == 'robust_rank'
              ? 'Consistency under stress'
              : stress
              ? 'Stress-test results'
              : 'Joint-probability research',
          text: result.summary,
          intent: CoachIntent.evidence,
          event: legs.first.event,
          player: legs.first.player,
          metric: legs.first.metric,
          coverage: DateTime.tryParse('${data!.metadata['cutoff']}'),
        );
      } on ArgumentError catch (e) {
        answer = CoachAnswer(
          title: 'Let’s make the inputs explicit',
          text: '${e.message}',
          intent: CoachIntent.clarify,
        );
      } catch (_) {
        answer = const CoachAnswer(
          title: 'Analysis unavailable',
          text: 'The supplied selections or research records could not be safely simulated. Use exact names, supported stats, over/under and half-lines.',
          intent: CoachIntent.clarify,
        );
      }
    } else {
      answer = session.respond(
        resolved,
        board: snapshot!.board,
        prices: snapshot!.props,
        data: data!,
        playerIds: snapshot!.playerIdsByName,
        now: at,
      );
      if (wantsGame && answer.intent != CoachIntent.clarify) {
        try {
          final payload = <String, dynamic>{
            'question': resolved,
            'context': {
              'eventId': answer.event?.id ?? session.eventId,
              'bookId': selectedBookId,
            },
          };
          final raw =
              await (widget.gameAnalysisLoader?.call(payload) ??
                  api!.gameAnalysis(payload));
          if (!mounted) return;
          if (raw['available'] == true) {
            game = GameOutlook.fromJson(raw);
            answer = CoachAnswer(
              title: '${game.event.away} at ${game.event.home}',
              text: game.summary,
              intent: CoachIntent.gameAnalysis,
              event: game.event,
            );
            session.eventId = game.event.id;
            session.playerId = null;
          } else if (raw['reason'] == 'choose_game') {
            answer = CoachAnswer(
              title: 'Choose a matching game',
              text: 'I could not resolve an upcoming game for that request. Choose the exact matchup and date below.',
              intent: CoachIntent.clarify,
              games: [
                for (final item in raw['games'] as List? ?? [])
                  SportEvent.fromJson(Map<String, dynamic>.from(item)),
              ],
            );
          } else {
            answer = CoachAnswer(
              title: 'Game outlook unavailable',
              text: 'The full forecast could not be verified. Try again shortly; no probabilities or prices are filled in.',
              intent: CoachIntent.clarify,
            );
          }
        } catch (_) {
          answer = CoachAnswer(
            title: answer.title,
            text: 'The full game outlook could not load. Available source evidence remains below; no forecasts or prices are filled in.',
            intent: answer.intent,
            event: answer.event,
            player: answer.player,
            games: answer.games,
            players: answer.players,
          );
        }
      }
      if (wantsLive && answer.intent != CoachIntent.clarify) {
        await _pollTelemetry();
        if (!mounted) return;
        live = liveResearch(
          question: resolved,
          now: now,
          telemetry: telemetry,
          playerId: answer.player?.id,
          eventId: answer.event?.id,
        );
        answer = CoachAnswer(
          title: live.title,
          text: live.summary,
          intent: CoachIntent.live,
          event: answer.event,
          player: answer.player,
          metric: answer.metric,
          coverage: answer.coverage,
        );
      }
    }
    final turn = _Turn(question, answer, at)
      ..analysis = result
      ..game = game
      ..evaluation = evaluation
      ..live = live;
    if (result != null) {
      final issue = checkAnalysis(
        analysis: result,
        prices: snapshot!.props,
        data: data!,
        now: at,
        before: telemetry,
        after: telemetry,
      );
      turn.invalidation = issue?.reason;
    }
    setState(() {
      turns.add(turn);
      if (turns.length > 40) turns.removeAt(0);
    });
    _toEnd();
    if (aiConnected &&
        answer.intent != CoachIntent.clarify &&
        turn.invalidation == null &&
        (answer.player != null ||
            answer.event != null ||
            answer.intent == CoachIntent.live)) {
      try {
        final payload = answer.modelPayload(question, at);
        payload['context'] = {
          'playerId': answer.player?.id,
          'eventId': answer.event?.id,
          'metric': answer.metric.key,
          'analysisOverview': answer.intent == CoachIntent.gameAnalysis,
          'bookId': selectedBookId,
        };
        if (result != null) payload['toolEvidence'] = result.toEvidence();
        final reply = await (widget.ask?.call(payload) ?? api!.coach(payload))
            .timeout(const Duration(seconds: 140));
        if (!mounted) return;
        setState(() {
          if (reply.available) {
            turn.generated = reply;
          } else {
            turn.aiFailed = true;
          }
        });
      } catch (_) {
        if (mounted) setState(() => turn.aiFailed = true);
      }
    }
    if (mounted) setState(() => busy = false);
    _toEnd();
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    final target = turns.lastOrNull?.anchor.currentContext;
    if (mounted && target != null) {
      Scrollable.ensureVisible(
        target,
        alignment: 0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  });

  void _sources() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Behind Coach’s answers', style: CoachType.title),
            const SizedBox(height: 16),
            Text(
              aiConnected
                  ? 'AI interpretation uses only the supplied research evidence. Check each answer’s source details.'
                  : 'Guided data mode. Responses are calculated from saved records and supported question patterns. Open-ended AI interpretation is not connected on this deployment.',
              style: CoachType.body,
            ),
            const SizedBox(height: 16),
            Text(
              'Schedule: nflverse · CC BY 4.0\nChecked: ${snapshot == null ? 'Unavailable' : formatEastern(snapshot!.scheduleAt, year: true)}\nPlayer box scores through: ${data?.metadata['cutoff'] ?? 'Unknown'}\nPrices: The Odds API · limited pregame snapshots\nHistorical appearances are not confirmed rosters. Injury listings are unofficial, weather is a forecast, and headlines are attributed reports. Source availability is shown below.',
              style: CoachType.label,
            ),
            if (telemetryError != null)
              Text(
                telemetryError!,
                style: CoachType.label.copyWith(color: CoachColors.warn),
              ),
            if (telemetry != null) ...[
              const SizedBox(height: 12),
              for (final source in telemetry!.sources)
                Text(
                  '${source['id']}: ${source['state']}',
                  style: CoachType.label,
                ),
            ],
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: loading
                  ? null
                  : () {
                      Navigator.pop(context);
                      _load();
                    },
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Refresh research data'),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('coach-workspace'),
    backgroundColor: CoachColors.background,
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            child: Row(
              children: [
                const _CoachMark(),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Coach',
                        style: CoachType.title.copyWith(fontSize: 30),
                      ),
                      Text(
                        'THE RESEARCH DESK',
                        style: CoachType.label.copyWith(
                          fontSize: 9,
                          letterSpacing: 1.8,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('coach-sources'),
                  tooltip: 'Data and sources',
                  onPressed: _sources,
                  icon: const Icon(Icons.info_outline, size: 20),
                ),
                IconButton(
                  key: const Key('coach-new-chat'),
                  tooltip: 'New conversation',
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          turns.clear();
                          session.eventId = null;
                          session.playerId = null;
                          session.metric = null;
                          session.line = null;
                        }),
                  icon: const Icon(Icons.add, size: 22),
                ),
              ],
            ),
          ),
          const Divider(),
          if (loadError != null || snapshot?.stale(now) == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                loadError ?? 'Schedule snapshot is older than 24 hours. Refresh before using it.',
                style: CoachType.label.copyWith(
                  color: CoachColors.warn,
                  fontSize: 12,
                ),
              ),
            ),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: turns.isEmpty
                    ? _welcome()
                    : SingleChildScrollView(
                        key: const Key('coach-conversation'),
                        controller: scroll,
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [for (final turn in turns) _turn(turn)],
                        ),
                      ),
              ),
            ),
          ),
          if (busy) const LinearProgressIndicator(minHeight: 2),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: CoachColors.surface,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: CoachColors.border.withValues(alpha: .65),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: TextField(
                                key: const Key('coach-composer'),
                                controller: composer,
                                enabled: !busy && !loading && snapshot != null,
                                minLines: 1,
                                maxLines: 3,
                                maxLength: 500,
                                textInputAction: TextInputAction.send,
                                onSubmitted: _send,
                                decoration: const InputDecoration(
                                  hintText:
                                      'Ask about a player, game, or line…',
                                  counterText: '',
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  contentPadding: EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                ),
                              ),
                            ),
                            IconButton.filled(
                              key: const Key('coach-send'),
                              tooltip: 'Send to Coach',
                              onPressed: busy || loading || snapshot == null
                                  ? null
                                  : () => _send(composer.text),
                              style: IconButton.styleFrom(
                                backgroundColor: CoachColors.accent,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              icon: const Icon(Icons.north_east, size: 20),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      aiConnected
                          ? 'AI interpretation · verify the evidence and current prices'
                          : 'Guided data mode · open-ended AI not connected',
                      style: CoachType.label.copyWith(
                        fontSize: 10,
                        color: CoachColors.textTertiary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _welcome() => LayoutBuilder(
    builder: (context, box) {
      final wide = box.maxWidth >= 680;
      final headlineSize = wide ? 72.0 : 44.0;
      final prompts = ['Analyze a game', 'Find a player', 'Compare prices'];
      Widget prompt(int index) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: loading || snapshot == null
              ? null
              : () => _send(prompts[index]),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: CoachColors.border)),
            ),
            child: Row(
              children: [
                Text(
                  '0${index + 1}',
                  style: CoachType.label.copyWith(
                    fontSize: 10,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Text(
                    prompts[index],
                    style: CoachType.body.copyWith(fontWeight: FontWeight.w500),
                  ),
                ),
                const Icon(Icons.north_east, size: 17),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      );
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, wide ? 52 : 28, 24, 28),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: (box.maxHeight - (wide ? 80 : 56)).clamp(
              0,
              double.infinity,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  Container(width: 22, height: 2, color: CoachColors.accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'A DIFFERENT VIEW OF THE GAME',
                      style: CoachType.label.copyWith(
                        fontSize: 9,
                        letterSpacing: 1.7,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 30),
              Text(
                'Read the game.\nQuestion the line.',
                style: CoachType.display.copyWith(fontSize: headlineSize),
              ),
              const SizedBox(height: 24),
              Text(
                'Bring me a player, a game, or a line.\nWe’ll work through the evidence together.',
                style: CoachType.body.copyWith(
                  color: CoachColors.textSecondary,
                  fontSize: wide ? 17 : 14,
                ),
              ),
              SizedBox(height: wide ? 44 : 30),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < 3; i++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(right: i == 2 ? 0 : 24),
                          child: prompt(i),
                        ),
                      ),
                  ],
                )
              else
                for (var i = 0; i < 3; i++) prompt(i),
              const SizedBox(height: 20),
              if (loading)
                const Text('Loading the research…', style: CoachType.label)
              else if (snapshot == null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry loading data'),
                  ),
                )
              else
                Text(
                  'NFL / DATED RECORDS / SAVED PRICES',
                  style: CoachType.label.copyWith(
                    fontSize: 9,
                    letterSpacing: 1.1,
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );

  Widget _turn(_Turn turn) {
    final a = turn.answer;
    return Padding(
      key: turn.anchor,
      padding: const EdgeInsets.only(bottom: 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.only(left: 32, bottom: 28),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: CoachColors.surfaceHigh,
                border: const Border(
                  left: BorderSide(color: CoachColors.textTertiary, width: 2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'YOUR QUESTION',
                    style: CoachType.label.copyWith(
                      fontSize: 9,
                      letterSpacing: 1.4,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(turn.question, style: CoachType.body),
                ],
              ),
            ),
          ),
          Row(
            children: [
              const _CoachMark(size: 24),
              const SizedBox(width: 8),
              Text(
                'Coach',
                style: CoachType.body.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  turn.generated != null
                      ? 'AI interpretation'
                      : 'Evidence response',
                  style: CoachType.label.copyWith(fontSize: 10),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(a.title, style: CoachType.title.copyWith(fontSize: 22)),
          const SizedBox(height: 12),
          SelectableText(
            turn.invalidation ??
                turn.liveNotice ??
                (turn.game != null
                    ? a.text
                    : turn.generated?.answer ??
                          turn.analysis?.summary ??
                          a.text),
            style: CoachType.body,
          ),
          if (turn.game != null &&
              turn.generated != null &&
              turn.invalidation == null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SelectableText(
                turn.generated!.answer,
                style: CoachType.body,
              ),
            ),
          if (turn.aiFailed)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'AI interpretation is unavailable. Showing the calculated evidence response.',
                style: CoachType.label.copyWith(
                  color: CoachColors.warn,
                  fontSize: 11,
                ),
              ),
            ),
          if (a.evidenceNotice != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                a.evidenceNotice!,
                style: CoachType.label.copyWith(
                  color: CoachColors.warn,
                  fontSize: 12,
                ),
              ),
            ),
          for (final e in a.games)
            _choice(
              '${e.away} at ${e.home}',
              formatEastern(e.startsAt),
              () => _send('Explore ${e.away} at ${e.home}'),
            ),
          for (final p in a.players)
            _choice(
              p.name,
              '${p.position} · ${p.team} · recorded participant',
              () => _send('Show evidence for ${p.name}'),
            ),
          if (turn.analysis != null && turn.invalidation == null)
            _analysisView(turn.analysis!),
          if (turn.game != null && turn.invalidation == null) _gameView(turn),
          if (turn.evaluation != null) _evaluationView(turn.evaluation!),
          if (turn.live != null) _liveView(turn),
          if (a.player != null &&
              turn.invalidation == null &&
              a.intent != CoachIntent.live) ...[
            const SizedBox(height: 16),
            if (turn.analysis != null)
              const SizedBox.shrink()
            else if (a.intent == CoachIntent.prices)
              _priceCards(a)
            else if (a.intent == CoachIntent.history)
              _history(a)
            else if (a.intent == CoachIntent.evidence)
              _chart(a),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in a.player!.metrics)
                  _DeskLink(
                    label: Text(m.shortLabel),
                    onPressed: busy
                        ? null
                        : () => _send(
                            'Show ${a.player!.name} ${m.label.toLowerCase()} evidence',
                          ),
                  ),
                for (final action in [
                  'Compare saved prices',
                  'What changed?',
                  'Challenge this',
                  'Show recorded games',
                ])
                  _DeskLink(
                    label: Text(action),
                    onPressed: busy ? null : () => _follow(a, action),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              'Sources & limits',
              style: CoachType.label.copyWith(fontSize: 11),
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Research checked ${formatEastern(turn.at, year: true)}.\n${a.coverage == null ? 'Schedule: nflverse · CC BY 4.0' : 'Box scores through ${a.coverage!.toIso8601String().substring(0, 10)} · nflverse · CC BY 4.0'}\nHistorical participants are not confirmed rosters. Saved prices may have changed. Settlement rules are unverified. No validated prop probability or edge is supplied.'
                    '${turn.generated == null ? '' : '\nAI used: ${turn.generated!.cited.map((id) => assistantInputLabels[id] ?? id).join(', ')}'}',
                    style: CoachType.label.copyWith(fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _gameView(_Turn turn) {
    final game = turn.game!, score = game.score;
    final books = (game.raw['books'] as List? ?? []).whereType<Map>();
    String number(dynamic value) =>
        value is num ? value.toStringAsFixed(1) : '—';
    String percentage(dynamic value) =>
        value is num ? '${(100 * value).toStringAsFixed(1)}%' : '—';
    Widget caption(String text) =>
        Text(text, style: CoachType.label.copyWith(fontSize: 11));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        caption(
          '${formatEastern(game.event.startsAt, year: true)} · Evidence through ${game.raw['cutoff']}',
        ),
        const SizedBox(height: 12),
        Text(
          '${game.event.away} ${number(score['away'])}  /  ${game.event.home} ${number(score['home'])}',
          style: CoachType.title.copyWith(fontSize: 21),
        ),
        const SizedBox(height: 6),
        caption(
          game.basis == 'market_anchored'
              ? 'Market-anchored score outlook. This is not an independent prediction of an edge.'
              : 'Experimental score outlook. The score-only candidate did not beat the historical market baseline.',
        ),
        const SizedBox(height: 8),
        if (game.raw['marketAsOf'] != null)
          caption(
            'Market observations from ${_reportTime(game.raw['marketAsOf'])}; offers may have changed.',
          ),
        caption(
          'Median home margin: ${number(score['marginMedian'])}. Median total: ${number(score['totalMedian'])}.',
        ),
        caption(
          'Central 80% research ranges · Margin ${score['marginRange']?.join(' to ')} · Total ${score['totalRange']?.join(' to ')}',
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            ChoiceChip(
              label: const Text('All books'),
              selected: game.raw['bookId'] == null,
              onSelected: busy
                  ? null
                  : (_) {
                      selectedBookId = null;
                      session.eventId = game.event.id;
                      _send(turn.question);
                    },
            ),
            for (final book in books)
              ChoiceChip(
                label: Text('${book['name']}'),
                selected: game.raw['bookId'] == book['id'],
                onSelected: busy
                    ? null
                    : (_) {
                        selectedBookId = book['id'] as String;
                        session.eventId = game.event.id;
                        _send(turn.question);
                      },
              ),
          ],
        ),
        for (final category in game.categories)
          Container(
            margin: const EdgeInsets.only(top: 20),
            padding: const EdgeInsets.only(top: 16),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: CoachColors.border)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${category['label']}',
                  style: CoachType.title.copyWith(fontSize: 19),
                ),
                if (category['market'] == 'spreads')
                  caption(
                    'Research median margin: ${number(score['marginMedian'])} for the home team.',
                  ),
                if (category['market'] == 'totals')
                  caption(
                    'Research median total: ${number(score['totalMedian'])} points.',
                  ),
                if (category['market'] == 'h2h')
                  caption(
                    'Home win ${percentage(score['homeWin'])} · Away win ${percentage(1 - (score['homeWin'] as num) - (score['tie'] as num))} · Tie ${percentage(score['tie'])}',
                  ),
                if ((category['rows'] as List).isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: caption(
                      game.raw['bookId'] == null
                          ? 'No saved price for this market.'
                          : 'No saved price at the selected book.',
                    ),
                  ),
                for (final row in (category['rows'] as List).take(2))
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Builder(
                      builder: (context) {
                        final selection = Selection.fromJson(
                          Map<String, dynamic>.from(row['selection']),
                        );
                        final minimum = row['minimumDecimal'];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${selection.label} · ${americanLabel((row['decimal'] as num).toDouble())} at ${row['book']}',
                              style: CoachType.body.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            caption(
                              'Research chance ${percentage(row['win'])} · Push ${percentage(row['push'])}',
                            ),
                            if (minimum is num &&
                                minimum > 1 &&
                                minimum.isFinite)
                              caption(
                                'Model-fair price ${americanLabel(minimum.toDouble())}. Conditional return ${number(100 * (row['conditionalEv'] as num))}% per unit; assumptions unvalidated.',
                              ),
                            caption(
                              'Observed ${_reportTime(row['sourceAt'])}. Price may have changed; settlement rules unverified.',
                            ),
                            if (row['blocked'] == true)
                              Text(
                                '${row['reason']}',
                                style: CoachType.label.copyWith(
                                  color: CoachColors.warn,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                if ((category['totalRows'] as num? ?? 0) > 2)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: caption(
                      'Showing two of ${category['totalRows']} exact price observations.',
                    ),
                  ),
              ],
            ),
          ),
        if (game.projections.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            'Player workload outlook',
            style: CoachType.title.copyWith(fontSize: 19),
          ),
          caption(
            'Conditional on the recorded role and participation. Opponent and role-change adjustments are not validated.',
          ),
          for (final projection in game.projections.take(6))
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${projection['name']} · ${projection['label']}: ${number(projection['mean'])}',
                    style: CoachType.body,
                  ),
                  caption(
                    '${number(projection['expectedWorkload'])} ${projection['workload']} · ${projection['records']} recorded appearances',
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 12),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            'Validation & what could change this',
            style: CoachType.label,
          ),
          children: [
            for (final limit in game.raw['limits'] as List)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: caption('$limit'),
                ),
              ),
            caption(
              'A new injury report, role change, different line or price, or kickoff can make this outlook unsuitable. Refresh before relying on saved observations.',
            ),
          ],
        ),
        Wrap(
          spacing: 14,
          children: [
            _DeskLink(
              label: const Text('Refresh game analysis'),
              onPressed: busy
                  ? null
                  : () {
                      session.eventId = game.event.id;
                      _send(turn.question);
                    },
            ),
            _DeskLink(
              label: const Text('How is Coach performing?'),
              onPressed: busy ? null : () => _send('Coach performance'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _evaluationView(Map<String, dynamic> report) {
    const labels = {
      'h2h': 'Moneyline',
      'spreads': 'Spread',
      'totals': 'Game total',
      'props': 'Player props',
    };
    String value(dynamic number) =>
        number is num ? number.toStringAsFixed(3) : '—';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          '${report['pendingGames'] ?? 0} games awaiting results · ${report['unresolved'] ?? 0} selections awaiting participation data',
          style: CoachType.label,
        ),
        for (final row in report['markets'] as List? ?? [])
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${labels[row['market']] ?? row['market']} · ${row['games']} graded games',
                  style: CoachType.body.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  'Forecast error: ${value(row['brier'])}. Lower is better.',
                  style: CoachType.label,
                ),
                if ((row['baselineGames'] as num? ?? 0) > 0)
                  Text(
                    'Same-observation comparison on ${row['baselineGames']} games: Coach ${value(row['pairedBrier'])}, market/reference ${value(row['baselineBrier'])}.',
                    style: CoachType.label,
                  ),
                if ((row['aiGames'] as num? ?? 0) > 0)
                  Text(
                    'Paired generic-model baseline on ${row['aiGames']} games: Coach ${value(row['aiPairedBrier'])}, AI ${value(row['aiBrier'])}.',
                    style: CoachType.label,
                  ),
              ],
            ),
          ),
        if (report['historical'] is Map)
          _researchProgress(Map<String, dynamic>.from(report['historical'])),
        for (final model in report['models'] as List? ?? [])
          if (model['role'] == 'shadow')
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                'Background challenger: ${model['gradedGames'] ?? 0} graded games · ${model['pendingGames'] ?? 0} awaiting results. Separate from the serving model.',
                style: CoachType.label,
              ),
            ),
        const SizedBox(height: 14),
        Text(
          '${report['notice'] ?? 'No settled forecasts yet. No profits or predictive advantage are claimed.'}',
          style: CoachType.label,
        ),
      ],
    );
  }

  Widget _researchProgress(Map<String, dynamic> lab) {
    const labels = {
      'moneyline': 'Moneyline',
      'spreads': 'Spread',
      'totals': 'Game total',
    };
    final markets = lab['markets'] as Map? ?? {};
    String error(dynamic v) => v is num ? v.toStringAsFixed(3) : '—';
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(
          'Research progress',
          style: CoachType.title.copyWith(fontSize: 20),
        ),
        subtitle: Text(
          'A research candidate is being tested in the background.',
          style: CoachType.label,
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Evidence through ${lab['cutoff'] ?? 'the dated research source'}. Settings selected using seasons before 2025. Retrospective evaluation on ${lab['evaluationGames']} later games; counts vary by available market and pushes.',
                  style: CoachType.label,
                ),
                const SizedBox(height: 12),
                for (final name in labels.keys)
                  if (markets[name] is Map)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${labels[name]} · ${markets[name]['games']} games',
                            style: CoachType.body.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'Forecast error · Current ${error(markets[name]['incumbentBrier'])} / Candidate ${error(markets[name]['brier'])} / Market ${error(markets[name]['marketBrier'])}',
                            style: CoachType.label,
                          ),
                        ],
                      ),
                    ),
                Text(
                  'Lower error is better. The candidate remains experimental and is not used for recommendations. Historical closing prices do not establish obtainable returns or superiority to AI.',
                  style: CoachType.label,
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _liveView(_Turn turn) {
    final live = turn.live!;
    final visible = turn.liveNotice == null
        ? live.rows.where((row) => currentObservation(row, now)).take(12)
        : <TelemetryObservation>[];
    const labels = {
      'injuries': 'Availability',
      'beat_writers': 'Reporter headlines',
      'markets': 'Saved prices',
      'market_movement': 'Price movement',
      'sharp_money': 'Verified sharp money',
      'betting_splits': 'Reported betting shares',
      'weather': 'Weather',
    };
    const states = {
      'reported_unofficial': 'Provider reports',
      'attributed_headlines': 'Connected',
      'attributed_feed': 'Provider-reported shares',
      'forecast_only': 'Forecast only',
      'published_snapshots_only': 'Snapshot data',
      'saved_observations': 'Tracking saved observations',
      'waiting_for_prices': 'Waiting for current prices',
      'provider_required': 'Provider needed',
      'not_connected': 'Not connected',
      'unavailable': 'Unavailable',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in visible)
          Container(
            margin: const EdgeInsets.only(top: 18),
            padding: const EdgeInsets.only(top: 16),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: CoachColors.border)),
            ),
            child: Builder(
              builder: (context) {
                final v = row.value;
                final title = switch (row.kind) {
                  'injury' =>
                    '${playerNames[row.playerId] ?? 'Player'} · ${v['status']}',
                  'news' => '${v['title']}',
                  'weather' =>
                    v['roof'] != null
                        ? 'Roof: ${v['roof']}'
                        : '${v['temperature']}°${v['unit'] ?? ''} · ${v['forecast'] ?? 'Forecast'}',
                  _ =>
                    v['signalType'] == 'betting_splits'
                        ? '${v['outcome']} · ${v['market']}'
                        : v['fromDecimal'] != null
                        ? '${v['participant'] ?? 'Market'} · ${v['outcome'] ?? ''}'
                        : 'Saved price snapshot',
                };
                final detail = switch (row.kind) {
                  'injury' =>
                    'Reported ${_reportTime(v['reportedUpdatedAt'])}. This listing does not confirm availability for the next game.',
                  'news' =>
                    '${v['author'] ?? 'ESPN'} · Published ${_reportTime(v['publishedAt'])}',
                  'weather' =>
                    '${v['windSpeed'] == null ? 'Schedule roof metadata' : 'Wind ${v['windSpeed']}'} · Forecast, not observed game conditions.',
                  _ =>
                    v['signalType'] == 'betting_splits'
                        ? '${v['betPercent']}% of bets · ${v['moneyPercent']}% of money. Provider-reported shares do not identify professional bettors.'
                        : v['fromDecimal'] != null
                        ? '${v['book'] ?? 'Book'}: ${v['fromLine'] ?? ''} at ${v['fromDecimal']} → ${v['toLine'] ?? ''} at ${v['toDecimal']}\n${_reportTime(v['fromSourceAt'])} → ${_reportTime(v['toSourceAt'])}. Saved observations, not sharp-money flow.'
                        : '${v['quoteCount'] ?? 0} saved observations. Original snapshot ${_reportTime(v['snapshotAt'])}.',
                };
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: CoachType.body.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(detail, style: CoachType.label),
                    const SizedBox(height: 5),
                    Text(
                      '${row.source} · Checked ${formatEastern(row.observedAt, year: true)}',
                      style: CoachType.label.copyWith(fontSize: 10),
                    ),
                    if (v['url'] is String)
                      _DeskLink(
                        label: const Text('Read source'),
                        onPressed: () => _openReport(v['url'] as String),
                      ),
                  ],
                );
              },
            ),
          ),
        if (live.rows.length > 12 && turn.liveNotice == null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Showing 12 of ${live.rows.length} matching reports. Ask about a specific player or game to narrow the evidence.',
              style: CoachType.label,
            ),
          ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            for (final source in live.sources)
              Text(
                '${labels[source['id']] ?? source['id']}: ${states[source['state']] ?? source['state']}',
                style: CoachType.label.copyWith(fontSize: 10),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _DeskLink(
          label: const Text('Check latest updates'),
          onPressed: busy
              ? null
              : () {
                  session.eventId = turn.answer.event?.id;
                  session.playerId = turn.answer.player?.id;
                  _send(turn.question);
                },
        ),
      ],
    );
  }

  String _reportTime(dynamic value) {
    final date = value is String ? DateTime.tryParse(value) : null;
    return date == null ? 'time unavailable' : formatEastern(date, year: true);
  }

  Future<void> _openReport(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) return;
    if (openSourceLink(uri)) return;
    await Clipboard.setData(ClipboardData(text: uri.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Source link copied')));
    }
  }

  void _follow(CoachAnswer answer, String action) {
    // A button on an earlier response explicitly restores that subject.
    session.eventId = answer.event?.id;
    session.playerId = answer.player?.id;
    session.metric = answer.metric;
    session.line = answer.line;
    _send(
      '$action for ${answer.player!.name} ${answer.metric.label.toLowerCase()}${answer.line == null ? '' : ' line ${answer.line}'}',
    );
  }

  Widget _choice(String title, String subtitle, VoidCallback action) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      title: Text(title, style: CoachType.body),
      subtitle: Text(subtitle, style: CoachType.label.copyWith(fontSize: 11)),
      trailing: const Icon(
        Icons.arrow_forward,
        size: 18,
        color: CoachColors.accent,
      ),
      onTap: busy ? null : action,
    ),
  );

  Widget _priceCards(CoachAnswer answer) {
    final groups = <String, List<OddsQuote>>{};
    for (final q in answer.quotes) {
      if (answer.event!.startsAt.isAfter(now) &&
          now.difference(q.sourceAt) <= const Duration(hours: 18) &&
          now.difference(q.collectedAt) <= const Duration(hours: 18)) {
        (groups[q.selection.key] ??= []).add(q);
      }
    }
    if (groups.isEmpty) {
      return Text(
        'No unexpired saved prices for this selection. Ask for performance or another line.',
        style: CoachType.label,
      );
    }
    final lines =
        groups.values
            .map((list) => list.first.selection.point!)
            .toSet()
            .toList()
          ..sort();
    final selected = answer.line ?? lines.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Saved snapshots · confirm current prices',
          style: CoachType.label.copyWith(
            color: CoachColors.warn,
            fontSize: 11,
          ),
        ),
        if (lines.length > 1)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final value in lines)
                _DeskLink(
                  label: Text('Line $value'),
                  onPressed: busy
                      ? null
                      : () {
                          session.eventId = answer.event?.id;
                          session.playerId = answer.player?.id;
                          session.metric = answer.metric;
                          session.line = value;
                          _send(
                            'Compare ${answer.player!.name} ${answer.metric.label.toLowerCase()} line $value',
                          );
                        },
                ),
            ],
          ),
        for (final list in groups.values.where(
          (list) => list.first.selection.point == selected,
        ))
          Builder(
            builder: (_) {
              list.sort((a, b) => b.decimal.compareTo(a.decimal));
              final best = list.first;
              return ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  '${best.selection.outcome} ${best.selection.point} · ${americanLabel(best.decimal)}',
                  style: CoachType.number.copyWith(fontSize: 21),
                ),
                subtitle: Text(
                  '${best.book} · highest saved · ${list.length} books\nSource ${formatEastern(best.sourceAt)} · ${best.eligible(now) ? 'recent' : 'outdated'} snapshot',
                  style: CoachType.label.copyWith(fontSize: 11),
                ),
                children: [
                  for (final q in list)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(q.book, style: CoachType.body),
                      trailing: Text(
                        americanLabel(q.decimal),
                        style: CoachType.number.copyWith(fontSize: 20),
                      ),
                      subtitle: Text(
                        'Source ${formatEastern(q.sourceAt, year: true)}\nChecked ${formatEastern(q.collectedAt, year: true)}',
                        style: CoachType.label.copyWith(fontSize: 10),
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _chart(CoachAnswer a) {
    final games = a.player!.games.take(10).toList().reversed.toList();
    final values = games.map((g) => g.stats[a.metric.key]).toList();
    final max = values.whereType<num>().fold<double>(
      1,
      (v, n) => n.abs() > v ? n.abs().toDouble() : v,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recorded ${a.metric.label.toLowerCase()} · oldest → newest',
          style: CoachType.label.copyWith(fontSize: 11),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 100,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < games.length; i++)
                Expanded(
                  child: Tooltip(
                    message:
                        '${games[i].date.toIso8601String().substring(0, 10)}: ${values[i] ?? 'missing'}',
                    child: Semantics(
                      label:
                          'Week ${games[i].week}: ${values[i] ?? 'missing'} ${a.metric.label}',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (values[i] == null)
                              const Text('—')
                            else
                              Container(
                                height: (values[i]!.abs() / max * 70)
                                    .clamp(2, 70)
                                    .toDouble(),
                                decoration: BoxDecoration(
                                  color: values[i]! < 0
                                      ? CoachColors.warn
                                      : CoachColors.accent.withValues(
                                          alpha: .75,
                                        ),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            const SizedBox(height: 6),
                            Text(
                              'W${games[i].week}',
                              style: CoachType.label.copyWith(fontSize: 9),
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
        const SizedBox(height: 8),
        Text(
          'Negative values are amber; missing values stay blank. Historical production is not a forecast.',
          style: CoachType.label.copyWith(fontSize: 10),
        ),
      ],
    );
  }

  Widget _analysisView(CoachAnalysis analysis) {
    String pct(num value) => '${(value * 100).toStringAsFixed(1)}%';
    final sim = analysis.simulation;
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'EXPERIMENTAL / NO VALIDATED BETTING EDGE',
            style: CoachType.label.copyWith(
              color: CoachColors.warn,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 10),
          for (final leg in analysis.legs)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(leg.label, style: CoachType.label),
            ),
          if (sim != null) ...[
            const SizedBox(height: 16),
            Text(
              'Joint ${pct(sim.joint)}  /  Independent ${pct(sim.independent)}',
              style: CoachType.number.copyWith(fontSize: 23),
            ),
            const SizedBox(height: 8),
            Text(
              'Sampling-only interval ${pct(sim.lower)}–${pct(sim.upper)}. Excludes model and data uncertainty.',
              style: CoachType.label,
            ),
            Text(
              '10,000 seeded draws · correlation training uses only earlier seasons. Minimum paired observations: ${sim.training.expand((m) => [for (var i = 6; i < m.pairs.length; i++)
                        for (var j = 6; j < i; j++) m.pairs[i][j]]).fold<int>(999999, (a, b) => a < b ? a : b) == 999999 ? 'n/a' : sim.training.expand((m) => [for (var i = 6; i < m.pairs.length; i++)
                      for (var j = 6; j < i; j++) m.pairs[i][j]]).reduce((a, b) => a < b ? a : b)}.',
              style: CoachType.label.copyWith(fontSize: 11),
            ),
          ],
          const SizedBox(height: 16),
          for (final row in analysis.rows)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: CoachColors.border)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text('${row['scenario']}', style: CoachType.label),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    '${pct((row['floor'] ?? row['chance']) as num)}${row.containsKey('floor') ? ' floor' : ''}',
                    style: CoachType.number.copyWith(fontSize: 18),
                  ),
                ],
              ),
            ),
          if (analysis.conditionalEv != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                'Conditional EV: ${(analysis.conditionalEv! * 100).toStringAsFixed(1)}% per unit using USER-ENTERED, UNVERIFIED ticket decimal ${analysis.ticketPrice}. This is assumption-based arithmetic, not an established edge.',
                style: CoachType.label.copyWith(color: CoachColors.warn),
              ),
            ),
          const SizedBox(height: 14),
          Text(
            'Dependence validation: ${analysis.validation['uniqueGames']} unique games; adopted ${analysis.validation['adopted']}; profitability established: false. Recorded participants are not confirmed rosters. ${telemetry == null ? 'Availability telemetry is not connected.' : 'Availability must be checked separately against source status.'}',
            style: CoachType.label.copyWith(fontSize: 11),
          ),
          const SizedBox(height: 12),
          _DeskLink(
            label: const Text('Stress this ticket'),
            onPressed: busy
                ? null
                : () {
                    lastAnalysis = analysis;
                    _send('Stress this ticket');
                  },
          ),
        ],
      ),
    );
  }

  Widget _history(CoachAnswer a) => Column(
    children: [
      for (final g in a.player!.games.take(20))
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('vs ${g.opponent}', style: CoachType.body),
          subtitle: Text(
            '${g.date.toIso8601String().substring(0, 10)} · Week ${g.week}',
            style: CoachType.label.copyWith(fontSize: 11),
          ),
          trailing: Text(
            '${g.stats[a.metric.key] ?? '—'}',
            style: CoachType.number.copyWith(fontSize: 20),
          ),
        ),
    ],
  );
}

class _DeskLink extends StatelessWidget {
  const _DeskLink({required this.label, required this.onPressed});
  final Widget label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onPressed,
    child: Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: CoachColors.border)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: DefaultTextStyle(
              style: CoachType.label.copyWith(
                color: onPressed == null
                    ? CoachColors.textTertiary
                    : CoachColors.text,
              ),
              child: label,
            ),
          ),
          const SizedBox(width: 10),
          const Icon(Icons.north_east, size: 12),
        ],
      ),
    ),
  );
}

class _CoachMark extends StatelessWidget {
  const _CoachMark({this.size = 34});
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(
      painter: const _DeskMark(),
      child: Center(
        child: Text('C', style: CoachType.title.copyWith(fontSize: size * .72)),
      ),
    ),
  );
}

class _DeskMark extends CustomPainter {
  const _DeskMark();
  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..color = CoachColors.accent
      ..strokeWidth = 1.3
      ..style = PaintingStyle.stroke;
    final edge = size.width * .3;
    canvas.drawPath(
      Path()
        ..moveTo(0, edge)
        ..lineTo(0, 0)
        ..lineTo(edge, 0)
        ..moveTo(size.width - edge, size.height)
        ..lineTo(size.width, size.height)
        ..lineTo(size.width, size.height - edge),
      pen,
    );
  }

  @override
  bool shouldRepaint(covariant _DeskMark oldDelegate) => false;
}
