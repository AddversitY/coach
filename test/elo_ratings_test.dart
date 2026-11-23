import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/coach_briefing.dart';
import 'package:odds_edge/domain/elo_ratings.dart';

EloRatings sample() => EloRatings.fromJson({
  'schema': 1,
  'season': 2026,
  'asOfWeek': 12,
  'note': 'Extra number to weigh. Not part of the chance.',
  'teams': [
    {
      't': 'MIN',
      'o': 80,
      'off': 70,
      'def': 90,
      'net': 4.0,
      'qb': 'J.J. McCarthy',
    },
    {
      't': 'CHI',
      'o': 60,
      'off': 65,
      'def': 55,
      'net': -1.5,
      'qb': 'Caleb Williams',
    },
    {'t': 'LA', 'o': 90, 'off': 95, 'def': 80, 'net': 8.0},
  ],
  'players': [
    {
      'n': 'Justin Jefferson',
      'id': 'jj',
      't': 'MIN',
      'p': 'WR',
      'o': 95,
      'd': 0,
      's': 600,
      'ypt': 1.2,
      'cr': 0.03,
      'ts': 0.08,
    },
    {
      'n': 'J.J. McCarthy',
      'id': 'qb1',
      't': 'MIN',
      'p': 'QB',
      'o': 70,
      'd': 0,
      's': 600,
      'ypa': 0.4,
    },
    {
      'n': 'Caleb Williams',
      'id': 'qb2',
      't': 'CHI',
      'p': 'QB',
      'o': 75,
      'd': 0,
      's': 600,
    },
    {
      'n': 'Jaylon Johnson',
      'id': 'cb1',
      't': 'CHI',
      'p': 'CB',
      'o': 90,
      'd': 1,
      's': 500,
    },
    {
      'n': 'Kevin Byard',
      'id': 's1',
      't': 'CHI',
      'p': 'FS',
      'o': 70,
      'd': 1,
      's': 550,
    },
    {
      'n': 'Tyrique Stevenson',
      'id': 'cb2',
      't': 'CHI',
      'p': 'CB',
      'o': 50,
      'd': 1,
      's': 450,
    },
  ],
  'defVs': {
    'MIN': {'WR': -0.5, 'TE': 0.1, 'RB': 0.0, 'ypc': -0.2},
    'CHI': {'WR': 0.6, 'TE': -0.2, 'RB': 0.1, 'ypc': 0.3},
    'LA': {'WR': 0.1, 'TE': 0.0, 'RB': -0.1, 'ypc': 0.0},
  },
});

void main() {
  test('reads teams, players and defense by position', () {
    final elo = sample();
    expect(elo.team('MIN')!.overall, 80);
    expect(elo.team('LAR')!.code, 'LA');
    expect(elo.player(name: 'justin jefferson')!.overall, 95);
    expect(elo.defenseRank('MIN', 'WR'), 1);
    expect(elo.defenseRank('CHI', 'WR'), 3);
    expect(elo.secondary('CHI'), 70);
  });

  test('player against a defense names the secondary and the QB', () {
    final lines = sample().playerLines(
      name: 'Justin Jefferson',
      opponent: 'CHI',
    );
    expect(lines.first, contains('95 out of 99'));
    expect(
      lines.join(' '),
      contains('CHI pass defense against WRs ranks 3rd of 3'),
    );
    expect(lines.join(' '), contains('secondary rates 70'));
    expect(lines.join(' '), contains('J.J. McCarthy, rates 70'));
  });

  test('game lines compare both teams', () {
    final lines = sample().gameLines('MIN', 'CHI');
    expect(lines.first, contains('CHI 60, MIN 80'));
    expect(lines.first, contains('MIN rates 5.5 points'));
  });

  test('a ratings question is answered from the ratings', () {
    final brief = interpretQuestion(
      question: "What's Justin Jefferson's elo against the Bears?",
      evidence: null,
      players: null,
      ratings: null,
      elo: sample(),
    );
    expect(brief, isNotNull);
    expect(brief!.title, 'Coach ratings');
    expect(brief.handlesQuestion, isTrue);
    expect(brief.text, contains('Justin Jefferson'));
    expect(brief.eloLines.join(' '), contains('CHI pass defense'));
    expect(brief.eloNote, contains('Not part of the chance'));
  });

  test('top rated corners', () {
    final brief = eloQuestionBrief(
      question: 'top rated corners',
      elo: sample(),
    );
    expect(brief!.text, startsWith('Top rated CBs: Jaylon Johnson (CHI) 90'));
  });

  test(
    'a two-way player is ranked only on his offensive side as a receiver',
    () {
      final elo = EloRatings.fromJson({
        'teams': [
          {'t': 'JAX', 'o': 90, 'off': 90, 'def': 90, 'net': 5.0},
        ],
        'players': [
          {
            'n': 'Two Way',
            'id': 'tw',
            't': 'JAX',
            'p': 'WR',
            'o': 99,
            'd': 1,
            's': 400,
          },
          {
            'n': 'Real Receiver',
            'id': 'rr',
            't': 'JAX',
            'p': 'WR',
            'o': 80,
            'd': 0,
            's': 400,
          },
        ],
      });
      final brief = eloQuestionBrief(question: 'top rated receivers', elo: elo);
      expect(brief!.text, 'Top rated WRs: Real Receiver (JAX) 80.');
    },
  );

  test('other questions are left alone', () {
    for (final q in [
      'How accurate is Coach?',
      'Is Minnesota good against a weak pass defense?',
      'Vikings spread tonight',
    ]) {
      expect(
        eloQuestionBrief(question: q, elo: sample()),
        isNull,
        reason: q,
      );
    }
  });

  test('game context adds ratings without changing anything else', () {
    final brief = contextBrief(
      players: null,
      ratings: null,
      evidence: null,
      home: 'Minnesota Vikings',
      away: 'Chicago Bears',
      season: 2026,
      week: 12,
      playerName: 'Justin Jefferson',
      elo: sample(),
    );
    final all = '${brief!.text} ${brief.eloLines.join(' ')}';
    expect(all, contains('Coach ratings'));
    expect(all, contains('Justin Jefferson'));
  });

  test('bundled asset parses', () {
    final raw = File('assets/elo-ratings.json').readAsStringSync();
    final elo = EloRatings.fromJson(Map<String, dynamic>.from(jsonDecode(raw)));
    expect(elo.teamCount, 32);
    expect(elo.note, contains('not part of'));
  });
}
