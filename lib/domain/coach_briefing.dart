import 'coach_books.dart';
import 'line_movement.dart';
import 'game_research.dart';
import 'matchup.dart';
import 'nfl_teams.dart';
import 'odds.dart';
import 'play_units.dart';
import 'player_stats.dart';
import 'price_history.dart';
import 'recent_evidence.dart';
import 'rematch.dart';
import 'trades.dart';
import 'unit_ratings.dart';

/// One answer card: a sentence on top, the table one tap down.
class CoachBrief {
  const CoachBrief({
    required this.title,
    required this.text,
    required this.handlesQuestion,
    this.change,
    this.splits,
    this.ratings = const [],
    this.formNotes = const [],
    this.props,
  });

  final String title, text;
  final bool handlesQuestion;
  final ChangeReport? change;
  final PlayerSplits? splits;
  final List<UnitRating> ratings;
  final List<String> formNotes;
  final PropBoard? props;
}

class PropBoardRow {
  const PropBoardRow({
    required this.label,
    required this.book,
    required this.bookId,
    required this.price,
    required this.implied,
    this.link,
  });

  final String label, book, bookId, price, implied;
  final String? link;
}

class PropBoard {
  const PropBoard({required this.summary, required this.rows, this.empty});
  final String summary;
  final List<PropBoardRow> rows;
  final String? empty;
}

final _rematch = RegExp(
  r"\b(since (they|the|we) (last|first)|rematch|blowout|beat the|playing so well)\b",
  caseSensitive: false,
);
final _whatChanged = RegExp(r"\bwhat changed\b", caseSensitive: false);
final _whySwing = RegExp(
  r"\bwhy (did|are|is|were|was|have)\b",
  caseSensitive: false,
);
final _matchup = RegExp(
  r"\b(against (a )?(good|elite|bad|weak|top|bottom|tough|soft)|pass defense|run defense|good matchup|trending)\b",
  caseSensitive: false,
);
final _props = RegExp(
  r"\b(props?|best overs|overs tonight|player props)\b",
  caseSensitive: false,
);

/// A question this layer should answer itself. Null leaves the normal path.
CoachBrief? interpretQuestion({
  required String question,
  required RecentEvidence? evidence,
  required PlayerStatsDataset? players,
  required RatingBook? ratings,
  List<SnapShare> snaps = const [],
  List<InjuryNote> injuries = const [],
  PlayBook? plays,
  TradeBook? trades,
  OddsBoard? props,
  String? contextHome,
  String? contextAway,
  String? contextPlayer,
  SelfGradeReport? grades,
  LineMoveBook? moves,
}) {
  if (asksForGrade(question)) {
    final market = gradeMarketForQuestion(question);
    final report = grades ?? SelfGradeReport.empty;
    return CoachBrief(
      title: 'Report card',
      text: selfGradeSentence(report, market),
      handlesQuestion: true,
    );
  }
  if (asksAboutSavedMovement(question)) {
    final book = moves ?? LineMoveBook.empty;
    return CoachBrief(
      title: 'Line movement',
      text: book.sentenceFor(
            home: contextHome,
            away: contextAway,
            question: question,
          ) ??
          'Line movement is unavailable. This is a comparison, not a pick.',
      handlesQuestion: true,
    );
  }
  final q = question.toLowerCase();
  final why =
      _whySwing.hasMatch(q) &&
      RegExp(r'\b(beat|blew|blow|changed|well|worse|better|badly)\b')
          .hasMatch(q);
  final namedClubs = _codes(question).length >= 2;
  if (_rematch.hasMatch(q) || why || (_whatChanged.hasMatch(q) && namedClubs)) {
    return _rematchBrief(
      question: question,
      evidence: evidence,
      snaps: snaps,
      injuries: injuries,
      plays: plays,
      trades: trades,
      contextHome: contextHome,
      contextAway: contextAway,
    );
  }
  if (_matchup.hasMatch(q) || RegExp(r'\btrending\b').hasMatch(q)) {
    return _matchupBrief(
      question: question,
      players: players,
      ratings: ratings,
      evidence: evidence,
      contextHome: contextHome,
      contextAway: contextAway,
      contextPlayer: contextPlayer,
    );
  }
  if (RegExp(r'\balternate', caseSensitive: false).hasMatch(q)) {
    return _ladder(props);
  }
  if (_props.hasMatch(q)) {
    return _propBrief(question, props);
  }
  if (RegExp(
    r'\b(team total|game prop|team prop)\b',
    caseSensitive: false,
  ).hasMatch(q)) {
    return _teamProps(props);
  }
  return null;
}

