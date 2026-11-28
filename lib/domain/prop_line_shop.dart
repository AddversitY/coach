import 'odds.dart';
import 'price_history.dart';

/// A saved prop price compared with the no-vig average of the books on the
/// same line. A comparison, not a pick.
///
/// At least 3 books must post both sides of that line. A different line is
/// not moved onto the chance. A side is listed when its price pays at least
/// 3% more than a fair payout at the consensus chance. The bar is wider than
/// the 2% Pinnacle rule because this average is the same soft books and each
/// book sits inside it.
const propConsensusMinBooks = 3;
const propConsensusMinEdge = 0.03;
const propConsensusMinFair = 0.10;
const propConsensusMaxFair = 0.90;

const _twoSided = {
  'player_pass_yds',
  'player_rush_yds',
  'player_reception_yds',
  'player_receptions',
  'player_pass_attempts',
  'player_pass_completions',
  'player_pass_tds',
};

class PropConsensusRecord {
  const PropConsensusRecord({
    this.scored,
    this.mean,
    this.low,
    this.high,
    this.passes = false,
  });

  /// Null when the log could not be read. Zero is a real empty log.
  final int? scored;
  final double? mean, low, high;
  final bool passes;

  static const unavailable = PropConsensusRecord();

  factory PropConsensusRecord.fromJson(Map<String, dynamic> json) {
    final summary = json['summary'];
    final clv = summary is Map ? summary['clv'] : null;
    if (clv is! Map) return unavailable;
    final scored = clv['n'];
    return PropConsensusRecord(
      scored: scored is num ? scored.toInt() : null,
      mean: (clv['mean'] as num?)?.toDouble(),
      low: (clv['low'] as num?)?.toDouble(),
      high: (clv['high'] as num?)?.toDouble(),
      passes: summary['passes'] == true,
    );
  }
}

class _Quote {
  _Quote(this.row, this.event, this.away, this.home, this.side, this.line);
  final SavedBookPrice row;
  final String event, away, home, side;
  final double line;
}

class PropConsensusFlag {
  PropConsensusFlag({
    required this.book,
    required this.player,
    required this.market,
    required this.outcome,
    required this.line,
    required this.decimal,
    required this.at,
    required this.fairChance,
    required this.edge,
    required this.books,
  });

  final String book, player, market, outcome, at;
  final double line, decimal, fairChance, edge;
  final int books;
}

bool asksPropComparison(String question, {bool hasPlayer = false}) {
  final q = question.toLowerCase();
  final prop = RegExp(
    r'\b(props?|yards|receptions?|catches|carries|rush(?:ing)?|pass(?:ing|es)?|touchdowns?|anytime|tds?)\b',
  ).hasMatch(q);
  if (!prop) return false;
  if (hasPlayer) return true;
  return RegExp(
    r'\b(price|prices|odds|line|lines|over|under|book|books|shop|compare)\b',
  ).hasMatch(q);
}

String? namedPlayer(String question, Iterable<String> names) {
  final q = question.toLowerCase();
  String? best;
  for (final name in names) {
    final text = name.trim();
    if (text.length >= 3 &&
        q.contains(text.toLowerCase()) &&
        (best == null || text.length > best.length)) {
      best = text;
    }
  }
  return best;
}

String? marketFromQuestion(String question) {
  final text = question.toLowerCase();
  if (text.contains('reception') && !text.contains('yard')) {
    return 'player_receptions';
  }
  if (text.contains('receiving')) return 'player_reception_yds';
  if (text.contains('rush')) return 'player_rush_yds';
  if (text.contains('anytime')) return 'player_anytime_td';
  if (text.contains('attempt')) return 'player_pass_attempts';
  if (text.contains('completion')) return 'player_pass_completions';
  if (text.contains('touchdown') || RegExp(r'\btds?\b').hasMatch(text)) {
    return 'player_pass_tds';
  }
  if (text.contains('pass')) return 'player_pass_yds';
  return null;
}

double? _noVig(double over, double under) {
  if (over <= 1 || under <= 1) return null;
  final a = 1 / over, b = 1 / under;
  return a / (a + b);
}

