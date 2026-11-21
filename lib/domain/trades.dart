import 'matchup.dart';

/// A named player trade from the nflverse trades file.
///
/// A row with no player name is a draft pick and is not stored. The public
/// ESPN transactions list returned no items, so a general-manager change is
/// not in this file and stays unavailable.
class PlayerTrade {
  const PlayerTrade({
    required this.date,
    required this.from,
    required this.to,
    required this.name,
    this.season,
  });

  final DateTime date;
  final String from, to, name;
  final int? season;

  String get dateLabel =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  String get sentence =>
      'nflverse trades records $name from $from to $to on $dateLabel. Source: nflverse trades.';

  factory PlayerTrade.fromJson(Map<String, dynamic> json) {
    final raw = '${json['date'] ?? ''}';
    final date = DateTime.tryParse(raw);
    return PlayerTrade(
      date: date == null
          ? DateTime.utc(1970)
          : DateTime.utc(date.year, date.month, date.day),
      from: boxScoreTeam('${json['from'] ?? ''}'),
      to: boxScoreTeam('${json['to'] ?? ''}'),
      name: '${json['name'] ?? ''}',
      season: json['season'] is int ? json['season'] as int : null,
    );
  }
}

class TradeBook {
  TradeBook._(this.trades);

  final List<PlayerTrade> trades;

  static final empty = TradeBook._(const []);

  factory TradeBook.fromJson(Map<String, dynamic> json) {
    final rows = json['trades'];
    if (rows is! List) return TradeBook.empty;
    final trades = <PlayerTrade>[
      for (final row in rows)
        if (row is Map) PlayerTrade.fromJson(Map<String, dynamic>.from(row)),
    ];
    trades.sort((a, b) => a.date.compareTo(b.date));
    return TradeBook._(trades);
  }

  /// A trade of [name] between [from] and [to] dated strictly after [after]
  /// and strictly before [before]. Either direction matches the snap clubs.
  PlayerTrade? between({
    required String name,
    required String from,
    required String to,
    required DateTime after,
    required DateTime before,
  }) {
    final wanted = _tradeName(name);
    if (wanted.isEmpty) return null;
    final origin = boxScoreTeam(from);
    final destination = boxScoreTeam(to);
    final start = DateTime.utc(after.year, after.month, after.day);
    final end = DateTime.utc(before.year, before.month, before.day);
    PlayerTrade? chosen;
    for (final trade in trades) {
      if (_tradeName(trade.name) != wanted) continue;
      final same =
          trade.from == origin && trade.to == destination ||
          trade.from == destination && trade.to == origin;
      if (!same) continue;
      if (!trade.date.isAfter(start) || !trade.date.isBefore(end)) continue;
      if (chosen == null || trade.date.isAfter(chosen.date)) chosen = trade;
    }
    return chosen;
  }
}

String _tradeName(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r"[^a-z0-9 ]"), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