CoachBrief _ladder(OddsBoard? board) {
  final points = <String, Set<double>>{};
  for (final quote in board?.quotes ?? const <OddsQuote>[]) {
    if (quote.selection.market != 'spreads') continue;
    final point = quote.selection.point;
    if (point == null) continue;
    points
        .putIfAbsent(
          '${quote.selection.eventId}|${quote.selection.outcome}',
          () => {},
        )
        .add(point);
  }
  final ladders = [
    for (final entry in points.entries)
      if (entry.value.length > 1) entry,
  ];
  if (ladders.isEmpty) {
    return const CoachBrief(
      title: 'Alternate lines',
      text: 'Alternate lines are unavailable. The free snapshot is the main line.',
      handlesQuestion: true,
    );
  }
  final lines = [
    for (final entry in ladders)
      '${entry.key}: ${entry.value.map((point) => point.toString()).join(', ')}',
  ];
  return CoachBrief(
    title: 'Alternate lines',
    text: lines.join('\n'),
    handlesQuestion: true,
  );
}

CoachBrief _teamProps(OddsBoard? board) {
  final markets = {
    for (final quote in board?.quotes ?? const <OddsQuote>[])
      quote.selection.market,
  };
  const wanted = {'team_totals', 'alternate_team_totals', 'player_anytime_td'};
  if (markets.intersection(wanted).isEmpty) {
    return const CoachBrief(
      title: 'Team and game props',
      text: 'Team and game props are unavailable. The free snapshot does not include those markets.',
      handlesQuestion: true,
    );
  }
  return _propBrief('team props', board);
}

/// Matchup and form context for a game or player the user already has open.
CoachBrief? contextBrief({
  required PlayerStatsDataset? players,
  required RatingBook? ratings,
  required RecentEvidence? evidence,
  String? home,
  String? away,
  String? playerName,
  int? season,
  int? week,
  double? line,
  String? metric,
}) {
  if (ratings == null || season == null || week == null) return null;
  final homeCode = home == null ? null : _code(home);
  final awayCode = away == null ? null : _code(away);
  if (homeCode == null || awayCode == null) return null;
  final snap = ratings.before(season: season, week: week);
  final cards = <UnitRating>[
    ?snap.lookup(homeCode, UnitKey.pass, offense: true),
    ?snap.lookup(awayCode, UnitKey.pass, offense: false),
    ?snap.lookup(awayCode, UnitKey.pass, offense: true),
    ?snap.lookup(homeCode, UnitKey.pass, offense: false),
    ?snap.lookup(homeCode, UnitKey.run, offense: true),
    ?snap.lookup(awayCode, UnitKey.run, offense: false),
    ?snap.lookup(awayCode, UnitKey.run, offense: true),
    ?snap.lookup(homeCode, UnitKey.run, offense: false),
  ];
  if (cards.isEmpty) return null;
  return CoachBrief(
    title: 'Matchup',
    text: _pairSentence(cards),
    handlesQuestion: false,
    ratings: cards,
    formNotes: _formNotes(evidence, homeCode, awayCode, week),
    splits: _splitsForName(
      players: players,
      ratings: ratings,
      name: playerName,
      season: season,
      week: week,
      line: line,
      metric: metric,
    ),
  );
}

/// Splits for a player answer that is not attached to a game.
///
/// The badge is the last opponent's unit, labeled as the last opponent.
/// The elite, average and weak rows are the player's earlier games.
CoachBrief? playerContextBrief({
  required RatingBook? ratings,
  required GameResearchPlayer player,
  required String metric,
  double? line,
}) {
  if (ratings == null || player.games.isEmpty) return null;
  final latest = player.latest;
  final beforeWeek = latest.week + 1;
  final splits = playerSplits(
    book: ratings,
    games: player.games,
    metric: metric,
    line: line,
    beforeSeason: latest.season,
    beforeWeek: beforeWeek,
  );
  if (splits == null) return null;
  final defense = ratings
      .before(season: latest.season, week: beforeWeek)
      .lookup(latest.opponent, splits.unit, offense: false);
  final last = defense == null
      ? ''
      : ' Last opponent ${defense.team}: ${defense.sentence}';
  return CoachBrief(
    title: 'Matchup',
    text: '${_allTiers(splits)}$last',
    handlesQuestion: false,
    ratings: [?defense],
    splits: splits,
  );
}