(String, String, String)? _identity(SavedBookPrice row) {
  final event = row.eventId ?? '';
  var away = '';
  var home = '';
  if (event.startsWith('nflverse:')) {
    final parts = event.split(':').last.split('_');
    if (parts.length >= 4 && parts[2].isNotEmpty && parts[3].isNotEmpty) {
      away = parts[2] == 'LAR' ? 'LA' : parts[2];
      home = parts[3] == 'LAR' ? 'LA' : parts[3];
    }
  }
  if (away.isEmpty || home.isEmpty) return null;
  return (event, away, home);
}

String _side(String outcome) {
  final text = outcome.toLowerCase();
  if (text == 'over') return 'Over';
  if (text == 'under') return 'Under';
  return '';
}

List<PropConsensusFlag> propConsensusFlags(
  List<SavedBookPrice> prices, {
  String? player,
  String? market,
  double? line,
  String? eventId,
}) {
  final latest = <String, _Quote>{};
  for (final row in prices) {
    if (!_twoSided.contains(row.market) || row.decimal <= 1 || row.decimal > 100) {
      continue;
    }
    final point = row.line;
    final who = _identity(row);
    final side = _side(row.outcome);
    if (point == null || who == null || side.isEmpty || row.player.isEmpty) {
      continue;
    }
    final key = '${who.$1}|${row.book}|${row.market}|${row.player}|$side';
    final prev = latest[key];
    if (prev == null || (row.at ?? '').compareTo(prev.row.at ?? '') >= 0) {
      latest[key] = _Quote(row, who.$1, who.$2, who.$3, side, point);
    }
  }
  final buckets = <String, List<_Quote>>{};
  for (final item in latest.values) {
    final key = '${item.event}|${item.row.market}|${item.row.player}|${item.line}';
    buckets.putIfAbsent(key, () => []).add(item);
  }
  final flags = <PropConsensusFlag>[];
  for (final items in buckets.values) {
    if (player != null &&
        player.isNotEmpty &&
        !items.first.row.player.toLowerCase().contains(player.toLowerCase()) &&
        !player.toLowerCase().contains(items.first.row.player.toLowerCase())) {
      continue;
    }
    if (market != null && market.isNotEmpty && items.first.row.market != market) {
      continue;
    }
    if (eventId != null && eventId.isNotEmpty && items.first.event != eventId) {
      continue;
    }
    if (line != null && items.first.line != line) continue;
    final byBook = <String, Map<String, _Quote>>{};
    for (final item in items) {
      byBook.putIfAbsent(item.row.book, () => {})[item.side] = item;
    }
    final fairs = <MapEntry<String, double>>[];
    for (final entry in byBook.entries) {
      final over = entry.value['Over'];
      final under = entry.value['Under'];
      if (over == null || under == null) continue;
      final chance = _noVig(over.row.decimal, under.row.decimal);
      if (chance == null) continue;
      fairs.add(MapEntry(entry.key, chance));
    }
    if (fairs.length < propConsensusMinBooks) continue;
    final consensus = fairs.map((item) => item.value).reduce((a, b) => a + b) / fairs.length;
    for (final sides in byBook.values) {
      for (final side in ['Over', 'Under']) {
        final item = sides[side];
        if (item == null) continue;
        final chance = side == 'Over' ? consensus : 1 - consensus;
        if (chance < propConsensusMinFair || chance > propConsensusMaxFair) continue;
        final edge = chance * item.row.decimal - 1;
        if (edge < propConsensusMinEdge) continue;
        flags.add(
          PropConsensusFlag(
            book: item.row.book,
            player: item.row.player,
            market: item.row.market,
            outcome: side,
            line: item.line,
            decimal: item.row.decimal,
            at: item.row.at ?? '',
            fairChance: chance,
            edge: edge,
            books: fairs.length,
          ),
        );
      }
    }
  }
  flags.sort((a, b) => b.edge.compareTo(a.edge));
  return flags;
}

