/// Coach ratings: Elo-style numbers for every team and player.
///
/// Built by model/elo_report.py from free nflverse data and bundled as
/// assets/elo-ratings.json. They are an extra number to weigh. They are not
/// part of Coach's chance, and in testing they did not beat the closing line
/// (docs/ELO_RATINGS.md). A missing team or player shows nothing.
library;

class EloTeam {
  const EloTeam({
    required this.code,
    required this.overall,
    required this.offense,
    required this.defense,
    required this.net,
    this.quarterback,
    this.lines = const {},
    this.angles = const {},
  });

  final String code;
  final int overall, offense, defense;

  /// Points per game better than an average team, on a neutral field.
  final double net;
  final String? quarterback;

  /// Line play, 40-99 across the league: passBlock, runBlock (offensive
  /// line plus quarterback for sacks), passRush, runDefense (the front).
  final Map<String, int> lines;

  /// Coaching, scheme, chemistry, line continuity and injuries (see
  /// model/elo_angles.py). Keys are absent when free data has no value.
  final Map<String, Object?> angles;
}

class EloPlayer {
  const EloPlayer({
    required this.name,
    required this.id,
    required this.team,
    required this.position,
    required this.overall,
    required this.defense,
    required this.snaps,
    this.yardsPerTarget,
    this.catchRate,
    this.targetShare,
    this.yardsPerCarry,
    this.yardsPerAttempt,
    this.attributes = const {},
    this.situations = const {},
  });

  final String name, id, team, position;
  final int overall, snaps;
  final bool defense;

  /// Each is the player's rating above (+) or below (-) the league average.
  final double? yardsPerTarget,
      catchRate,
      targetShare,
      yardsPerCarry,
      yardsPerAttempt;

  /// Madden-style sub-ratings (40-99) from measured data only: combine
  /// testing, Next Gen Stats and play-by-play. A trait with no measurement
  /// is absent.
  final Map<String, int> attributes;

  /// 40-99 vs others in his role (passer, rusher or receiver) by situation:
  /// 3rd down, red zone, two-minute, script, blitz, play-action, shotgun,
  /// deep and short throws. Only situations with enough plays are present.
  final Map<String, int> situations;
}

const _secondaryPositions = {'CB', 'S', 'FS', 'SS', 'DB', 'SAF'};

String _norm(String name) {
  var text = name.toLowerCase().replaceAll(RegExp(r"[.'\-]"), ' ');
  text = text.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
  text = text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).join(' ');
  for (final suffix in const [' jr', ' sr', ' iii', ' ii', ' iv']) {
    if (text.endsWith(suffix)) {
      text = text.substring(0, text.length - suffix.length);
    }
  }
  return text.trim();
}

String _signed(double value, {int digits = 1}) {
  final text = value.abs().toStringAsFixed(digits);
  return value >= 0 ? '+$text' : '-$text';
}

class EloRatings {
  EloRatings._(
    this._teams,
    this._players,
    this._defenseVs, {
    required this.season,
    required this.asOfWeek,
    required this.note,
    this.upcomingWeek = 0,
    this.upcoming = const [],
    this.backups = const [],
  }) {
    for (final p in _players) {
      _byId[p.id] = p;
      _byName.putIfAbsent(_norm(p.name), () => []).add(p);
    }
  }

  final int season, asOfWeek;
  final String note;

  /// Rest, travel and referee for the coming week's games (raw rows).
  final int upcomingWeek;
  final List<Map<String, Object?>> upcoming;

  /// Backups stepping in for a starter ruled out (assets/backup-watch.json
  /// `current`). Research shown beside the ratings, never part of a chance.
  final List<BackupStepIn> backups;
  final Map<String, EloTeam> _teams;
  final List<EloPlayer> _players;
  final Map<String, Map<String, double>> _defenseVs;
  final Map<String, EloPlayer> _byId = {};
  final Map<String, List<EloPlayer>> _byName = {};

