import 'dart:async';

import 'package:flutter/material.dart';

import '../data/nfl_assets.dart';
import '../data/published_snapshot.dart';
import '../data/repository.dart';
import '../domain/assistant.dart';
import '../domain/coach_session.dart';
import '../domain/eastern.dart';
import '../domain/odds.dart';
import '../domain/player_stats.dart';
import '../theme/edge_theme.dart';

class CoachWorkspace extends StatefulWidget {
  const CoachWorkspace({
    super.key,
    this.snapshotLoader,
    this.playerLoader,
    this.ask,
    this.clock,
  });
  final Future<PublishedSnapshot> Function()? snapshotLoader;
  final Future<PlayerStatsDataset> Function()? playerLoader;
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
  DateTime get now => widget.clock?.call().toUtc() ?? DateTime.now().toUtc();
  bool get aiConnected => widget.ask != null || api != null;

  @override
  void initState() {
    super.initState();
    _load();
    clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    clockTimer?.cancel();
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
      if (mounted) setState(() => loading = false);
    }
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
    final at = now;
    final answer = session.respond(
      question,
      board: snapshot!.board,
      prices: snapshot!.props,
      data: data!,
      playerIds: snapshot!.playerIdsByName,
      now: at,
    );
    final turn = _Turn(question, answer, at);
    setState(() {
      composer.clear();
      turns.add(turn);
      if (turns.length > 40) turns.removeAt(0);
      busy = true;
    });
    _toEnd();
    if (aiConnected &&
        answer.intent != CoachIntent.clarify &&
        (answer.player != null || answer.event != null)) {
      try {
        final payload = answer.modelPayload(question, at);
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
            Text('Behind Coach’s answers', style: EdgeType.title),
            const SizedBox(height: 16),
            Text(
              aiConnected
                  ? 'AI interpretation uses only the supplied research evidence. Check each answer’s source details.'
                  : 'Guided data mode. Responses are calculated from saved records and supported question patterns. Open-ended AI interpretation is not connected on this deployment.',
              style: EdgeType.body,
            ),
            const SizedBox(height: 16),
            Text(
              'Schedule: nflverse · CC BY 4.0\nChecked: ${snapshot == null ? 'Unavailable' : formatEastern(snapshot!.scheduleAt, year: true)}\nPlayer box scores through: ${data?.metadata['cutoff'] ?? 'Unknown'}\nPrices: The Odds API · limited pregame snapshots\nHistorical appearances are not confirmed rosters. No verified current injury or weather feed is supplied here.',
              style: EdgeType.label,
            ),
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
    backgroundColor: EdgeColors.background,
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
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
                        style: EdgeType.title.copyWith(fontSize: 21),
                      ),
                      Text(
                        'SPORTS RESEARCH',
                        style: EdgeType.label.copyWith(
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
                  icon: const Icon(Icons.edit_square, size: 20),
                ),
              ],
            ),
          ),
          if (loadError != null || snapshot?.stale(now) == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                loadError ?? 'Schedule snapshot is older than 24 hours. Refresh before using it.',
                style: EdgeType.label.copyWith(
                  color: EdgeColors.warn,
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
                        color: EdgeColors.surface,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: EdgeColors.border.withValues(alpha: .65),
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
                              icon: const Icon(Icons.arrow_upward, size: 20),
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
                      style: EdgeType.label.copyWith(
                        fontSize: 10,
                        color: EdgeColors.textTertiary,
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
    builder: (context, constraints) => SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: (constraints.maxHeight - 48).clamp(0, double.infinity),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A clearer read.\nOne conversation.',
              style: EdgeType.display.copyWith(
                fontSize: 40,
                fontWeight: FontWeight.w500,
                height: 1.13,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Bring me a game, a player, or a line.\nWe’ll work through the evidence together.',
              style: EdgeType.body.copyWith(color: EdgeColors.textSecondary),
            ),
            const SizedBox(height: 28),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final prompt in [
                  'Brief me',
                  'Find a player',
                  'Compare prices',
                ])
                  ActionChip(
                    label: Text(prompt),
                    onPressed: loading || snapshot == null
                        ? null
                        : () => _send(prompt),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            if (loading)
              const Text('Loading the research…', style: EdgeType.label)
            else if (snapshot == null)
              TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry loading data'),
              )
            else
              Text(
                'NFL · saved prices and dated player records',
                style: EdgeType.label.copyWith(
                  fontSize: 11,
                  color: EdgeColors.textTertiary,
                ),
              ),
          ],
        ),
      ),
    ),
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
                color: EdgeColors.surfaceHigh,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(turn.question, style: EdgeType.body),
            ),
          ),
          Row(
            children: [
              const _CoachMark(size: 24),
              const SizedBox(width: 8),
              Text(
                'Coach',
                style: EdgeType.body.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  turn.generated != null
                      ? 'AI interpretation'
                      : 'Evidence response',
                  style: EdgeType.label.copyWith(fontSize: 10),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(a.title, style: EdgeType.title.copyWith(fontSize: 22)),
          const SizedBox(height: 12),
          SelectableText(
            turn.generated?.answer ?? a.text,
            style: EdgeType.body,
          ),
          if (turn.aiFailed)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'AI interpretation is unavailable. Showing the calculated evidence response.',
                style: EdgeType.label.copyWith(
                  color: EdgeColors.warn,
                  fontSize: 11,
                ),
              ),
            ),
          if (a.evidenceNotice != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                a.evidenceNotice!,
                style: EdgeType.label.copyWith(
                  color: EdgeColors.warn,
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
          if (a.player != null) ...[
            const SizedBox(height: 16),
            if (a.intent == CoachIntent.prices)
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
                  ActionChip(
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
                  ActionChip(
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
              style: EdgeType.label.copyWith(fontSize: 11),
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Research checked ${formatEastern(turn.at, year: true)}.\n${a.coverage == null ? 'Schedule: nflverse · CC BY 4.0' : 'Box scores through ${a.coverage!.toIso8601String().substring(0, 10)} · nflverse · CC BY 4.0'}\nHistorical participants are not confirmed rosters. Saved prices may have changed. Settlement rules are unverified. No validated prop probability or edge is supplied.'
                    '${turn.generated == null ? '' : '\nAI used: ${turn.generated!.cited.map((id) => assistantInputLabels[id] ?? id).join(', ')}'}',
                    style: EdgeType.label.copyWith(fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
      title: Text(title, style: EdgeType.body),
      subtitle: Text(subtitle, style: EdgeType.label.copyWith(fontSize: 11)),
      trailing: const Icon(
        Icons.arrow_forward,
        size: 18,
        color: EdgeColors.accent,
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
        style: EdgeType.label,
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
          style: EdgeType.label.copyWith(color: EdgeColors.warn, fontSize: 11),
        ),
        if (lines.length > 1)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final value in lines)
                ActionChip(
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
                  style: EdgeType.number.copyWith(fontSize: 21),
                ),
                subtitle: Text(
                  '${best.book} · highest saved · ${list.length} books\nSource ${formatEastern(best.sourceAt)} · ${best.eligible(now) ? 'recent' : 'outdated'} snapshot',
                  style: EdgeType.label.copyWith(fontSize: 11),
                ),
                children: [
                  for (final q in list)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(q.book, style: EdgeType.body),
                      trailing: Text(
                        americanLabel(q.decimal),
                        style: EdgeType.number.copyWith(fontSize: 20),
                      ),
                      subtitle: Text(
                        'Source ${formatEastern(q.sourceAt, year: true)}\nChecked ${formatEastern(q.collectedAt, year: true)}',
                        style: EdgeType.label.copyWith(fontSize: 10),
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
          style: EdgeType.label.copyWith(fontSize: 11),
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
                                      ? EdgeColors.warn
                                      : EdgeColors.accent.withValues(
                                          alpha: .75,
                                        ),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            const SizedBox(height: 6),
                            Text(
                              'W${games[i].week}',
                              style: EdgeType.label.copyWith(fontSize: 9),
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
          style: EdgeType.label.copyWith(fontSize: 10),
        ),
      ],
    );
  }

  Widget _history(CoachAnswer a) => Column(
    children: [
      for (final g in a.player!.games.take(20))
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('vs ${g.opponent}', style: EdgeType.body),
          subtitle: Text(
            '${g.date.toIso8601String().substring(0, 10)} · Week ${g.week}',
            style: EdgeType.label.copyWith(fontSize: 11),
          ),
          trailing: Text(
            '${g.stats[a.metric.key] ?? '—'}',
            style: EdgeType.number.copyWith(fontSize: 20),
          ),
        ),
    ],
  );
}

class _CoachMark extends StatelessWidget {
  const _CoachMark({this.size = 34});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: EdgeColors.accent.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(size * .32),
      border: Border.all(color: EdgeColors.accent.withValues(alpha: .25)),
    ),
    child: Icon(Icons.auto_awesome, size: size * .55, color: EdgeColors.accent),
  );
}
