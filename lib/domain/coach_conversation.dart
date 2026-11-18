import 'odds.dart';
import 'eastern.dart';
import 'nfl_teams.dart';
import 'coach_books.dart';

/// Session-only context for explicit selections. Never persists personal bets.
class CoachConversation {
  SportEvent? event;
  String? playerName, market, side, team, bookId;
  double? point;
  String? _unsupportedNotice;
  String? _pendingQuestion;

  void noteClarification(String message, {bool resetSubject = false}) {
    if (resetSubject) clear();
    _pendingQuestion = message;
  }

  static String? unsupportedScope(String text) {
    if (RegExp(
      r'\bregulation[- ](?:only|time)\b|\b(?:excluding|without|no)\s+(?:overtime|ot)\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'Regulation-only settlement isn’t verified. An unverified full-game quote cannot substitute for that market.';
    }
    if (RegExp(r'\bteam\s*totals?\b', caseSensitive: false).hasMatch(text)) {
      return 'Team totals aren’t supported yet. A full-game total cannot substitute for a team total.';
    }
    if (RegExp(
      r'\b(?:(?:first|second|third|fourth|1st|2nd|3rd|4th)[-\s]*(?:half|quarter)|[12]h|[1-4]q|[1-4]\s*(?:half|quarter)|half[- ]time)\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'Half and quarter markets aren’t supported yet. The available price comparisons cover full games.';
    }
    if (RegExp(
      r'\blive\s+(?:bet|odds|line|spread|total|prop|moneyline)s?\b|\bin[- ]play\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'Live and in-play bets aren’t supported. Coach uses saved pregame prices.';
    }
    return null;
  }

  static bool isTeamPrompt(String text) {
    final q = text
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'[?!.]+$'), '')
        .replaceFirst(
          RegExp(
            r'^(tell me about|show me|show|what about|how about|analyze|explore)\s+',
          ),
          '',
        )
        .replaceFirst(RegExp(r'^the\s+'), '');
    return nflTeams.entries.any(
      (t) => [
        t.key.toLowerCase(),
        t.key.split(' ').last.toLowerCase(),
        t.value.toLowerCase(),
      ].contains(q),
    );
  }

  static String? marketIn(String text) {
    final q = text.toLowerCase();
    if (RegExp(r'\bmoneyline\b|\bml\b|win outright').hasMatch(q)) {
      return 'moneyline';
    }
    if (RegExp(r'spread|cover').hasMatch(q)) return 'spread';
    if (RegExp(r'receptions').hasMatch(q)) return 'receptions';
    if (RegExp(r'\breceiving\b|\brec\.?\s+(yards?|yds?)\b').hasMatch(q)) {
      return 'receiving yards';
    }
    if (RegExp(r'\bpassing\b|\bpass\s+(yards?|yds?)\b').hasMatch(q)) {
      return 'passing yards';
    }
    if (RegExp(r'\brushing\b|\brush\s+(yards?|yds?)\b').hasMatch(q)) {
      return 'rushing yards';
    }
    if (RegExp(r'total|over.?under').hasMatch(q)) return 'game total';
    final hasTeam = nflTeams.entries.any(
      (t) => [t.key, t.key.split(' ').last, t.value].any(
        (alias) => RegExp(
          '\\b${RegExp.escape(alias)}\\b',
          caseSensitive: false,
        ).hasMatch(q),
      ),
    );
    if (hasTeam) {
      if (RegExp(r'\b(over|under)\b').hasMatch(q)) return 'game total';
      final clean = q.replaceAll(RegExp(r'\b20\d{2}-\d{2}-\d{2}\b'), '');
      if (RegExp(r'[+-]\d+(?:\.\d+)?')
          .allMatches(clean)
          .any((m) => double.parse(m[0]!).abs() < 100)) {
        return 'spread';
      }
    }
    return null;
  }

  ({String query, String? clarification, bool game}) resolve(
    String question,
    DateTime now,
  ) {
    final scopeNotice = unsupportedScope(question);
    if (scopeNotice != null) {
      clear();
      _unsupportedNotice = scopeNotice;
      return (query: question, clarification: scopeNotice, game: false);
    }
    final q = question.toLowerCase().trim().replaceAll(RegExp(r'[?!.]+$'), '');
    final follow = RegExp(
      r'^(?:(?:what|how) about |and |then |instead )?(?:the )?(over|under)(?:\s+(-?\d+(?:\.\d+)?))?$',
    ).firstMatch(q);
    final marketOnly = RegExp(
      r'^(?:(?:what|how) about |and |then |compare )?(?:the )?(spread|moneyline|game total|total|receptions|receiving yards|passing yards|rushing yards)$',
    ).hasMatch(q);
    final same = RegExp(
      r'^(why|why that|why this|show the opposing case|show the matchup|what argues against it|what could go wrong|compare the options|compare the markets|which looks strongest|what else|refresh|check again)$',
    ).hasMatch(q);
    final bookOnly = CoachBooks.isPreferenceOnly(q);
    final pending = _pendingQuestion != null;
    if (pending && ['why', 'why that', 'why this'].contains(q)) {
      return (query: question, clarification: _pendingQuestion, game: false);
    }
    final numericReply = pending && RegExp(r'^[+-]?\d+(?:\.\d+)?$').hasMatch(q)
        ? double.tryParse(q)
        : null;
    final canCompleteLine =
        market == 'spread' && team != null ||
        market == 'game total' && side != null ||
        playerName != null &&
            side != null &&
            [
              'receptions',
              'receiving yards',
              'passing yards',
              'rushing yards',
            ].contains(market);
    if (numericReply != null && !canCompleteLine) {
      return (query: question, clarification: _pendingQuestion, game: false);
    }
    final teamReply =
        pending &&
            event != null &&
            ['spread', 'moneyline'].contains(market) &&
            (market != 'spread' || point != null)
        ? [event!.home, event!.away]
              .where(
                (name) => [
                  name.toLowerCase(),
                  name.split(' ').last.toLowerCase(),
                  nflTeams[name]?.toLowerCase(),
                ].contains(q),
              )
              .firstOrNull
        : null;
    if (_unsupportedNotice != null && (same || follow != null || bookOnly)) {
      return (query: question, clarification: _unsupportedNotice, game: false);
    }
    _unsupportedNotice = null;
    _pendingQuestion = null;
    if (follow == null &&
        !marketOnly &&
        !same &&
        !bookOnly &&
        numericReply == null &&
        teamReply == null) {
      return (query: question, clarification: null, game: false);
    }
    if (event == null || !event!.startsAt.isAfter(now)) {
      return (
        query: question,
        clarification: 'Which upcoming game or player should I use?',
        game: false,
      );
    }
    final allMarkets = [
      'compare the options',
      'compare the markets',
      'which looks strongest',
      'what else',
      'show the matchup',
    ].contains(q);
    var nextMarket = allMarkets
        ? null
        : marketOnly
        ? marketIn(q)
        : market;
    final completingMarket =
        pending &&
        market == null &&
        playerName != null &&
        [
          'receptions',
          'receiving yards',
          'passing yards',
          'rushing yards',
        ].contains(nextMarket);
    var nextPoint =
        numericReply ??
        (marketOnly && !completingMarket || allMarkets ? null : point);
    var nextSide = marketOnly && !completingMarket || allMarkets ? null : side;
    if (teamReply != null) team = teamReply;
    if (follow != null) {
      if (nextMarket == null || ['spread', 'moneyline'].contains(nextMarket)) {
        return (
          query: question,
          clarification: 'Do you mean the game total or a player prop? Include the line you want to compare.',
          game: false,
        );
      }
      nextPoint = double.tryParse(follow.group(2) ?? '') ?? point;
      nextSide = follow.group(1);
      if (nextPoint == null) {
        side = nextSide;
        final message =
            'Which $nextMarket line should I compare? I won’t choose a number for you.';
        noteClarification(message);
        return (query: question, clarification: message, game: false);
      }
    }
    final matchup = '${event!.away} at ${event!.home}';
    final subject = allMarkets
        ? team ?? matchup
        : marketOnly &&
              ['spread', 'moneyline', 'game total'].contains(nextMarket)
        ? team ?? matchup
        : playerName ?? team ?? matchup;
    if ([
          'receptions',
          'receiving yards',
          'passing yards',
          'rushing yards',
        ].contains(nextMarket) &&
        playerName == null) {
      return (
        query: question,
        clarification: 'Which player should I use for $nextMarket?',
        game: false,
      );
    }
    final selection = nextMarket == 'spread' && nextPoint != null
        ? 'spread line $nextPoint'
        : '${nextMarket ?? ''} ${nextSide ?? ''} ${nextPoint ?? ''}';
    final extra = bookOnly
        ? question
        : same
        ? question
        : '';
    return (
      query:
          '$subject $selection on ${easternWall(event!.startsAt).toIso8601String().substring(0, 10)} $extra'
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim(),
      clarification: null,
      game: true,
    );
  }

  void remember(SportEvent next, String query, {String? player, String? book}) {
    final scopeNotice = unsupportedScope(query);
    if (scopeNotice != null) {
      clear();
      _unsupportedNotice = scopeNotice;
      return;
    }
    _unsupportedNotice = null;
    _pendingQuestion = null;
    final nextMarket = marketIn(query);
    // Follow-ups are expanded into explicit queries by resolve(). A new report
    // must not keep a prior side/line that its own query did not specify.
    point = null;
    side = null;
    final namedTeams = [next.home, next.away]
        .where(
          (t) =>
              RegExp(
                '\\b${RegExp.escape(t.split(' ').last)}\\b',
                caseSensitive: false,
              ).hasMatch(query) ||
              RegExp(
                '\\b${RegExp.escape(nflTeams[t] ?? 'UNMATCHED')}\\b',
                caseSensitive: false,
              ).hasMatch(query),
        )
        .toList();
    team = namedTeams.length == 1 ? namedTeams.single : null;
    event = next;
    playerName = player;
    market = nextMarket;
    bookId = book;
    final selection = RegExp(
      r'\b(over|under)\b(?:\s+(-?\d+(?:\.\d+)?))?',
      caseSensitive: false,
    ).firstMatch(query);
    if (selection != null) {
      side = selection.group(1)!.toLowerCase();
      point = double.tryParse(selection.group(2) ?? '');
    }
    if (market == 'game total' && point == null) {
      final clean = query.replaceAll(RegExp(r'\b20\d{2}-\d{2}-\d{2}\b'), '');
      final total = RegExp(
        r'\btotal(?:\s+line)?\s+(?:at\s+|of\s+)?(-?\d+(?:\.\d+)?)',
        caseSensitive: false,
      ).firstMatch(clean);
      point = double.tryParse(total?.group(1) ?? '');
    }
    if (market == 'spread') {
      final line = RegExp(
        r'(?:spread|line|cover)\s*(?:at\s*)?([+-]?\d+(?:\.\d+)?)',
        caseSensitive: false,
      ).firstMatch(query);
      if (line != null && double.parse(line.group(1)!).abs() < 100) {
        point = double.tryParse(line.group(1)!);
      } else {
        final signed = RegExp(r'[+-]\d+(?:\.\d+)?')
            .allMatches(
              query.replaceAll(RegExp(r'\b20\d{2}-\d{2}-\d{2}\b'), ''),
            )
            .map((m) => double.parse(m[0]!))
            .where((n) => n.abs() < 100);
        if (signed.isNotEmpty) point = signed.first;
      }
    }
  }

  void clear() {
    _unsupportedNotice = null;
    _pendingQuestion = null;
    event = null;
    playerName = null;
    market = null;
    side = null;
    point = null;
    team = null;
    bookId = null;
  }
}
