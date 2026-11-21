import 'coach_telemetry.dart';

/// Movement is shown from saved prices. It is not the served chance.
///
/// Version 2 stays the game number. The free open/close archive does not
/// contain 2025 or 2026, so this path was not adopted.
const lineMovementAdopted = false;

class LineSteam {
  const LineSteam({
    required this.books,
    required this.minutes,
    required this.direction,
  });

  final List<String> books;
  final int minutes;
  final String direction;

  factory LineSteam.fromJson(Map<String, dynamic> json) {
    return LineSteam(
      books: [
        for (final book in json['books'] as List? ?? const []) '$book',
      ],
      minutes: json['minutes'] is num ? (json['minutes'] as num).toInt() : 0,
      direction: '${json['direction'] ?? ''}',
    );
  }
}

/// One saved path. A null number was not in the file.
class LineMove {
  const LineMove({
    required this.eventId,
    required this.market,
    required this.book,
    required this.player,
    required this.outcome,
    this.home = '',
    this.away = '',
    this.homeName = '',
    this.awayName = '',
    this.kickoff = '',
    this.openLine,
    this.closeLine,
    this.openToClose,
    this.lateFrom,
    this.lateTo,
    this.lateMove,
    this.keyNumbers,
    this.pinnacleLine,
    this.retailLine,
    this.steam,
  });

  final String eventId, market, book, player, outcome;
  final String home, away, homeName, awayName, kickoff;
  final double? openLine, closeLine, openToClose, lateFrom, lateTo, lateMove;
  final List<int>? keyNumbers;
  final double? pinnacleLine, retailLine;
  final LineSteam? steam;

  bool get measured => lateMove != null || openToClose != null;

  factory LineMove.fromJson(Map<String, dynamic> json) {
    double? number(String key) =>
        json[key] is num ? (json[key] as num).toDouble() : null;
    List<int>? keys;
    if (json['keyNumbers'] is List) {
      keys = [
        for (final value in json['keyNumbers'] as List)
          if (value is num) value.toInt(),
      ];
    }
    final steam = json['steam'];
    return LineMove(
      eventId: '${json['eventId'] ?? ''}',
      market: '${json['market'] ?? ''}',
      book: '${json['book'] ?? ''}',
      player: '${json['player'] ?? ''}',
      outcome: '${json['outcome'] ?? ''}',
      home: '${json['home'] ?? ''}',
      away: '${json['away'] ?? ''}',
      homeName: '${json['homeName'] ?? ''}',
      awayName: '${json['awayName'] ?? ''}',
      kickoff: '${json['kickoff'] ?? ''}',
      openLine: number('openLine'),
      closeLine: number('closeLine'),
      openToClose: number('openToClose'),
      lateFrom: number('lateFrom'),
      lateTo: number('lateTo'),
      lateMove: number('lateMove'),
      keyNumbers: keys,
      pinnacleLine: number('pinnacleLine'),
      retailLine: number('retailLine'),
      steam: steam is Map ? LineSteam.fromJson(Map<String, dynamic>.from(steam)) : null,
    );
  }

  /// The sentence for this path. [full] names the features that are missing.
  String sentence({bool full = false}) {
    final parts = <String>[_lead()];
    if (keyNumbers != null && keyNumbers!.isNotEmpty) {
      parts.add(
        'That move crossed ${keyNumbers!.map((number) => '$number').join(' and ')}.',
      );
    } else if (full && market == 'spreads') {
      parts.add('A move through a key number is unavailable.');
    }
    if (market == 'spreads' &&
        (full || (pinnacleLine != null && retailLine != null))) {
      parts.add(_disagreement());
    }
    if (full) {
      parts.add(_steamSentence());
      parts.add('A move against the public is unavailable.');
    }
    parts.add('This is a comparison, not a pick.');
    return parts.join(' ');
  }

  String _lead() {
    final label = _label();
    if (lateFrom != null && lateTo != null && lateFrom != lateTo) {
      final late =
          '$label moved from ${_points(lateFrom!)} to ${_points(lateTo!)} in the last 3 hours.${_homeNote()}';
      if (openLine != null &&
          closeLine != null &&
          openToClose != null &&
          (openLine != lateFrom || closeLine != lateTo)) {
        return '$late From the first saved price to the last price before kickoff, it moved from ${_points(openLine!)} to ${_points(closeLine!)}.';
      }
      return late;
    }
    if (openLine != null && closeLine != null && openToClose != null && openLine != closeLine) {
      return '$label moved from ${_points(openLine!)} to ${_points(closeLine!)} from the first saved price to the last price before kickoff.${_homeNote()} A move in the last 3 hours is unavailable.';
    }
    if (openLine != null || closeLine != null) {
      return 'Line movement is unavailable. One saved price cannot be compared with itself.';
    }
    return 'Line movement is unavailable.';
  }

  String _homeNote() => market == 'spreads' ? ' That is the home spread.' : '';

  String _label() {
    final bookName = book == 'median' || book.isEmpty ? '' : '${_book(book)} ';
    if (market == 'spreads') {
      return bookName.isEmpty ? 'The line' : 'The ${bookName.trim()} line';
    }
    if (market == 'totals') return 'The ${bookName}total'.replaceAll('  ', ' ');
    if (market == 'h2h') return 'The ${bookName}moneyline'.replaceAll('  ', ' ');
    final stat = switch (market) {
      'player_reception_yds' => 'receiving yards line',
      'player_receptions' => 'receptions line',
      'player_rush_yds' => 'rushing yards line',
      'player_pass_yds' => 'passing yards line',
      _ => 'line',
    };
    final who = player.isEmpty ? 'The $stat' : 'The $stat for $player';
    final side = outcome.isEmpty ? '' : ' ${outcome.toLowerCase()}';
    return '$who$side';
  }