String _decimalLabel(double value) {
  final text = value
      .toStringAsFixed(6)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
  return text.contains('.') ? text : '$text.0';
}

String _percent(double chance) => '${(chance * 100).toStringAsFixed(1)}%';

String _signedPercent(double value) {
  final text = (value * 100).toStringAsFixed(1);
  return value >= 0 ? '+$text%' : '$text%';
}

String recordSentence(PropConsensusRecord? record) {
  if (record == null || record.scored == null) {
    return 'Prop-consensus closing-line record: unavailable.';
  }
  final n = record.scored!;
  const gate =
      '200 scored bets, with the low end of the range above zero, are needed before this is a signal.';
  final mean = record.mean;
  if (n <= 0 || mean == null) {
    return 'Prop-consensus closing-line record: $n scored bets. $gate';
  }
  final low = record.low;
  final high = record.high;
  final range = low != null && high != null
      ? ' (90% range ${_signedPercent(low)} to ${_signedPercent(high)})'
      : '';
  final cleared = record.passes
      ? ' The closing-line record has cleared the 200-bet bar.'
      : ' $gate';
  return 'Prop-consensus closing-line record: $n scored bets, average closing-line value ${_signedPercent(mean)}$range.$cleared';
}

String _flagSentence(PropConsensusFlag flag) {
  final saved = flag.at.isEmpty ? 'unavailable' : flag.at;
  return '${bookDisplayName(flag.book)}, ${flag.player} ${flag.outcome} ${flag.line} at ${americanLabel(flag.decimal)} (decimal ${_decimalLabel(flag.decimal)}), consensus fair chance ${_percent(flag.fairChance)} from ${flag.books} books, price saved $saved.';
}

/// The sentence shown on a prop answer. Missing prices stay unavailable.
String bestPriceVsOtherBooksSentence({
  required List<SavedBookPrice> prices,
  String question = '',
  String? player,
  String? market,
  double? line,
  String? eventId,
  PropConsensusRecord? record,
  Iterable<String> knownNames = const [],
}) {
  final resolved = (player != null && player.trim().isNotEmpty)
      ? player.trim()
      : namedPlayer(question, {...knownNames, for (final row in prices) row.player});
  final resolvedMarket = (market != null && market.isNotEmpty)
      ? market
      : marketFromQuestion(question);
  final resolvedLine = line ?? _lineFromQuestion(question);
  const framing = 'This is a comparison, not a pick.';
  final recordText = recordSentence(record);
  if (resolvedMarket == 'player_anytime_td') {
    return 'Best price vs other books: unavailable. Anytime touchdown is one-sided, so there is no two-sided consensus to compare. $framing $recordText';
  }
  String? scoped = (eventId != null && eventId.isNotEmpty) ? eventId : null;
  var flags = propConsensusFlags(
    prices,
    player: resolved,
    market: resolvedMarket,
    line: resolvedLine,
    eventId: scoped,
  );
  var groups = _consensusCount(
    prices,
    player: resolved,
    market: resolvedMarket,
    line: resolvedLine,
    eventId: scoped,
  );
  // A game id that matches no saved price falls back to the player's prices.
  if (flags.isEmpty && groups == 0 && scoped != null) {
    scoped = null;
    flags = propConsensusFlags(
      prices,
      player: resolved,
      market: resolvedMarket,
      line: resolvedLine,
    );
    groups = _consensusCount(
      prices,
      player: resolved,
      market: resolvedMarket,
      line: resolvedLine,
    );
  }
  final matched = [
    for (final row in prices)
      if ((resolved == null ||
              resolved.isEmpty ||
              row.player.toLowerCase().contains(resolved.toLowerCase()) ||
              resolved.toLowerCase().contains(row.player.toLowerCase())) &&
          (resolvedMarket == null || row.market == resolvedMarket))
        row,
  ];
  if (flags.isEmpty) {
    final reason = matched.isEmpty
        ? 'No saved price for this prop.'
        : 'Fewer than 3 books have a two-sided price on the same line. A different line is not treated as the same chance.';
    if (groups == 1) {
      final detail = _singleConsensus(
        prices,
        player: resolved,
        market: resolvedMarket,
        line: resolvedLine,
        eventId: scoped,
      );
      if (detail != null) {
        return 'Best price vs other books: no saved price pays 3% more than a fair payout at the consensus chance. Consensus fair chance on the over at ${detail.$1} is ${_percent(detail.$2)} from ${detail.$3} books. $framing $recordText';
      }
    }
    if (groups > 1) {
      return 'Best price vs other books: no saved price pays 3% more than a fair payout at the consensus chance. $framing $recordText';
    }
    return 'Best price vs other books: unavailable. $reason $framing $recordText';
  }
  final shown = flags.take(4).map(_flagSentence).join(' ');
  final extra = flags.length > 4 ? ' ${flags.length - 4} more are not listed.' : '';
  return 'Best price vs other books: $shown$extra $framing $recordText';
}

