import 'odds.dart';
import 'eastern.dart';
import 'nfl_teams.dart';

/// Session-only context for explicit selections. Never persists personal bets.
class CoachConversation {
  SportEvent? event;
  String? playerName, market, side, team, bookId;
  double? point;
  static String? marketIn(String text) {
    final q = text.toLowerCase();
    if (RegExp(r'moneyline|win outright').hasMatch(q)) return 'moneyline';
    if (RegExp(r'spread|cover').hasMatch(q)) return 'spread';
    if (RegExp(r'receptions').hasMatch(q)) return 'receptions';
    if (RegExp(r'receiving|rec\. yards').hasMatch(q)) return 'receiving yards';
    if (RegExp(r'passing|pass yards').hasMatch(q)) return 'passing yards';
    if (RegExp(r'rushing|rush yards').hasMatch(q)) return 'rushing yards';
    if (RegExp(r'total|over.?under').hasMatch(q)) return 'game total';
    return null;
  }

  ({String query, String? clarification, bool game}) resolve(
    String question,
    DateTime now,
  ) {
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
    final bookOnly = RegExp(
      r'^(?:(?:what|how) about |and |at |on )?(draftkings|fanduel|betmgm|caesars|espn bet|fanatics|betrivers|hard rock bet|bally bet|fliff)$',
    ).hasMatch(q);
    if (follow == null && !marketOnly && !same && !bookOnly) {
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
    var nextPoint = marketOnly || allMarkets ? null : point;
    var nextSide = marketOnly || allMarkets ? null : side;
    if (follow != null) {
      if (nextMarket == null || ['spread', 'moneyline'].contains(nextMarket)) {
        return (
          query: question,
          clarification: 'Do you mean the game total or a player prop? Include the line you want to compare.',
          game: false,
        );
      }
      nextPoint = double.tryParse(follow.group(2) ?? '') ?? point;
      if (nextPoint == null) {
        return (
          query: question,
          clarification:
              'Which $nextMarket line should I compare? I won’t choose a number for you.',
          game: false,
        );
      }
      nextSide = follow.group(1);
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
    final nextMarket = marketIn(query);
    final changed =
        nextMarket == null ||
        event?.id != next.id ||
        player != playerName ||
        nextMarket != market;
    if (changed) {
      point = null;
      side = null;
    }
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
    market = nextMarket ?? (changed ? null : market);
    bookId = book;
    final selection = RegExp(
      r'\b(over|under)\s+(-?\d+(?:\.\d+)?)',
      caseSensitive: false,
    ).firstMatch(query);
    if (selection != null) {
      side = selection.group(1)!.toLowerCase();
      point = double.tryParse(selection.group(2)!);
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
            .allMatches(query)
            .map((m) => double.parse(m[0]!))
            .where((n) => n.abs() < 100);
        if (signed.isNotEmpty) point = signed.first;
      }
    }
  }

  void clear() {
    event = null;
    playerName = null;
    market = null;
    side = null;
    point = null;
    team = null;
    bookId = null;
  }
}
