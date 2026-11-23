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
  });

  final String code;
  final int overall, offense, defense;

  /// Points per game better than an average team, on a neutral field.
  final double net;
  final String? quarterback;
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
  }) {
    for (final p in _players) {
      _byId[p.id] = p;
      _byName.putIfAbsent(_norm(p.name), () => []).add(p);
    }
  }

  final int season, asOfWeek;
  final String note;
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
      final positions = entry.key == 'S'
          ? const {'S', 'FS', 'SS', 'SAF'}
          : {entry.key};
      final list =
          _players
              .where((p) => positions.contains(p.position) && p.snaps >= 150)
              .toList()
            ..sort(
              (a, b) => low
                  ? a.overall.compareTo(b.overall)
                  : b.overall.compareTo(a.overall),
            );
      if (list.isEmpty) return const [];
      return [
        '${low ? 'Lowest' : 'Top'} rated ${entry.key == 'S' ? 'safeties' : '${entry.key}s'}: '
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