  static final empty = EloRatings._(
    const {},
    const [],
    const {},
    season: 0,
    asOfWeek: 0,
    note: '',
  );

  bool get isEmpty => _teams.isEmpty;
  int get teamCount => _teams.length;

  factory EloRatings.fromJson(Map<String, dynamic> json) {
    double? d(Object? v) => v is num ? v.toDouble() : null;
    final teams = <String, EloTeam>{};
    for (final row in (json['teams'] as List? ?? const [])) {
      if (row is! Map) continue;
      final code = '${row['t'] ?? ''}';
      if (code.isEmpty) continue;
      teams[code] = EloTeam(
        code: code,
        overall: (row['o'] as num?)?.toInt() ?? 0,
        offense: (row['off'] as num?)?.toInt() ?? 0,
        defense: (row['def'] as num?)?.toInt() ?? 0,
        net: d(row['net']) ?? 0,
        quarterback: row['qb'] is String ? row['qb'] as String : null,
        lines: {
          if (row['lines'] is Map)
            for (final e in (row['lines'] as Map).entries)
              if (e.value is num) '${e.key}': (e.value as num).toInt(),
        },
        angles: {
          if (row['ang'] is Map)
            for (final e in (row['ang'] as Map).entries) '${e.key}': e.value,
        },
      );
    }
    final players = <EloPlayer>[
      for (final row in (json['players'] as List? ?? const []))
        if (row is Map && row['n'] is String && row['t'] is String)
          EloPlayer(
            name: row['n'] as String,
            id: '${row['id'] ?? ''}',
            team: row['t'] as String,
            position: '${row['p'] ?? ''}',
            overall: (row['o'] as num?)?.toInt() ?? 0,
            defense: row['d'] == 1,
            snaps: (row['s'] as num?)?.toInt() ?? 0,
            yardsPerTarget: d(row['ypt']),
            catchRate: d(row['cr']),
            targetShare: d(row['ts']),
            yardsPerCarry: d(row['ypc']),
            yardsPerAttempt: d(row['ypa']),
            attributes: {
              if (row['a'] is Map)
                for (final e in (row['a'] as Map).entries)
                  if (e.value is num) '${e.key}': (e.value as num).toInt(),
            },
            situations: {
              if (row['sit'] is Map)
                for (final e in (row['sit'] as Map).entries)
                  if (e.value is num) '${e.key}': (e.value as num).toInt(),
            },
          ),
    ];
    final defenseVs = <String, Map<String, double>>{};
    final raw = json['defVs'];
    if (raw is Map) {
      raw.forEach((team, values) {
        if (values is! Map) return;
        defenseVs['$team'] = {
          for (final e in values.entries)
            if (e.value is num) '${e.key}': (e.value as num).toDouble(),
        };
      });
    }
    return EloRatings._(
      teams,
      players,
      defenseVs,
      season: (json['season'] as num?)?.toInt() ?? 0,
      asOfWeek: (json['asOfWeek'] as num?)?.toInt() ?? 0,
      note: '${json['note'] ?? ''}',
      upcomingWeek: json['upcoming'] is Map
          ? ((json['upcoming'] as Map)['week'] as num?)?.toInt() ?? 0
          : 0,
      upcoming: [
        if (json['upcoming'] is Map &&
            (json['upcoming'] as Map)['games'] is List)
          for (final g in ((json['upcoming'] as Map)['games'] as List))
            if (g is Map) {for (final e in g.entries) '${e.key}': e.value},
      ],
      backups: [
        if (json['backupWatch'] is List)
          for (final row in json['backupWatch'] as List)
            if (row is Map) BackupStepIn.fromJson(row),
      ],
    );
  }

  EloTeam? team(String code) => _teams[code == 'LAR' ? 'LA' : code];