double? _lineFromQuestion(String question) {
  final match = RegExp(
    r'\b(?:over|under|line)\s+(-?\d+(?:\.\d+)?)\b',
  ).firstMatch(question);
  if (match == null) return null;
  return double.tryParse(match.group(1)!);
}

int _consensusCount(
  List<SavedBookPrice> prices, {
  String? player,
  String? market,
  double? line,
  String? eventId,
}) {
  return _consensusDetails(
    prices,
    player: player,
    market: market,
    line: line,
    eventId: eventId,
  ).length;
}

(double, double, int)? _singleConsensus(
  List<SavedBookPrice> prices, {
  String? player,
  String? market,
  double? line,
  String? eventId,
}) {
  final details = _consensusDetails(
    prices,
    player: player,
    market: market,
    line: line,
    eventId: eventId,
  );
  if (details.length != 1) return null;
  return details.single;
}

List<(double, double, int)> _consensusDetails(
  List<SavedBookPrice> prices, {
  String? player,
  String? market,
  double? line,
  String? eventId,
}) {
  final latest = <String, _Quote>{};
  for (final row in prices) {
    if (!_twoSided.contains(row.market) || row.decimal <= 1 || row.decimal > 100) {
      continue;
    }
    final point = row.line;
    final who = _identity(row);
    final side = _side(row.outcome);
    if (point == null || who == null || side.isEmpty || row.player.isEmpty) continue;
    final key = '${who.$1}|${row.book}|${row.market}|${row.player}|$side';
    final prev = latest[key];
    if (prev == null || (row.at ?? '').compareTo(prev.row.at ?? '') >= 0) {
      latest[key] = _Quote(row, who.$1, who.$2, who.$3, side, point);
    }
  }
  final buckets = <String, List<_Quote>>{};
  for (final item in latest.values) {
    buckets
        .putIfAbsent(
          '${item.event}|${item.row.market}|${item.row.player}|${item.line}',
          () => [],
        )
        .add(item);
  }
  final out = <(double, double, int)>[];
  for (final items in buckets.values) {
    if (player != null &&
        player.isNotEmpty &&
        !items.first.row.player.toLowerCase().contains(player.toLowerCase()) &&
        !player.toLowerCase().contains(items.first.row.player.toLowerCase())) {
      continue;
    }
    if (market != null && market.isNotEmpty && items.first.row.market != market) {
      continue;
    }
    if (eventId != null && eventId.isNotEmpty && items.first.event != eventId) {
      continue;
    }
    if (line != null && items.first.line != line) continue;
    final byBook = <String, Map<String, _Quote>>{};
    for (final item in items) {
      byBook.putIfAbsent(item.row.book, () => {})[item.side] = item;
    }
    final chances = <double>[];
    for (final sides in byBook.values) {
      final over = sides['Over'];
      final under = sides['Under'];
      if (over == null || under == null) continue;
      final chance = _noVig(over.row.decimal, under.row.decimal);
      if (chance != null) chances.add(chance);
    }
    if (chances.length < propConsensusMinBooks) continue;
    final consensus = chances.reduce((a, b) => a + b) / chances.length;
    out.add((items.first.line, consensus, chances.length));
  }
  return out;
}
