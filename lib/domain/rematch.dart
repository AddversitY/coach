import 'matchup.dart';
import 'player_stats.dart';
import 'recent_evidence.dart';

/// What can be said about two meetings from the files in hand.
class ChangeReport {
  const ChangeReport({
    required this.summary,
    required this.details,
    required this.unavailable,
    required this.sources,
    required this.earlier,
    required this.later,
  });

  final String summary;
  final List<String> details;
  final List<String> unavailable;
  final String sources;
  final RecentGame earlier, later;

  String get allText => [summary, ...details, ...unavailable, sources].join('\n');
}

class _Record {
  _Record(this.wins, this.losses, this.ties);
  final int wins, losses, ties;
  String get label => ties == 0 ? '$wins-$losses' : '$wins-$losses-$ties';
}

/// The later meeting of [a] and [b], with what changed since the earlier one.
///
/// Names, scores, yards, turnovers, EPA, injuries and snap clubs come from
/// the supplied rows. A missing feed stays in [ChangeReport.unavailable].
ChangeReport? rematchReport({
  required RecentEvidence evidence,
  required String teamA,
  required String teamB,
  List<SnapShare> snaps = const [],
  List<InjuryNote> earlierInjuries = const [],
}) {
  final a = teamA.toUpperCase();
  final b = teamB.toUpperCase();
  final meetings = [
    for (final game in evidence.games)
      if (game.involves(a, b)) game,
  ]..sort((left, right) => left.date.compareTo(right.date));
  if (meetings.length < 2) return null;
  final earlier = meetings[meetings.length - 2];
  final later = meetings.last;
  final details = <String>[
    _scoreLine(earlier),
    _scoreLine(later),
    _lineSentence(earlier),
    _lineSentence(later),
  ];
  final unavailable = <String>[
    'Front-office and general-manager changes are unavailable. These files do not name a general manager or a firing.',
    'A trade tape is unavailable. A player who snaps for a different club later is a snap-count team change, not a recorded transaction.',
    'Third-down rate is unavailable. The team weekly file has no third-down attempts.',
    'Pass rate over expected is unavailable. The pass rate below is attempts divided by attempts plus carries.',
    'Down-to-down success rate is unavailable. Passing and rushing EPA are the efficiency numbers the team file does publish.',
  ];
  final earlyWeeks = _weeks(evidence, earlier.id);
  final lateWeeks = _weeks(evidence, later.id);
  final turnover = _turnoverRead(earlier, later, earlyWeeks, lateWeeks);
  if (turnover != null) details.add(turnover);
  details.add(_efficiencyRead(earlyWeeks, lateWeeks));
  final between = _recordBetween(evidence.games, a, earlier, later);
  final other = _recordBetween(evidence.games, b, earlier, later);
  details.add(
    'Between the meetings, $a was ${between.label} and $b was ${other.label}, from the schedule scores in the weeks strictly between them.',
  );
  details.add(_coachLine(earlier, later));
  details.add(_restLine(later));
  final snapWeek = snaps.isEmpty
      ? null
      : snaps.map((row) => row.week).reduce((x, y) => x > y ? x : y);
  if (snapWeek == null || snapWeek < later.week) {
    unavailable.add(
      'Snap counts for week ${later.week} are unavailable${snapWeek == null ? '' : '. The snap file stops at week $snapWeek'}.',
    );
  }
  final injuries = [...earlierInjuries, ...evidence.injuries];
  details.addAll(_absences(injuries, snaps, later, {a, b}));
  details.addAll(
    _returns(injuries, evidence.players, snaps, earlier, later, {a, b}),
  );
  details.addAll(_snapMoves(snaps, earlier, later, {a, b}));
  details.addAll(_passRate(earlyWeeks, lateWeeks));
  final summary = _summary(earlier, later, earlyWeeks, lateWeeks);
  return ChangeReport(
    summary: summary,
    details: details,
    unavailable: unavailable,
    sources: evidence.sources.isEmpty
        ? evidence.notice
        : '${evidence.sources.join(' ')} ${evidence.notice}',
    earlier: earlier,
    later: later,
  );
}

