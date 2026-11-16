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
import '../theme/coach_theme.dart';

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
              'Schedule: nflverse · CC BY 4.0\nChecked: ${snapshot == null ? 'Unavailable' : formatEastern(snapshot!.scheduleAt, year: true)}\nPlayer box scores through: ${data?.metadata['cutoff'] ?? 'Unknown'}\nPrices: The Odds API · limited pregame snapshots\nHistorical appearances are not confirmed rosters. No verified current injury or weather feed is supplied here.',
              style: CoachType.label,
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
      final prompts = ['Brief me', 'Find a player', 'Compare prices'];
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
            turn.generated?.answer ?? a.text,
            style: CoachType.body,
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
