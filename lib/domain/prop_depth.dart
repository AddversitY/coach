import 'hit_rate.dart';
import 'odds.dart';
import 'player_stats.dart';
import 'value_check.dart';

/// One window of a player's record against a line, such as "Last 10".
class PropWindow {
  const PropWindow({
    required this.label,
    required this.over,
    required this.average,
  });
  final String label;
  final HitRate over;

  /// Mean of the games that recorded the stat. Null when none did.
  final double? average;

  int get decided => over.hits + over.misses;
  int get overs => over.hits;
  int get unders => over.misses;
}

/// How the opponent has treated players at one position this season.
class DefenseVsPosition {
  const DefenseVsPosition({
    required this.opponent,
    required this.position,
    required this.metric,
    required this.allowedPerGame,
    required this.rank,
    required this.teams,
    required this.games,
  });
  final String opponent, position, metric;

  /// Average total of [metric] by all [position] players against [opponent].
  final double allowedPerGame;

  /// 1 = allows the most. Out of [teams] defenses with recorded games.
  final int rank, teams;
  final int games;

  bool get soft => rank <= (teams / 4).ceil();
  bool get tough => rank > teams - (teams / 4).ceil();
}

/// The market's view of one line from the saved prices.
class PropMarketView {
  const PropMarketView({
    required this.line,
    this.bestOver,
    this.bestUnder,
    this.fairOver,
    this.books = 0,
  });
  final double line;
  final OddsQuote? bestOver, bestUnder;

  /// Fee-free over chance averaged across books that posted both sides.
  final double? fairOver;
  final int books;
}

/// Everything Coach shows for "player + stat + line", in one place.
class PropDepth {
  const PropDepth({
    required this.playerId,
    required this.metric,
    required this.line,
    required this.windows,
    this.vsOpponent,
    this.lastSeason,
    this.defense,
    this.market,
    required this.notes,
  });
  final String playerId, metric;
  final double line;
  final List<PropWindow> windows;
  final PropWindow? vsOpponent;

  /// The previous season, shown beside the current windows (Outlier's "LS").
  final PropWindow? lastSeason;
  final DefenseVsPosition? defense;
  final PropMarketView? market;
  final List<String> notes;

  /// Over rate in the longest window with at least 8 decided games,
  /// shrunk toward 50% so a small sample cannot look certain.
  double? get historyOver {
    final sample = windows.reversed.firstWhere(
      (w) => w.decided >= 8,
      orElse: () => windows.last,
    );
    if (sample.decided == 0) return null;
    return (sample.overs + 2) / (sample.decided + 4);
  }

  /// History minus the market's fee-free over chance, in percentage points.
  double? get historyVersusMarket {
    final history = historyOver, fair = market?.fairOver;
    if (history == null || fair == null) return null;
    return (history - fair) * 100;
  }
}

double? _average(List<PlayerGame> games, String metric) {
  final values = [
    for (final g in games)
      if (g.stats[metric] != null) g.stats[metric]!.toDouble(),
  ];
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a + b) / values.length;
}

PropWindow _window(
  String label,
  List<PlayerGame> games,
  String metric,
  double line,
) => PropWindow(
  label: label,
  over: hitRate(
    label: label,
    games: games,
    metric: metric,
    line: line,
    side: LineSide.over,
  ),
  average: _average(games, metric),
);