String _summary(
  RecentGame earlier,
  RecentGame later,
  Map<String, TeamWeek> early,
  Map<String, TeamWeek> late,
) {
  final first = _shortScore(earlier);
  final second = _shortScore(later);
  final earlyGap = _giveawayGap(earlier, early);
  final lateGap = _giveawayGap(later, late);
  final turnover = earlyGap == null || lateGap == null
      ? 'Turnover counts for one of the games are unavailable.'
      : earlyGap.abs() > lateGap.abs()
      ? 'The earlier margin came with the larger giveaway gap.'
      : 'The later giveaway gap was not larger than the earlier one.';
  return 'Week ${later.week} was $second after week ${earlier.week} was $first. $turnover Passing EPA, not a transaction feed, is the efficiency comparison.';
}

String _shortScore(RecentGame game) =>
    '${game.away} ${game.awayScore}, ${game.home} ${game.homeScore}';

String _scoreLine(RecentGame game) =>
    'Week ${game.week} ${game.date.toIso8601String().substring(0, 10)} at ${game.home}: ${_shortScore(game)}.';

String _lineSentence(RecentGame game) {
  final line = game.spreadLine;
  final total = game.totalLine;
  final totalText = total == null ? 'Total unavailable.' : 'Total $total.';
  if (line == null) return 'Week ${game.week} closing spread unavailable. $totalText';
  if (line == 0) {
    return 'Week ${game.week} closing home margin was a pick. $totalText';
  }
  final favorite = line > 0 ? game.home : game.away;
  return 'Week ${game.week} closing home margin ${line > 0 ? '+' : ''}$line, so $favorite was favored by ${line.abs()}. $totalText';
}

Map<String, TeamWeek> _weeks(RecentEvidence evidence, String gameId) => {
  for (final row in evidence.teamWeeks)
    if (row.gameId == gameId) row.team: row,
};

int? _giveawayGap(RecentGame game, Map<String, TeamWeek> weeks) {
  final home = weeks[game.home]?.giveaways;
  final away = weeks[game.away]?.giveaways;
  if (home == null || away == null) return null;
  return home - away;
}

String? _turnoverRead(
  RecentGame earlier,
  RecentGame later,
  Map<String, TeamWeek> early,
  Map<String, TeamWeek> late,
) {
  String? one(RecentGame game, Map<String, TeamWeek> weeks) {
    final home = weeks[game.home];
    final away = weeks[game.away];
    if (home?.giveaways == null || away?.giveaways == null) return null;
    return '${game.home} gave it away ${home!.giveaways} times and ${game.away} ${away!.giveaways} times (interceptions plus fumbles lost)';
  }

  final first = one(earlier, early);
  final second = one(later, late);
  if (first == null || second == null) {
    return 'Turnover counts are unavailable for at least one meeting.';
  }
  final earlyGap = _giveawayGap(earlier, early)!.abs();
  final lateGap = _giveawayGap(later, late)!.abs();
  final label = earlyGap >= 2 && earlyGap > lateGap
      ? 'Week ${earlier.week} is the turnover result. It is not treated as a new level of play.'
      : lateGap <= 1
      ? 'Week ${later.week} is not a turnover result. The giveaway gap is ${lateGap == 0 ? 'even' : 'one'}.'
      : 'Both games have a giveaway gap. Neither is labeled as only noise or only skill.';
  final yards = _yards(later, late);
  return '$label Week ${earlier.week}: $first. Week ${later.week}: $second.${yards == null ? '' : ' $yards'}';
}

String? _yards(RecentGame game, Map<String, TeamWeek> weeks) {
  final home = weeks[game.home];
  final away = weeks[game.away];
  if (home?.netYards == null || away?.netYards == null) return null;
  final homeRush = home!.rushingYards;
  final awayRush = away!.rushingYards;
  final rush = homeRush == null || awayRush == null
      ? ''
      : ' Rushing yards ${home.team} ${homeRush.round()} , ${away.team} ${awayRush.round()}.';
  return 'Net yards (passing, plus the file\'s sack yards, plus rushing) ${home.team} ${home.netYards!.round()} , ${away.team} ${away.netYards!.round()}.$rush';
}

String _efficiencyRead(Map<String, TeamWeek> early, Map<String, TeamWeek> late) {
  String side(String label, Map<String, TeamWeek> weeks) {
    final parts = [
      for (final row in weeks.values)
        if (row.passingEpa != null)
          '${row.team} passing EPA ${row.passingEpa!.toStringAsFixed(1)}'
              '${row.rushingEpa == null ? '' : ', rushing EPA ${row.rushingEpa!.toStringAsFixed(1)}'}',
    ];
    if (parts.isEmpty) return '$label EPA unavailable.';
    return '$label: ${parts.join('; ')}.';
  }

  return '${side('Earlier game', early)} ${side('Later game', late)} EPA includes the value of turnovers on those plays. It is not a turnover-free rating. Fumble-recovery luck beyond fumbles lost is not separated.';
}

