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
      'a': {'Speed': 88, 'Separation': 91},
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
    expect(
      lines.join(' '),
      contains('Traits (40-99 vs his position): Speed 88, Separation 91.'),
    );
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

  test('line matchups and new position groups', () {
    final elo = EloRatings.fromJson({
      'teams': [
        {
          't': 'BUF',
          'o': 97,
          'off': 97,
          'def': 77,
          'net': 15.0,
          'lines': {
            'passBlock': 84,
            'runBlock': 99,
            'passRush': 86,
            'runDefense': 57,
          },
        },
        {
          't': 'MIA',
          'o': 44,
          'off': 49,
          'def': 51,
          'net': -11.5,
          'lines': {
            'passBlock': 64,
            'runBlock': 49,
            'passRush': 64,
            'runDefense': 44,
          },
        },
      ],
      'players': [
        {
          'n': 'Big Tackle',
          'id': 't1',
          't': 'BUF',
          'p': 'T',
          'o': 99,
          'd': 0,
          's': 600,
          'a': {'Pass block': 75},
        },
        {
          'n': 'Edge Guy',
          'id': 'd1',
          't': 'MIA',
          'p': 'DE',
          'o': 90,
          'd': 1,
          's': 500,
        },
        {
          'n': 'Leg Man',
          'id': 'k1',
          't': 'BUF',
          'p': 'K',
          'o': 95,
          'd': 0,
          's': 60,
        },
      ],
    });
    final lines = elo.gameLines('BUF', 'MIA').join(' ');
    expect(
      lines,
      contains(
        'Trenches: BUF pass block 84 vs MIA pass rush 64; BUF run block 99 vs MIA run defense 44.',
      ),
    );
    expect(
      eloQuestionBrief(question: 'top rated offensive linemen', elo: elo)!.text,
      'Top rated offensive linemen: Big Tackle (BUF) 99.',
    );
    expect(
      eloQuestionBrief(question: 'best rated pass rushers', elo: elo)!.text,
      contains('Edge Guy'),
    );
    expect(
      eloQuestionBrief(question: 'top rated kickers', elo: elo)!.text,
      contains('Leg Man (BUF) 95'),
    );
  });

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

  test('game lines add coaching, chemistry, injuries, rest and referee', () {
    final r = EloRatings.fromJson({
      'season': 2026,
      'teams': [
        {
          't': 'KC',
          'o': 90,
          'off': 90,
          'def': 80,
          'net': 5.0,
          'ang': {
            'coach': 'Andy Reid',
            'proe': 5.7,
            'go4': 0.67,
            'blitz': 0.27,
            'pa': 0.3,
            'olTogether': 4,
            'chem': {'qb': 'Patrick Mahomes', 'rec': 'Travis Kelce', 'v': 0.05},
            'out': [
              {'n': 'Trey Smith', 'p': 'G', 'pts': 0.4},
            ],
            'outPts': 0.4,
          },
        },
        {
          't': 'ARI',
          'o': 50,
          'off': 50,
          'def': 50,
          'net': -2.0,
          'ang': {'coach': 'Jonathan Gannon', 'blitz': 0.35},
        },
      ],
      'players': [
        {
          'n': 'Patrick Mahomes',
          'id': 'pm',
          't': 'KC',
          'p': 'QB',
          'o': 95,
          'd': 0,
          's': 600,
          'sit': {'3rd down': 97, 'Vs blitz': 88},
        },
      ],
      'upcoming': {
        'week': 12,
        'games': [
          {
            'h': 'KC',
            'a': 'ARI',
            'restH': 7,
            'restA': 6,
            'milesA': 1059,
            'tzA': 2,
            'early': ['ARI'],
            'ref': 'Shawn Smith',
            'refPens': 1.2,
            'refTotal': -0.8,
            'refHome': 0.3,
          },
        ],
      },
    });
    final lines = r.gameLines('KC', 'ARI').join('\n');
    expect(
      lines,
      contains(
        'Coaching: ARI Jonathan Gannon; KC Andy Reid (passes +5.7% vs expected, goes for it on 67% of short 4th downs).',
      ),
    );
    expect(
      lines,
      contains('ARI blitzes on 35% of dropbacks; KC uses play-action on 30%'),
    );
    expect(lines, contains('Patrick Mahomes to Travis Kelce'));
    expect(lines, contains('KC lists Trey Smith (G) out or doubtful'));
    expect(
      lines,
      contains(
        'ARI 6 days of rest, KC 7; ARI travels 1059 miles and 2 time zones.',
      ),
    );
    expect(lines, contains('ARI kicks off at 10 AM or earlier'));
    expect(lines, contains('Referee: Shawn Smith.'));
    expect(r.upcomingWeek, 12);
    final p = r.playerLines(name: 'Patrick Mahomes').join('\n');
    expect(
      p,
      contains(
        'Situations (40-99 vs other passers): 3rd down 97, Vs blitz 88.',
      ),
    );
    // A game with no angle data adds no angle lines.
    expect(
      EloRatings.fromJson({
        'teams': [
          {'t': 'A', 'o': 1, 'off': 1, 'def': 1, 'net': 0},
          {'t': 'B', 'o': 1, 'off': 1, 'def': 1, 'net': 0},
        ],
      }).gameLines('A', 'B').any((l) => l.startsWith('Coaching')),
      isFalse,
    );
  });

  test('game lines name a backup stepping in, with the logged price', () {
    final elo = EloRatings.fromJson({
      'teams': [
        {'t': 'NE', 'o': 70, 'off': 70, 'def': 70, 'net': 0.0},
        {'t': 'LAC', 'o': 75, 'off': 75, 'def': 75, 'net': 1.0},
      ],
      'backupWatch': [
        {
          'team': 'NE',
          'group': 'WR',
          'out': [
            {'player': 'A.J. Brown', 'status': 'Doubtful'},
          ],
          'backup': 'Mack Hollins',
          'backupRating': 67,
          'projection': {
            'player_reception_yds': 55.2,
            'player_receptions': 4.4,
          },
          'prices': [
            {
              'book': 'fanduel',
              'market': 'player_reception_yds',
              'line': 40.5,
              'over': 1.91,
              'under': 1.91,
              'overChance': 0.68,
              'overEdge': 0.2988,
              'underEdge': -0.3888,
              'side': 'over',
            },
          ],
        },
        {'team': 'KC', 'backup': 'Someone Else', 'out': []},
      ],
    });
    final lines = elo.gameLines('LAC', 'NE');
    final line = lines.singleWhere((l) => l.startsWith('Next man up'));
    expect(line, contains('Mack Hollins (Coach rating 67) for A.J. Brown (Doubtful)'));
    expect(line, contains('55 receiving yards, 4.4 receptions'));
    expect(line, contains('FanDuel over 40.5 receiving yards at 1.91'));
    expect(line, contains('68%'));
    expect(line, contains('not a pick'));
    expect(lines.any((l) => l.contains('Someone Else')), isFalse);
  });
}