String _pairSentence(List<UnitRating> cards) {
  if (cards.length < 2) return cards.first.sentence;
  final offense = cards[0];
  final defense = cards[1];
  if (!offense.ranked || !defense.ranked) {
    return '${offense.sentence} ${defense.sentence}';
  }
  return '${offense.team} ${offense.tierLabel.toLowerCase()} pass offense against ${defense.team} ${defense.tierLabel.toLowerCase()} pass defense.';
}

CoachBrief _rematchBrief({
  required String question,
  required RecentEvidence? evidence,
  required List<SnapShare> snaps,
  required List<InjuryNote> injuries,
  PlayBook? plays,
  TradeBook? trades,
  String? contextHome,
  String? contextAway,
}) {
  if (evidence == null) {
    return const CoachBrief(
      title: 'What changed',
      text: 'The recent-game file is unavailable, so the rematch is not described.',
      handlesQuestion: true,
    );
  }
  final codes = _codes(question);
  if (contextHome != null) codes.add(_code(contextHome) ?? contextHome);
  if (contextAway != null) codes.add(_code(contextAway) ?? contextAway);
  if (codes.length < 2) {
    return const CoachBrief(
      title: 'What changed',
      text: 'Name both clubs. I will not guess a second team.',
      handlesQuestion: true,
    );
  }
  final pair = codes.take(2).toList();
  final report = rematchReport(
    evidence: evidence,
    teamA: pair[0],
    teamB: pair[1],
    snaps: snaps,
    earlierInjuries: injuries,
    plays: plays,
    trades: trades,
  );
  if (report == null) {
    return CoachBrief(
      title: 'What changed',
      text: 'Those clubs do not have two completed meetings in the loaded schedule. A later result that is not in the file is not described.',
      handlesQuestion: true,
    );
  }
  return CoachBrief(
    title: 'What changed',
    text: report.summary,
    handlesQuestion: true,
    change: report,
  );
}

CoachBrief _matchupBrief({
  required String question,
  required PlayerStatsDataset? players,
  required RatingBook? ratings,
  required RecentEvidence? evidence,
  String? contextHome,
  String? contextAway,
  String? contextPlayer,
}) {
  if (ratings == null || players == null) {
    return const CoachBrief(
      title: 'Matchup',
      text: 'Player box scores are unavailable, so no opponent tier is shown.',
      handlesQuestion: true,
    );
  }
  final season = evidence?.games.isNotEmpty == true
      ? evidence!.games
            .map((game) => game.season)
            .reduce((a, b) => a > b ? a : b)
      : 2026;
  final week = _nextWeek(evidence) ?? 12;
  final name = _playerName(question, players) ?? contextPlayer;
  final splits = _splitsForName(
    players: players,
    ratings: ratings,
    name: name,
    season: season,
    week: week,
    line: _line(question),
  );
  final codes = _codes(question);
  if (contextHome != null) codes.add(_code(contextHome) ?? '');
  if (contextAway != null) codes.add(_code(contextAway) ?? '');
  codes.removeWhere((code) => code.isEmpty);
  final snap = ratings.before(season: season, week: week);
  final cards = <UnitRating>[
    for (final code in codes.take(2)) ...[
      ?snap.lookup(code, UnitKey.pass, offense: false),
      ?snap.lookup(code, UnitKey.run, offense: false),
      ?snap.lookup(code, UnitKey.sack, offense: false),
    ],
  ];
  final focus = _focusTier(question);
  final focused = splits?.tiers.where((row) => row.tier == focus).toList();
  final sentence = splits == null
      ? (cards.isEmpty
            ? 'No ranked unit is available for that question yet.'
            : cards.first.sentence)
      : _splitSentence(splits, focus, focused);
  return CoachBrief(
    title: 'Matchup',
    text: sentence,
    handlesQuestion: true,
    splits: splits,
    ratings: cards,
    formNotes: [
      for (final code in codes.take(2))
        ..._formNotes(evidence, code, null, week),
    ],
  );
}