_Record _recordBetween(
  List<RecentGame> games,
  String team,
  RecentGame earlier,
  RecentGame later,
) {
  var wins = 0, losses = 0, ties = 0;
  for (final game in games) {
    if (game.date.isBefore(earlier.date) || !game.date.isBefore(later.date)) {
      continue;
    }
    if (game.home != team && game.away != team) continue;
    final own = game.home == team ? game.homeScore : game.awayScore;
    final opp = game.home == team ? game.awayScore : game.homeScore;
    if (own > opp) {
      wins++;
    } else if (own < opp) {
      losses++;
    } else {
      ties++;
    }
  }
  return _Record(wins, losses, ties);
}

String _coachLine(RecentGame earlier, RecentGame later) {
  final homeSame = earlier.homeCoach != null &&
      later.homeCoach != null &&
      earlier.awayCoach != null &&
      later.awayCoach != null;
  if (!homeSame) {
    return 'Head coaches are unavailable for at least one meeting.';
  }
  final same = {earlier.homeCoach, earlier.awayCoach}.contains(later.homeCoach) &&
      {earlier.homeCoach, earlier.awayCoach}.contains(later.awayCoach);
  if (!same) {
    return 'Head coach changed in the schedule file. Week ${earlier.week}: ${earlier.awayCoach} at ${earlier.homeCoach}. Week ${later.week}: ${later.awayCoach} at ${later.homeCoach}.';
  }
  return 'Head coaches are unchanged in the schedule: ${later.awayCoach} and ${later.homeCoach}.';
}

String _restLine(RecentGame game) {
  if (game.homeRest == null || game.awayRest == null) {
    return 'Rest days for week ${game.week} are unavailable.';
  }
  return 'Rest before week ${game.week}: ${game.home} ${game.homeRest} days, ${game.away} ${game.awayRest} days.';
}

List<String> _absences(
  List<InjuryNote> injuries,
  List<SnapShare> snaps,
  RecentGame later,
  Set<String> clubs,
) {
  final lines = <String>[];
  final seen = <String>{};
  var practiceLines = 0;
  // Practice-only lines stay short. Out and Questionable listings are kept.
  for (final note in injuries) {
    if (note.week != later.week || !clubs.contains(note.team)) continue;
    if (!seen.add('${note.team}|${note.player}|${note.status}|${note.practice}')) {
      continue;
    }
    if (note.listedOut) {
      lines.add(
        '${note.player} (${note.team}, ${note.position}) was ${note.status} for week ${later.week}${note.injury.isEmpty ? '' : ', ${note.injury}'}. Source: nflverse injury report. This is not a snap count.',
      );
    } else if (note.status == 'Questionable') {
      lines.add(
        '${note.player} (${note.team}) was Questionable for week ${later.week}${note.injury.isEmpty ? '' : ', ${note.injury}'}. Questionable is not an inactive designation.',
      );
    } else if (note.status.isEmpty &&
        note.practice.toLowerCase().contains('did not') &&
        practiceLines < 8 &&
        _wasRegular(snaps, note, later.week)) {
      practiceLines++;
      lines.add(
        '${note.player} (${note.team}) had no game status listed for week ${later.week}. Practice status: ${note.practice}. Earlier snaps were at least half the snaps. That is not an inactive designation.',
      );
    }
  }
  return lines;
}

bool _wasRegular(List<SnapShare> snaps, InjuryNote note, int beforeWeek) {
  SnapShare? latest;
  for (final snap in snaps) {
    if (snap.player != note.player || snap.team != note.team || snap.week >= beforeWeek) {
      continue;
    }
    if (latest == null || snap.week > latest.week) latest = snap;
  }
  final share = latest?.share;
  return share != null && share >= 0.5;
}