  /// Offense first when a player has both; null when the name is ambiguous.
  EloPlayer? player({String? id, String? name, String? team}) {
    if (id != null && _byId.containsKey(id)) return _byId[id];
    if (name == null) return null;
    var hits = _byName[_norm(name)] ?? const <EloPlayer>[];
    if (team != null) {
      final onTeam = hits.where((p) => p.team == team).toList();
      if (onTeam.isNotEmpty) hits = onTeam;
    }
    final offense = hits.where((p) => !p.defense).toList();
    if (offense.length == 1) return offense.first;
    if (hits.length == 1) return hits.first;
    return null;
  }

  /// A player named in a question: full name first, then a last name that
  /// only one offensive player has.
  EloPlayer? playerIn(String question) {
    final q = ' ${_norm(question)} ';
    EloPlayer? best;
    for (final entry in _byName.entries) {
      if (entry.key.length < 5 || !q.contains(' ${entry.key} ')) continue;
      final found = player(name: entry.value.first.name);
      if (found != null &&
          (best == null || entry.key.length > _norm(best.name).length)) {
        best = found;
      }
    }
    if (best != null) return best;
    final words = q.trim().split(' ').where((w) => w.length > 3).toSet();
    final hits = <EloPlayer>[];
    for (final p in _players) {
      if (p.defense || p.snaps < 150) continue;
      final last = _norm(p.name).split(' ').last;
      if (words.contains(last)) hits.add(p);
    }
    return hits.length == 1 ? hits.single : null;
  }

  List<String> teamLines(String code) {
    final t = team(code);
    if (t == null) return const [];
    final rank = 1 + _teams.values.where((o) => o.net > t.net).length;
    final lines = <String>[
      'Coach rating: ${t.code} ${t.overall} out of 99, ${_ordinal(rank)} of ${_teams.length}. '
          'Offense ${t.offense}, defense ${t.defense}.',
      '${t.code} rates ${_signed(t.net)} points a game against an average team on a neutral field.',
    ];
    final qb = t.quarterback == null
        ? null
        : player(name: t.quarterback, team: t.code);
    if (qb != null) lines.add('Quarterback ${qb.name} rates ${qb.overall}.');
    final sec = secondary(t.code);
    if (sec != null) {
      lines.add(
        'Secondary $sec (average of its top four corners and safeties).',
      );
    }
    return lines;
  }

  static const _positionWords = {
    'QB': r'qbs?|quarterbacks?',
    'WR': r'wrs?|receivers?|wide receivers?',
    'TE': r'tes?|tight ends?',
    'RB': r'rbs?|running backs?|backs',
    'CB': r'cbs?|corners?|cornerbacks?',
    'S': r'safet(y|ies)',
    'OL': r'ol|o-?line(men)?|offensive line(men)?|tackles?|guards?|centers?',
    'DL': r'dl|d-?line(men)?|defensive line(men)?|pass rushers?|edge rushers?|defensive ends?|des|dts?',
    'LB': r'lbs?|linebackers?',
    'K': r'kickers?',
    'P': r'punters?',
  };
  static const _groupPositions = {
    'S': {'S', 'FS', 'SS', 'SAF'},
    'OL': {'T', 'G', 'C', 'OL', 'OT', 'OG'},
    'DL': {'DE', 'DT', 'NT', 'DL'},
    'LB': {'LB', 'OLB', 'ILB', 'MLB'},
  };
  static const _groupLabel = {
    'S': 'safeties',
    'OL': 'offensive linemen',
    'DL': 'defensive linemen',
    'LB': 'linebackers',
    'K': 'kickers',
    'P': 'punters',
  };