String _allTiers(PlayerSplits splits) {
  final parts = [
    for (final row in splits.tiers)
      if (row.games > 0)
        '${row.tier.name} ${row.games} games, ${row.rawAverage?.toStringAsFixed(1) ?? '—'} per game',
  ];
  if (parts.isEmpty) {
    return '${splits.player} has no earlier games against a ranked defense.';
  }
  return '${splits.player}: ${parts.join('; ')}.';
}

String _splitSentence(
  PlayerSplits splits,
  UnitTier focus,
  List<TierSplit>? rows,
) {
  final row = rows == null || rows.isEmpty ? null : rows.first;
  if (row == null || row.games == 0) {
    return '${splits.player} has no recorded games in the ${focus.name} tier before this week. ${splits.summary}';
  }
  final average = row.rawAverage?.toStringAsFixed(1) ?? '—';
  final shrunk = row.shrunkAverage?.toStringAsFixed(1);
  final line = splits.line;
  final against = line == null
      ? ''
      : ' Against ${line.toStringAsFixed(1)}: ${row.overs} of ${row.games} over'
            '${row.pushes > 0 ? ', ${row.pushes} push' : ''}.';
  final shrink = row.smallSample && shrunk != null
      ? ' Small sample. Shrunk average $shrunk, toward the player\'s own games.'
      : '';
  return '${splits.player} vs ${focus.name} defenses: $average per game across ${row.games} games.$against$shrink';
}

CoachBrief _propBrief(String question, OddsBoard? board) {
  if (board == null) {
    return const CoachBrief(
      title: 'Props',
      text: 'Saved prop prices are unavailable.',
      handlesQuestion: true,
      props: PropBoard(summary: 'Saved prop prices are unavailable.', rows: []),
    );
  }
  final books = CoachBooks.parse(question);
  final book = books != null && books.length == 1 ? books.first : null;
  final overs = RegExp(r'\bovers?\b', caseSensitive: false).hasMatch(question);
  final unders = RegExp(
    r'\bunders?\b',
    caseSensitive: false,
  ).hasMatch(question);
  final side = overs
      ? 'over'
      : unders
      ? 'under'
      : null;
  final rows = <PropBoardRow>[];
  for (final quote in board.quotes) {
    final market = quote.selection.market;
    if (!market.startsWith('player_')) continue;
    if (book != null && quote.bookId != book) continue;
    if (side != null && quote.selection.outcome.toLowerCase() != side) continue;
    final point = quote.selection.point;
    final who = quote.selection.participant;
    rows.add(
      PropBoardRow(
        label:
            '$who ${quote.selection.outcome}${point == null ? '' : ' $point'}',
        book: quote.book,
        bookId: quote.bookId,
        price: _american(quote.decimal),
        implied: '${(100 / quote.decimal).toStringAsFixed(1)}%',
        link: quote.link,
      ),
    );
  }
  rows.sort((a, b) => a.label.compareTo(b.label));
  final shown = rows.take(12).toList();
  final where = [
    if (book != null) CoachBooks.labels[book] ?? book,
    if (side != null) '${side}s',
    'NFL',
  ].join(', ');
  final summary = shown.isEmpty
      ? 'No saved $where props in this snapshot. Prices that were not saved stay unavailable.'
      : '${shown.length} saved $where props. Implied probability is the price as a percentage, fee included. This is not a pick.';
  return CoachBrief(
    title: 'Props',
    text: summary,
    handlesQuestion: true,
    props: PropBoard(
      summary: summary,
      rows: shown,
      empty: shown.isEmpty ? summary : null,
    ),
  );
}

String _american(double decimal) {
  if (decimal <= 1) return '—';
  final value = decimal >= 2 ? (decimal - 1) * 100 : -100 / (decimal - 1);
  return '${value >= 0 ? '+' : ''}${value.round()}';
}