  String _disagreement() {
    if (pinnacleLine == null || retailLine == null) {
      return 'Pinnacle versus the other books is unavailable.';
    }
    if (pinnacleLine == retailLine) {
      return 'Pinnacle and the other books are on ${_points(pinnacleLine!)}.';
    }
    return 'Pinnacle is ${_points(pinnacleLine!)} and the other books are ${_points(retailLine!)}.';
  }

  String _steamSentence() {
    final move = steam;
    if (move == null || move.books.length < 3) {
      return 'A fast move across books is unavailable.';
    }
    final names = move.books.map(_book).toList()..sort();
    final toward = move.direction == 'home' ? 'the home team' : 'the away team';
    final window = move.minutes <= 0
        ? 'in the same snapshot'
        : 'inside ${move.minutes} minutes';
    return '${_join(names)} moved toward $toward $window.';
  }
}

class LineMoveBook {
  const LineMoveBook({required this.moves, required this.adopted});

  final List<LineMove> moves;
  final bool adopted;

  static const empty = LineMoveBook(moves: [], adopted: false);

  factory LineMoveBook.fromJson(Map<String, dynamic> json) {
    final rows = json['moves'];
    return LineMoveBook(
      moves: [
        for (final row in rows is List ? rows : const [])
          if (row is Map) LineMove.fromJson(Map<String, dynamic>.from(row)),
      ],
      adopted: json['adopted'] == true && lineMovementAdopted,
    );
  }

  /// Text to add to an answer. A game answer stays quiet until a move was measured.
  String? sentenceFor({
    String? home,
    String? away,
    String question = '',
    bool onlyWhenMeasured = false,
  }) {
    final asked = asksAboutSavedMovement(question);
    final match = _pick(home: home, away: away, question: question);
    if (match == null) {
      if (!asked || onlyWhenMeasured) return null;
      return 'Line movement is unavailable. This is a comparison, not a pick.';
    }
    if (onlyWhenMeasured && !match.measured) return null;
    return match.sentence(full: asked);
  }

  LineMove? _pick({String? home, String? away, String question = ''}) {
    final wanted = _market(question);
    final pool = [
      for (final move in moves)
        if (_sameGame(move, home, away)) move,
    ];
    if (pool.isEmpty) return null;
    final marketPool = wanted == null
        ? pool
        : pool.where((move) => move.market == wanted).toList();
    final rows = marketPool.isEmpty ? pool : marketPool;
    final measured = rows.where((move) => move.measured).toList();
    final choice = (measured.isEmpty ? rows : measured).toList()
      ..sort((a, b) => (b.kickoff).compareTo(a.kickoff));
    if (wanted != null) {
      return choice.firstWhere(
        (move) => move.market == wanted,
        orElse: () => choice.first,
      );
    }
    for (final market in ['spreads', 'totals', 'h2h']) {
      final found = choice.where((move) => move.market == market);
      if (found.isNotEmpty) return found.first;
    }
    return choice.first;
  }

  bool _sameGame(LineMove move, String? home, String? away) {
    if ((home == null || home.isEmpty) && (away == null || away.isEmpty)) {
      return false;
    }
    bool hit(String? asked, String code, String name) {
      if (asked == null || asked.isEmpty) return true;
      final text = asked.toLowerCase();
      return text == code.toLowerCase() ||
          text == name.toLowerCase() ||
          name.toLowerCase().contains(text) ||
          text.contains(name.toLowerCase()) && name.isNotEmpty;
    }
    return hit(home, move.home, move.homeName) && hit(away, move.away, move.awayName);
  }
}

bool asksAboutSavedMovement(String question) {
  if (asksAboutLineMovement(question)) return true;
  return RegExp(
    r'\b(?:line|spread|total|moneyline|odds|price)\b.{0,24}\b(?:move|moved|movement|open|opening)\b',
    caseSensitive: false,
  ).hasMatch(question);
}

String _market(String question) {
  final text = question.toLowerCase();
  if (text.contains('receiving') && text.contains('yard')) {
    return 'player_reception_yds';
  }
  if (text.contains('reception')) return 'player_receptions';
  if (text.contains('rush')) return 'player_rush_yds';
  if (text.contains('pass') && text.contains('yard')) return 'player_pass_yds';
  if (text.contains('total')) return 'totals';
  if (text.contains('moneyline') || text.contains('money line')) return 'h2h';
  if (text.contains('spread') || text.contains('line')) return 'spreads';
  return '';
}

String _points(double value) {
  final twice = value * 2;
  if ((twice - twice.round()).abs() < 1e-6) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(1);
  }
  return value.toString();
}

String _book(String book) => switch (book) {
  'draftkings' => 'DraftKings',
  'fanduel' => 'FanDuel',
  'betmgm' => 'BetMGM',
  'pinnacle' => 'Pinnacle',
  'williamhill_us' => 'Caesars',
  'espnbet' => 'theScore Bet',
  'fanatics' => 'Fanatics',
  'betrivers' => 'BetRivers',
  'hardrockbet' => 'Hard Rock',
  'ballybet' => 'Bally Bet',
  'fliff' => 'Fliff',
  'median' => 'the books',
  _ => book,
};

String _join(List<String> names) {
  if (names.length <= 1) return names.join();
  if (names.length == 2) return '${names[0]} and ${names[1]}';
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}