  /// "Top rated corners", "best teams by elo".
  List<String> topLines(String question) {
    final q = question.toLowerCase();
    if (!RegExp(r'\b(top|best|highest|lowest|worst|bottom)\b').hasMatch(q)) {
      return const [];
    }
    final low = RegExp(r'\b(lowest|worst|bottom)\b').hasMatch(q);
    if (RegExp(r'\bteams?\b').hasMatch(q)) {
      final list = _teams.values.toList()
        ..sort((a, b) => low ? a.net.compareTo(b.net) : b.net.compareTo(a.net));
      return [
        '${low ? 'Lowest' : 'Top'} rated teams: '
            '${list.take(5).map((t) => '${t.code} ${t.overall}').join(', ')}.',
      ];
    }
    for (final entry in _positionWords.entries) {
      if (!RegExp('\\b(${entry.value})\\b').hasMatch(q)) continue;
      final positions = _groupPositions[entry.key] ?? {entry.key};
      final defense = const {'CB', 'S', 'DL', 'LB'}.contains(entry.key);
      final minSnaps = const {'K', 'P'}.contains(entry.key) ? 30 : 150;
      final list =
          _players
              .where(
                (p) =>
                    positions.contains(p.position) &&
                    p.snaps >= minSnaps &&
                    // A two-way player's defensive snaps are not a receiver rating.
                    p.defense == defense,
              )
              .toList()
            ..sort(
              (a, b) => low
                  ? a.overall.compareTo(b.overall)
                  : b.overall.compareTo(a.overall),
            );
      if (list.isEmpty) return const [];
      return [
        '${low ? 'Lowest' : 'Top'} rated ${_groupLabel[entry.key] ?? '${entry.key}s'}: '
            '${list.take(5).map((p) => '${p.name} (${p.team}) ${p.overall}').join(', ')}.',
      ];
    }
    return const [];
  }

  /// Rank 1 = fewest yards per target allowed to that position.
  int? defenseRank(String team, String position) {
    final key = position == 'QB' ? null : (position == 'FB' ? 'RB' : position);
    if (key == null) return null;
    final mine = _defenseVs[team]?[key];
    if (mine == null) return null;
    var rank = 1;
    for (final row in _defenseVs.values) {
      final other = row[key];
      if (other != null && other < mine) rank++;
    }
    return rank;
  }

  int? runDefenseRank(String team) {
    final mine = _defenseVs[team]?['ypc'];
    if (mine == null) return null;
    var rank = 1;
    for (final row in _defenseVs.values) {
      final other = row['ypc'];
      if (other != null && other < mine) rank++;
    }
    return rank;
  }

  /// Average overall of the four corners and safeties who play the most.
  int? secondary(String team) {
    final dbs =
        _players
            .where(
              (p) =>
                  p.team == team &&
                  p.defense &&
                  _secondaryPositions.contains(p.position),
            )
            .toList()
          ..sort((a, b) => b.snaps.compareTo(a.snaps));
    if (dbs.isEmpty) return null;
    final top = dbs.take(4);
    return (top.map((p) => p.overall).reduce((a, b) => a + b) / top.length)
        .round();
  }

  /// "BUF pass block 84 vs MIA pass rush 64" for both offenses.
  List<String> _lineMatchups(EloTeam a, EloTeam h) {
    final out = <String>[];
    for (final pair in [(a, h), (h, a)]) {
      final off = pair.$1.lines, def = pair.$2.lines;
      final pb = off['passBlock'], pr = def['passRush'];
      final rb = off['runBlock'], rd = def['runDefense'];
      if (pb == null || pr == null || rb == null || rd == null) continue;
      out.add(
        'Trenches: ${pair.$1.code} pass block $pb vs ${pair.$2.code} pass rush $pr; '
        '${pair.$1.code} run block $rb vs ${pair.$2.code} run defense $rd.',
      );
    }
    return out;
  }

  static double? _num(Object? v) => v is num ? v.toDouble() : null;

  String _pct(double v) => '${(v * 100).round()}%';