PlayerSplits? _splitsForName({
  required PlayerStatsDataset? players,
  required RatingBook? ratings,
  required String? name,
  required int season,
  required int week,
  required double? line,
  String? metric,
}) {
  if (players == null || ratings == null || name == null || name.isEmpty) {
    return null;
  }
  final rows = [
    for (final game in players.rows)
      if (game.name.toLowerCase() == name.toLowerCase()) game,
  ];
  if (rows.isEmpty) return null;
  final chosen =
      metric ??
      (rows.last.position == 'QB'
          ? 'passing_yards'
          : rows.last.position == 'RB'
          ? 'rushing_yards'
          : 'receiving_yards');
  return playerSplits(
    book: ratings,
    games: rows,
    metric: chosen,
    line: line,
    beforeSeason: season,
    beforeWeek: week,
  );
}

List<String> _formNotes(
  RecentEvidence? evidence,
  String team,
  String? other,
  int beforeWeek,
) {
  if (evidence == null) return const ['Recent team form is unavailable.'];
  final games = [
    for (final game in evidence.games)
      if (game.season == 2026 &&
          game.week < beforeWeek &&
          (game.home == team || game.away == team))
        game,
  ]..sort((a, b) => a.week.compareTo(b.week));
  if (games.length < 3) {
    return [
      '$team does not have three earlier 2026 games in the schedule file.',
    ];
  }
  String record(Iterable<RecentGame> slice) {
    var w = 0, l = 0, t = 0;
    for (final game in slice) {
      final own = game.home == team ? game.homeScore : game.awayScore;
      final opp = game.home == team ? game.awayScore : game.homeScore;
      if (own > opp) {
        w++;
      } else if (own < opp) {
        l++;
      } else {
        t++;
      }
    }
    return t == 0 ? '$w-$l' : '$w-$l-$t';
  }

  final last3 = games.sublist(games.length - 3);
  final season = record(games);
  final recent = record(last3);
  final moved = recent != season;
  return [
    '$team is $season on the loaded 2026 games before week $beforeWeek, and $recent in the last three. ${moved ? 'The recent record is not the season record.' : 'The last three match the season record\'s shape only as a count of those games, not a new level.'} ${other == null ? '' : 'Opponent $other.'}',
  ];
}

Set<String> _codes(String question) {
  final q = question.toLowerCase();
  final found = <String>{};
  for (final entry in nflTeams.entries) {
    final nickname = entry.key.split(' ').last.toLowerCase();
    if (q.contains(entry.key.toLowerCase()) ||
        RegExp('\\b${RegExp.escape(nickname)}\\b').hasMatch(q) ||
        RegExp('\\b${entry.value.toLowerCase()}\\b').hasMatch(q)) {
      found.add(entry.value == 'LAR' ? 'LA' : entry.value);
    }
  }
  return found;
}

String? _code(String name) {
  final direct = canonicalTeam(name);
  if (direct != null) return direct == 'LAR' ? 'LA' : direct;
  final found = _codes(name);
  return found.length == 1 ? found.first : null;
}

String? _playerName(String question, PlayerStatsDataset data) {
  final q = question.toLowerCase();
  final hits = <String>{};
  for (final game in data.rows) {
    final name = game.name.toLowerCase();
    if (name.length > 4 && q.contains(name)) hits.add(game.name);
  }
  if (hits.length == 1) return hits.first;
  return null;
}

double? _line(String question) {
  final match = RegExp(r'\b(\d{1,3}(?:\.\d)?)\b').firstMatch(question);
  if (match == null) return null;
  return double.tryParse(match.group(1)!);
}

int? _nextWeek(RecentEvidence? evidence) {
  if (evidence == null || evidence.games.isEmpty) return null;
  var week = 0;
  for (final game in evidence.games) {
    if (game.week > week) week = game.week;
  }
  return week + 1;
}

UnitTier _focusTier(String question) {
  final q = question.toLowerCase();
  if (RegExp(r'\b(bad|weak|bottom|soft|poor)\b').hasMatch(q)) {
    return UnitTier.weak;
  }
  if (RegExp(r'\b(good|elite|top|tough|strong)\b').hasMatch(q)) {
    return UnitTier.elite;
  }
  return UnitTier.elite;
}
