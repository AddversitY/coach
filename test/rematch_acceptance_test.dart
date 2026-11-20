import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/coach_briefing.dart';
import 'package:odds_edge/domain/matchup.dart';
import 'package:odds_edge/domain/player_stats.dart';
import 'package:odds_edge/domain/recent_evidence.dart';
import 'package:odds_edge/domain/rematch.dart';

void main() {
  test('the Texans and Colts rematch is read from the files', () {
    final evidence = RecentEvidence.fromJson(
      jsonDecode(File('assets/nfl-recent-evidence.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    final matchup = MatchupContext.fromJson(
      jsonDecode(File('assets/nfl-matchup.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    final injuries = [
      for (final row in matchup.injuries)
        InjuryNote(
          week: row.week,
          team: row.team,
          player: row.player,
          position: row.position,
          status: row.status,
          injury: row.injury,
        ),
    ];
    final report = rematchReport(
      evidence: evidence,
      teamA: 'HOU',
      teamB: 'IND',
      snaps: matchup.snaps,
      earlierInjuries: injuries,
    );
    expect(report, isNotNull);
    final earlier = report!.earlier;
    final later = report.later;
    expect(earlier.week, lessThan(later.week));
    expect({earlier.home, earlier.away}, {'HOU', 'IND'});
    expect({later.home, later.away}, {'HOU', 'IND'});

    final text = report.allText;
    expect(text, contains('${earlier.away} ${earlier.awayScore}'));
    expect(text, contains('${later.home} ${later.homeScore}'));
    expect(text, contains('${earlier.spreadLine}'));
    expect(text, contains('${later.spreadLine}'));
    expect(text, contains('${earlier.totalLine}'));
    expect(text, contains('${later.totalLine}'));

    final earlyWeeks = {
      for (final row in evidence.teamWeeks)
        if (row.gameId == earlier.id) row.team: row,
    };
    final lateWeeks = {
      for (final row in evidence.teamWeeks)
        if (row.gameId == later.id) row.team: row,
    };
    final earlyGap =
        (earlyWeeks[earlier.home]!.giveaways! - earlyWeeks[earlier.away]!.giveaways!).abs();
    final lateGap =
        (lateWeeks[later.home]!.giveaways! - lateWeeks[later.away]!.giveaways!).abs();
    expect(earlyGap, greaterThan(lateGap));
    expect(lateWeeks['HOU']!.giveaways, lateWeeks['IND']!.giveaways);
    expect(text.toLowerCase(), contains('turnover result'));
    expect(text, contains('Passing EPA'));
    expect(text, isNot(contains('8/14')));
    expect(text, isNot(contains('1/11')));
    expect(text.toLowerCase(), contains('third-down rate is unavailable'));
    expect(text.toLowerCase(), contains('general manager'));
    expect(text.toLowerCase(), isNot(contains('ballard')));
    expect(text.toLowerCase(), isNot(contains('fired')));
    expect(text.toLowerCase(), isNot(contains('traded away')));

    final returned = _returned(injuries, evidence.players, matchup.snaps, earlier, later);
    expect(returned, isNotEmpty);
    for (final name in returned) {
      expect(text, contains(name));
    }
    final moved = _moved(matchup.snaps, earlier.week, later.week);
    expect(moved, isNotEmpty);
    for (final name in moved) {
      expect(text, contains(name));
      expect(text, contains('snap-count team change'));
    }

    final brief = interpretQuestion(
      question: 'why did the Texans beat the Colts so badly after losing earlier?',
      evidence: evidence,
      players: null,
      ratings: null,
      snaps: matchup.snaps,
      injuries: injuries,
    );
    expect(brief?.handlesQuestion, isTrue);
    expect(brief!.text.toLowerCase(), contains('week ${later.week}'));
    expect(brief.text.toLowerCase(), isNot(contains('ballard')));
  });
}

Set<String> _returned(
  List<InjuryNote> injuries,
  List<PlayerGame> players,
  List<SnapShare> snaps,
  RecentGame earlier,
  RecentGame later,
) {
  final names = <String>{};
  for (final note in injuries) {
    if (note.team != 'HOU' && note.team != 'IND') continue;
    if (note.week < earlier.week || note.week >= later.week) continue;
    if (note.status != 'Out' && note.status != 'Questionable' && note.status != 'Doubtful') {
      continue;
    }
    final played = players.any(
      (game) =>
          game.name == note.player &&
          game.week == later.week &&
          (game.stats['receiving_yards'] ?? 0) +
                  (game.stats['rushing_yards'] ?? 0) +
                  (game.stats['passing_yards'] ?? 0) >
              0,
    );
    if (!played) continue;
    if (note.week == earlier.week && (note.status == 'Out' || note.status == 'Doubtful')) {
      names.add(note.player);
      continue;
    }
    final snappedBefore = snaps.any(
      (snap) =>
          snap.player == note.player &&
          snap.team == note.team &&
          snap.week < later.week &&
          (snap.share ?? 0) > 0,
    );
    final snappedThatWeek = snaps.any(
      (snap) =>
          snap.player == note.player &&
          snap.team == note.team &&
          snap.week == note.week &&
          (snap.share ?? 0) > 0,
    );
    if (snappedBefore && !snappedThatWeek) names.add(note.player);
  }
  return names;
}

Set<String> _moved(List<SnapShare> snaps, int earlierWeek, int laterWeek) {
  final names = <String>{};
  final byPlayer = <String, List<SnapShare>>{};
  for (final snap in snaps) {
    if (snap.week < earlierWeek || snap.week >= laterWeek) continue;
    (byPlayer[snap.player] ??= []).add(snap);
  }
  for (final entry in byPlayer.entries) {
    final origin = entry.value.where(
      (snap) => snap.week == earlierWeek && (snap.team == 'HOU' || snap.team == 'IND'),
    );
    if (origin.isEmpty) continue;
    final club = origin.first.team;
    if (entry.value.any((snap) => snap.week > earlierWeek && snap.team != club)) {
      names.add(entry.key);
    }
  }
  return names;
}