  /// Coaching, scheme, chemistry, line continuity, injuries, rest, travel and
  /// referee lines for a game. Each is skipped when its data is missing.
  List<String> _angleLines(EloTeam a, EloTeam h) {
    final out = <String>[];
    final coaches = <String>[];
    for (final t in [a, h]) {
      final ang = t.angles;
      final coach = ang['coach'];
      if (coach is! String) continue;
      final bits = <String>[];
      final proe = _num(ang['proe']);
      if (proe != null) {
        bits.add('passes ${_signed(proe)}% vs expected');
      }
      final go = _num(ang['go4']);
      if (go != null) {
        bits.add('goes for it on ${_pct(go)} of short 4th downs');
      }
      coaches.add(
        '${t.code} $coach${bits.isEmpty ? '' : ' (${bits.join(', ')})'}',
      );
    }
    if (coaches.isNotEmpty) out.add('Coaching: ${coaches.join('; ')}.');
    for (final pair in [(a, h), (h, a)]) {
      final off = pair.$1, def = pair.$2;
      final blitz = _num(def.angles['blitz']);
      final pa = _num(off.angles['pa']);
      if (blitz == null && pa == null) continue;
      final bits = <String>[
        if (blitz != null) '${def.code} blitzes on ${_pct(blitz)} of dropbacks',
        if (pa != null) '${off.code} uses play-action on ${_pct(pa)}',
      ];
      out.add('Scheme: ${bits.join('; ')}.');
    }
    for (final t in [a, h]) {
      final chem = t.angles['chem'];
      if (chem is Map && chem['qb'] is String && chem['rec'] is String) {
        final v = _num(chem['v']) ?? 0;
        out.add(
          'Chemistry: ${chem['qb']} to ${chem['rec']} is ${t.code}\'s best pair, '
          '${_signed(v, digits: 2)} EPA per target beyond what each does with others.',
        );
      }
    }
    final ol = <String>[
      for (final t in [a, h])
        if (t.angles['olTogether'] is num)
          '${t.code} ${(t.angles['olTogether'] as num).toInt()}',
    ];
    if (ol.isNotEmpty) {
      out.add(
        'Offensive line: games the current starting five have started together this season: ${ol.join(', ')}.',
      );
    }
    for (final t in [a, h]) {
      final outs = t.angles['out'];
      if (outs is! List || outs.isEmpty) continue;
      final names = [
        for (final o in outs.take(4))
          if (o is Map) '${o['n']} (${o['p']})',
      ];
      final pts = _num(t.angles['outPts']);
      out.add(
        'Injuries: ${t.code} lists ${names.join(', ')} out or doubtful'
        '${pts == null ? '' : ', worth about ${pts.toStringAsFixed(1)} points a game by their ratings'}.',
      );
    }
    final game = upcoming.where((g) => g['h'] == h.code && g['a'] == a.code);
    if (game.isNotEmpty) {
      final g = game.first;
      final rest = <String>[
        if (g['restA'] is num)
          '${a.code} ${(g['restA'] as num).toInt()} days of rest',
        if (g['restH'] is num) '${h.code} ${(g['restH'] as num).toInt()}',
      ];
      final miles = _num(g['milesA']);
      final tz = _num(g['tzA']);
      var travel = '';
      if (miles != null && miles > 0) {
        travel = '; ${a.code} travels ${miles.round()} miles';
        if (tz != null && tz != 0) {
          travel +=
              ' and ${tz.abs().round()} time zone${tz.abs() == 1 ? '' : 's'}';
        }
      }
      final early = g['early'];
      final body = early is List && early.isNotEmpty
          ? ' ${early.join(' and ')} kicks off at 10 AM or earlier on its home clock.'
          : '';
      if (rest.isNotEmpty) {
        out.add('Rest and travel: ${rest.join(', ')}$travel.$body');
      }
      final ref = g['ref'];
      if (ref is String) {
        final pens = _num(g['refPens']) ?? 0;
        final total = _num(g['refTotal']) ?? 0;
        final home = _num(g['refHome']) ?? 0;
        out.add(
          'Referee: $ref. The crew calls ${_signed(pens)} penalties a game vs average; '
          'their games land ${_signed(total)} points vs the closing total and the home side '
          '${_signed(home)} vs the spread (shrunk toward zero).',
        );
      }
    }
    return out;
  }

  int get _teams32 => _defenseVs.isEmpty ? _teams.length : _defenseVs.length;