List<String> _returns(
  List<InjuryNote> injuries,
  List<PlayerGame> players,
  List<SnapShare> snaps,
  RecentGame earlier,
  RecentGame later,
  Set<String> clubs,
) {
  final lines = <String>[];
  final seen = <String>{};
  final notes = [
    for (final note in injuries)
      if (clubs.contains(note.team) &&
          note.week >= earlier.week &&
          note.week < later.week &&
          (note.listedOut || note.status == 'Questionable'))
        note,
  ]..sort((a, b) {
    final out = (b.listedOut ? 1 : 0) - (a.listedOut ? 1 : 0);
    return out != 0 ? out : a.week.compareTo(b.week);
  });
  for (final note in notes) {
    if (!seen.add('${note.team}|${note.player}')) continue;
    final laterRows = [
      for (final game in players)
        if (game.week == later.week &&
            game.season == later.season &&
            game.name == note.player &&
            clubs.contains(game.team))
          game,
    ];
    final stat = laterRows.isEmpty ? null : _production(laterRows.first);
    final satEarlier = note.week == earlier.week && note.listedOut;
    final missedSnaps = _missedAfter(snaps, note, later.week);
    final listed = note.listedOut || note.status == 'Questionable';
    if (!satEarlier && !(listed && missedSnaps)) continue;
    if (stat == null) {
      if (satEarlier) {
        lines.add(
          '${note.player} was ${note.status} in week ${note.week}${note.injury.isEmpty ? '' : ' (${note.injury})'}. No week ${later.week} counting stat is in the file, so a return is not claimed.',
        );
      }
      continue;
    }
    lines.add(
      '${note.player} was ${note.status} in week ${note.week}${note.injury.isEmpty ? '' : ' (${note.injury})'} and has a week ${later.week} counting stat ($stat).',
    );
  }
  return lines;
}

bool _missedAfter(List<SnapShare> snaps, InjuryNote note, int laterWeek) {
  var saw = false;
  var playedTheWeek = false;
  for (final snap in snaps) {
    if (snap.player != note.player || snap.team != note.team) continue;
    if (snap.week >= laterWeek) continue;
    if ((snap.share ?? 0) <= 0) continue;
    saw = true;
    if (snap.week == note.week) playedTheWeek = true;
  }
  return saw && !playedTheWeek;
}

String? _production(PlayerGame game) {
  final parts = <String>[];
  void add(String key, String label) {
    final value = game.stats[key];
    if (value == null || value == 0) return;
    parts.add('$label ${value is int ? value : value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)}');
  }

  add('passing_yards', 'passing yards');
  add('rushing_yards', 'rushing yards');
  add('receiving_yards', 'receiving yards');
  add('receptions', 'receptions');
  add('targets', 'targets');
  if (parts.isEmpty) return null;
  return parts.join(', ');
}

List<String> _snapMoves(
  List<SnapShare> snaps,
  RecentGame earlier,
  RecentGame later,
  Set<String> clubs,
) {
  if (snaps.isEmpty) return const ['Snap counts were not loaded.'];
  final byPlayer = <String, List<SnapShare>>{};
  for (final snap in snaps) {
    if (snap.week < earlier.week || snap.week >= later.week) continue;
    (byPlayer[snap.player] ??= []).add(snap);
  }
  final lines = <String>[];
  for (final entry in byPlayer.entries) {
    final rows = entry.value..sort((a, b) => a.week.compareTo(b.week));
    final first = rows.where((row) => row.week == earlier.week && clubs.contains(row.team));
    if (first.isEmpty) continue;
    final origin = first.first;
    SnapShare? moved;
    for (final row in rows.reversed) {
      if (row.week <= earlier.week) break;
      if (row.team != origin.team) {
        moved = row;
        break;
      }
    }
    if (moved == null) continue;
    final share = moved.share;
    lines.add(
      '${entry.key} snapped for ${origin.team} in week ${earlier.week} and for ${moved.team} in week ${moved.week}'
      '${share == null ? '' : ' (${(share * 100).round()}% of snaps)'}. This is a snap-count team change. The file does not say whether it was a trade.',
    );
  }
  lines.sort();
  return lines;
}

List<String> _passRate(Map<String, TeamWeek> early, Map<String, TeamWeek> late) {
  final lines = <String>[];
  final teams = {...early.keys, ...late.keys};
  for (final team in teams) {
    final before = early[team];
    final after = late[team];
    final first = _rate(before);
    final second = _rate(after);
    if (first == null && second == null) continue;
    lines.add(
      '$team pass rate (attempts / attempts + carries): week ${before?.week ?? '—'} ${first == null ? 'unavailable' : '${(first * 100).round()}%'}, week ${after?.week ?? '—'} ${second == null ? 'unavailable' : '${(second * 100).round()}%'}. Not pass rate over expected.',
    );
  }
  return lines;
}

double? _rate(TeamWeek? week) {
  if (week?.attempts == null || week?.carries == null) return null;
  final plays = week!.attempts! + week.carries!;
  if (plays <= 0) return null;
  return week.attempts! / plays;
}