/// Builds the prop view from recorded games and saved prices only.
///
/// [opponent] is the upcoming opponent's abbreviation, when the game is known.
/// [quotes] are saved prices for this player's market; other lines and
/// expired or in-game prices should already be filtered out by the caller.
PropDepth propDepth({
  required PlayerStatsDataset data,
  required String playerId,
  required String metric,
  required double line,
  String? opponent,
  List<OddsQuote> quotes = const [],
  DateTime? through,
}) {
  final rows = data.rows;
  final all = propGames(rows, playerId, through: through);
  final latestSeason = all.isEmpty ? null : all.first.season;
  final windows = <PropWindow>[
    _window('Last 5', all.take(5).toList(), metric, line),
    _window('Last 10', all.take(10).toList(), metric, line),
    _window('Last 20', all.take(20).toList(), metric, line),
    if (latestSeason != null)
      _window(
        '$latestSeason season',
        propGames(rows, playerId, season: latestSeason, through: through),
        metric,
        line,
      ),
  ];
  PropWindow? lastSeason;
  if (latestSeason != null) {
    final games = propGames(
      rows,
      playerId,
      season: latestSeason - 1,
      through: through,
    );
    if (games.isNotEmpty) {
      lastSeason = _window('${latestSeason - 1} season', games, metric, line);
    }
  }
  final notes = <String>[];
  PropWindow? vsOpponent;
  DefenseVsPosition? defense;
  if (opponent != null && opponent.isNotEmpty) {
    final games = propGames(
      rows,
      playerId,
      opponent: opponent,
      through: through,
    );
    if (games.isNotEmpty) {
      vsOpponent = _window('vs $opponent', games, metric, line);
    }
    if (all.isNotEmpty && latestSeason != null) {
      defense = defenseVsPosition(
        rows,
        opponent: opponent,
        position: all.first.position,
        metric: metric,
        season: latestSeason,
        through: through,
      );
    }
  }
  final market = _market(quotes, line);
  if (all.isEmpty) {
    notes.add('No recorded regular-season games for this player.');
  }
  if (all.isNotEmpty && all.length < 8) {
    notes.add('Only ${all.length} recorded games, so the rates are thin.');
  }
  return PropDepth(
    playerId: playerId,
    metric: metric,
    line: line,
    windows: windows,
    vsOpponent: vsOpponent,
    lastSeason: lastSeason,
    defense: defense,
    market: market,
    notes: notes,
  );
}

PropMarketView? _market(List<OddsQuote> quotes, double line) {
  final atLine = quotes.where((q) => q.selection.point == line).toList();
  if (atLine.isEmpty) return null;
  OddsQuote? best(String side) {
    final list =
        atLine.where((q) => q.selection.outcome.toLowerCase() == side).toList()
          ..sort((a, b) => b.decimal.compareTo(a.decimal));
    return list.isEmpty ? null : list.first;
  }

  final fair = <double>[];
  final byBook = <String, Map<String, OddsQuote>>{};
  for (final q in atLine) {
    (byBook[q.bookId] ??= {})[q.selection.outcome.toLowerCase()] = q;
  }
  for (final sides in byBook.values) {
    final chance = noVigChance(sides['over']?.decimal, sides['under']?.decimal);
    if (chance != null) fair.add(chance);
  }
  return PropMarketView(
    line: line,
    bestOver: best('over'),
    bestUnder: best('under'),
    fairOver: fair.isEmpty ? null : fair.reduce((a, b) => a + b) / fair.length,
    books: byBook.length,
  );
}

/// Ranks every defense by what one position produced against it in [season].
/// Per team-game, every player at [position] on the other side is summed.
DefenseVsPosition? defenseVsPosition(
  List<PlayerGame> rows, {
  required String opponent,
  required String position,
  required String metric,
  required int season,
  DateTime? through,
}) {
  final totals = <String, Map<String, double>>{};
  for (final g in rows) {
    if (g.season != season ||
        g.seasonType != 'REG' ||
        g.position != position ||
        (through != null && g.date.isAfter(through))) {
      continue;
    }
    final value = g.stats[metric];
    if (value == null) continue;
    final defense = g.opponent.toUpperCase();
    final game = '${g.week}';
    final byGame = totals[defense] ??= {};
    byGame[game] = (byGame[game] ?? 0) + value.toDouble();
  }
  final wanted = opponent.toUpperCase();
  if (!totals.containsKey(wanted)) return null;
  final averages = {
    for (final e in totals.entries)
      if (e.value.isNotEmpty)
        e.key: e.value.values.reduce((a, b) => a + b) / e.value.length,
  };
  final ranked = averages.keys.toList()
    ..sort((a, b) => averages[b]!.compareTo(averages[a]!));
  return DefenseVsPosition(
    opponent: wanted,
    position: position,
    metric: metric,
    allowedPerGame: averages[wanted]!,
    rank: ranked.indexOf(wanted) + 1,
    teams: ranked.length,
    games: totals[wanted]!.length,
  );
}