  /// Short lines for a game. Empty when either team is missing.
  List<String> gameLines(String home, String away) {
    final h = team(home), a = team(away);
    if (h == null || a == null) return const [];
    final gap = h.net - a.net;
    final better = gap >= 0 ? h : a;
    final lines = <String>[
      'Coach ratings: ${a.code} ${a.overall}, ${h.code} ${h.overall} (out of 99). '
          '${better.code} rates ${gap.abs().toStringAsFixed(1)} points a game better on a neutral field.',
      '${a.code} offense ${a.offense}, defense ${a.defense}. ${h.code} offense ${h.offense}, defense ${h.defense}.',
    ];
    lines.addAll(_lineMatchups(a, h));
    lines.addAll(_angleLines(a, h));
    final qbs = <String>[];
    for (final t in [a, h]) {
      final qb = t.quarterback == null
          ? null
          : player(name: t.quarterback, team: t.code);
      if (qb != null) qbs.add('${t.code} QB ${qb.name} ${qb.overall}');
    }
    if (qbs.isNotEmpty) {
      qbs.length == 2
          ? lines.add('${qbs.join(', ')}.')
          : lines.add('${qbs.single}.');
    }
    for (final t in [a, h]) {
      for (final b in backups) {
        if (team(b.team)?.code == t.code) lines.add(b.sentence());
      }
    }
    for (final pair in [(a, h), (h, a)]) {
      final sec = secondary(pair.$2.code);
      if (sec != null) {
        lines.add(
          '${pair.$2.code} secondary $sec (average of its top four corners and safeties).',
        );
      }
    }
    return lines;
  }

  /// Short lines for one player against an opponent (when known).
  List<String> playerLines({
    String? id,
    String? name,
    String? team,
    String? opponent,
  }) {
    final p = player(id: id, name: name, team: team);
    if (p == null) return const [];
    final lines = <String>[
      'Coach rating: ${p.name} (${p.team} ${p.position}) ${p.overall} out of 99.',
    ];
    final skills = <String>[];
    if (p.targetShare != null) {
      skills.add('target share ${_signed(p.targetShare! * 100)} pts');
    }
    if (p.yardsPerTarget != null) {
      skills.add('yards per target ${_signed(p.yardsPerTarget!)}');
    }
    if (p.catchRate != null) {
      skills.add('catch rate ${_signed(p.catchRate! * 100)} pts');
    }
    if (p.yardsPerCarry != null && p.position != 'QB') {
      skills.add('yards per carry ${_signed(p.yardsPerCarry!)}');
    }
    if (p.yardsPerAttempt != null) {
      skills.add('yards per attempt ${_signed(p.yardsPerAttempt!)}');
    }
    if (skills.isNotEmpty) {
      lines.add('Against league average: ${skills.join(', ')}.');
    }
    if (p.attributes.isNotEmpty) {
      lines.add(
        'Traits (40-99 vs his position): '
        '${p.attributes.entries.map((e) => '${e.key} ${e.value}').join(', ')}.',
      );
    }
    if (p.situations.isNotEmpty) {
      final role = p.position == 'QB'
          ? 'passers'
          : p.position == 'RB' || p.position == 'FB'
          ? 'rushers'
          : 'receivers';
      lines.add(
        'Situations (40-99 vs other $role): '
        '${p.situations.entries.map((e) => '${e.key} ${e.value}').join(', ')}.',
      );
    }
    if (opponent != null && opponent != p.team) {
      final n = _teams32;
      if (p.position == 'QB') {
        final sec = secondary(opponent);
        final def = this.team(opponent)?.defense;
        if (def != null) {
          lines.add(
            '$opponent defense rates $def${sec == null ? '' : ', its secondary $sec'}.',
          );
        }
      } else {
        final rank = defenseRank(opponent, p.position);
        final sec = secondary(opponent);
        if (rank != null) {
          lines.add(
            '$opponent pass defense against ${p.position}s ranks ${_ordinal(rank)} of $n '
            '(1st allows the fewest yards per target)'
            '${sec == null ? '' : '. Its secondary rates $sec'}.',
          );
        }
        if (p.position == 'RB') {
          final run = runDefenseRank(opponent);
          if (run != null) {
            lines.add(
              '$opponent run defense ranks ${_ordinal(run)} of $n in yards per carry allowed.',
            );
          }
        }
        final qbName = this.team(p.team)?.quarterback;
        final qb = qbName == null ? null : player(name: qbName, team: p.team);
        if (qb != null) {
          lines.add('His quarterback, ${qb.name}, rates ${qb.overall}.');
        }
      }
    }
    return lines;
  }
}

