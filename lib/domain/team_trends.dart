import 'history.dart';

/// A record against a closing line, with its sample size kept in view.
class TeamTrend {
  const TeamTrend({
    required this.team,
    required this.label,
    required this.wins,
    required this.losses,
    required this.pushes,
    required this.winWord,
    required this.lossWord,
  });
  final String team, label, winWord, lossWord;
  final int wins, losses, pushes;

  int get decided => wins + losses;
  double? get rate => decided == 0 ? null : wins / decided;
  bool get smallSample => decided < 8;

  /// Strong enough to mention: at least 70% or at most 30% of decided games.
  bool get notable =>
      !smallSample && rate != null && (rate! >= .7 || rate! <= .3);

  String get record => '$wins-$losses${pushes > 0 ? '-$pushes' : ''}';

  String get sentence {
    final tag = smallSample
        ? 'small sample'
        : notable
        ? 'notable, but past covers predict little'
        : 'no clear lean';
    return '$team $record $winWord/$lossWord $label ($tag).';
  }
}

/// Spread and total records for both teams of an upcoming game, built from
/// completed regular-season games that carry an nflverse closing line.
class MatchupTrends {
  const MatchupTrends({required this.trends, required this.games});
  final List<TeamTrend> trends;

  /// Completed games with a closing line that the trends were drawn from.
  final int games;

  List<TeamTrend> get notable => [
    for (final t in trends)
      if (t.notable) t,
  ];
}

class _Result {
  _Result(this.game, this.team);
  final HistoricalGame game;
  final String team;
  bool get home => game.home == team;
  String get opponent => home ? game.away : game.home;
  int get margin =>
      home ? game.homeScore - game.awayScore : game.awayScore - game.homeScore;

  /// The team's own spread: negative when favored.
  double? get spread => game.spreadLine == null
      ? null
      : home
      ? -game.spreadLine!
      : game.spreadLine!;
  bool get favored => (spread ?? 0) < 0;

  /// 1 cover, 0 push, -1 no cover. Null without a line.
  int? get cover {
    final s = spread;
    if (s == null) return null;
    final value = margin + s;
    return value > 0
        ? 1
        : value < 0
        ? -1
        : 0;
  }

  /// 1 over, 0 push, -1 under. Null without a total.
  int? get overTotal {
    final line = game.totalLine;
    if (line == null) return null;
    final total = game.homeScore + game.awayScore;
    return total > line
        ? 1
        : total < line
        ? -1
        : 0;
  }
}

TeamTrend _count(
  String team,
  String label,
  Iterable<int?> outcomes,
  String winWord,
  String lossWord,
) {
  var w = 0, l = 0, p = 0;
  for (final o in outcomes) {
    if (o == null) continue;
    if (o > 0) {
      w++;
    } else if (o < 0) {
      l++;
    } else {
      p++;
    }
  }
  return TeamTrend(
    team: team,
    label: label,
    wins: w,
    losses: l,
    pushes: p,
    winWord: winWord,
    lossWord: lossWord,
  );
}

/// [home] and [away] are team abbreviations. [before] keeps the trends
/// point-in-time: only games played before it count. [homeSpread] is the
/// current home spread (negative when the home team is favored), when known.
MatchupTrends matchupTrends(
  List<HistoricalGame> history, {
  required String home,
  required String away,
  required DateTime before,
  double? homeSpread,
}) {
  final played = [
    for (final g in history)
      if (g.date.isBefore(before) && g.spreadLine != null) g,
  ]..sort((a, b) => b.date.compareTo(a.date));
  List<_Result> of(String team) => [
    for (final g in played)
      if (g.home == team || g.away == team) _Result(g, team),
  ];
  final trends = <TeamTrend>[];
  for (final team in [away, home]) {
    final games = of(team);
    final isHome = team == home;
    trends.add(
      _count(
        team,
        'against the spread, last 10',
        games.take(10).map((r) => r.cover),
        'cover',
        'no cover',
      ),
    );
    trends.add(
      _count(
        team,
        'against the spread ${isHome ? 'at home' : 'on the road'}, last 8',
        games.where((r) => r.home == isHome).take(8).map((r) => r.cover),
        'cover',
        'no cover',
      ),
    );
    if (homeSpread != null) {
      final favored = isHome ? homeSpread < 0 : homeSpread > 0;
      trends.add(
        _count(
          team,
          'against the spread as ${favored ? 'a favorite' : 'an underdog'}, last 10',
          games
              .where((r) => r.favored == favored && r.spread != 0)
              .take(10)
              .map((r) => r.cover),
          'cover',
          'no cover',
        ),
      );
    }
    trends.add(
      _count(
        team,
        'on the total, last 10',
        games.take(10).map((r) => r.overTotal),
        'over',
        'under',
      ),
    );
  }
  trends.add(
    _count(
      away,
      'against the spread vs $home, last 5 meetings',
      of(away).where((r) => r.opponent == home).take(5).map((r) => r.cover),
      'cover',
      'no cover',
    ),
  );
  return MatchupTrends(trends: trends, games: played.length);
}