String _ordinal(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}


/// One backup stepping in for a starter ruled out, from tools/backup_watch.py.
class BackupStepIn {
  const BackupStepIn({
    required this.team,
    required this.backup,
    required this.outNames,
    this.backupRating,
    this.projection = const {},
    this.bestPrice,
  });

  factory BackupStepIn.fromJson(Map raw) {
    final out = <String>[
      for (final o in (raw['out'] as List? ?? const []))
        if (o is Map && o['player'] is String)
          '${o['player']} (${o['status'] ?? 'out'})',
    ];
    final projection = <String, double>{
      if (raw['projection'] is Map)
        for (final e in (raw['projection'] as Map).entries)
          if (e.value is num) '${e.key}': (e.value as num).toDouble(),
    };
    Map<String, Object?>? best;
    for (final p in (raw['prices'] as List? ?? const [])) {
      if (p is! Map || p['side'] == null) continue;
      final edge = p['side'] == 'over' ? p['overEdge'] : p['underEdge'];
      final current = best == null
          ? null
          : (best['side'] == 'over' ? best['overEdge'] : best['underEdge']);
      if (edge is num && (current is! num || edge > current)) {
        best = {for (final e in p.entries) '${e.key}': e.value};
      }
    }
    return BackupStepIn(
      team: '${raw['team'] ?? ''}',
      backup: '${raw['backup'] ?? ''}',
      backupRating: (raw['backupRating'] as num?)?.toInt(),
      outNames: out,
      projection: projection,
      bestPrice: best,
    );
  }

  final String team, backup;
  final int? backupRating;
  final List<String> outNames;
  final Map<String, double> projection;
  final Map<String, Object?>? bestPrice;

  static const _labels = {
    'player_pass_yds': 'passing yards',
    'player_pass_attempts': 'pass attempts',
    'player_pass_completions': 'completions',
    'player_rush_yds': 'rushing yards',
    'player_reception_yds': 'receiving yards',
    'player_receptions': 'receptions',
  };

  static const _books = {
    'fanduel': 'FanDuel',
    'bovada': 'Bovada',
    'betrivers': 'BetRivers',
  };

  String sentence() {
    final rating = backupRating == null ? '' : ' (Coach rating $backupRating)';
    final parts = [
      for (final e in projection.entries)
        if (_labels.containsKey(e.key))
          '${e.value.toStringAsFixed(e.key == 'player_receptions' ? 1 : 0)} ${_labels[e.key]}',
    ];
    final buffer = StringBuffer(
      'Next man up, $team: $backup$rating for ${outNames.join(' and ')}.',
    );
    if (parts.isNotEmpty) buffer.write(' Coach projects ${parts.join(', ')}.');
    final p = bestPrice;
    if (p != null) {
      final side = '${p['side']}';
      final chance = p['overChance'] is num
          ? (side == 'over'
                ? p['overChance'] as num
                : 1 - (p['overChance'] as num))
          : null;
      final price = p[side];
      final book = _books[p['book']] ?? '${p['book']}';
      final label = _labels[p['market']] ?? '${p['market']}';
      if (chance != null && price is num) {
        buffer.write(
          ' $book $side ${p['line']} $label at ${price.toStringAsFixed(2)}; '
          'Coach puts it at ${(chance * 100).round()}%.',
        );
      }
    }
    buffer.write(' Research being tracked against the close, not a pick.');
    return buffer.toString();
  }
}
