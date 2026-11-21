/// Saved sportsbook prices and the last price before kickoff.
///
/// A number that was not in the file is unavailable. The report describes
/// graded cards. It does not claim a betting edge.
class PriceObservation {
  const PriceObservation({
    required this.at,
    required this.source,
    required this.book,
    required this.eventId,
    required this.market,
    required this.outcome,
    required this.player,
    required this.decimal,
    this.kickoff,
    this.season,
    this.week,
    this.away,
    this.home,
    this.line,
  });

  final String at, source, book, eventId, market, outcome, player;
  final double decimal;
  final String? kickoff, away, home;
  final int? season, week;
  final double? line;

  bool get beforeKickoff {
    final start = kickoff;
    if (start == null || start.isEmpty) return false;
    return at.compareTo(start) < 0;
  }
}

class PriceSourceStatus {
  const PriceSourceStatus({
    required this.source,
    required this.status,
    required this.detail,
  });

  final String source, status, detail;
  bool get unavailable => status != 'ok';
}

class GradeMarket {
  const GradeMarket({
    required this.market,
    required this.label,
    required this.savedPrices,
    required this.cards,
    required this.graded,
    required this.hits,
    required this.pushes,
    required this.chanceSum,
    required this.clvSum,
    required this.clvCount,
  });

  final String market, label;
  final int savedPrices, cards, graded, hits, pushes, clvCount;
  final double? chanceSum, clvSum;

  double? get meanChance =>
      graded == 0 || chanceSum == null ? null : chanceSum! / graded;

  double? get meanClv =>
      clvCount == 0 || clvSum == null ? null : clvSum! / clvCount;
}

class SelfGradeReport {
  const SelfGradeReport({
    required this.propCloses,
    required this.realCloseGate,
    required this.sources,
    required this.markets,
    required this.notice,
  });

  final int propCloses, realCloseGate;
  final List<PriceSourceStatus> sources;
  final Map<String, GradeMarket> markets;
  final String notice;

  static const empty = SelfGradeReport(
    propCloses: 0,
    realCloseGate: savedCloseGate,
    sources: [],
    markets: {},
    notice:
        'The grade file has not loaded. The report is unavailable.',
  );

  factory SelfGradeReport.fromJson(Map<String, dynamic> json) {
    final markets = <String, GradeMarket>{};
    final rawMarkets = json['markets'];
    if (rawMarkets is Map) {
      for (final entry in rawMarkets.entries) {
        final row = entry.value;
        if (row is! Map) continue;
        markets[entry.key.toString()] = GradeMarket(
          market: row['market'] as String? ?? entry.key.toString(),
          label: row['label'] as String? ?? entry.key.toString(),
          savedPrices: _int(row['savedPrices']),
          cards: _int(row['cards']),
          graded: _int(row['graded']),
          hits: _int(row['hits']),
          pushes: _int(row['pushes']),
          clvCount: _int(row['clvCount']),
          chanceSum: (row['chanceSum'] as num?)?.toDouble(),
          clvSum: (row['clvSum'] as num?)?.toDouble(),
        );
      }
    }
    final sources = <PriceSourceStatus>[];
    final rawSources = json['sources'];
    if (rawSources is List) {
      for (final row in rawSources) {
        if (row is! Map) continue;
        sources.add(
          PriceSourceStatus(
            source: row['source'] as String? ?? '',
            status: row['status'] as String? ?? 'unavailable',
            detail: row['detail'] as String? ?? '',
          ),
        );
      }
    }
    return SelfGradeReport(
      propCloses: _int(json['propCloses']),
      realCloseGate: json['realCloseGate'] == null
          ? savedCloseGate
          : _int(json['realCloseGate']),
      sources: sources,
      markets: markets,
      notice: json['notice'] as String? ?? '',
    );
  }
}

class PriceHistory {
  const PriceHistory({required this.observations, required this.closes});

  final List<PriceObservation> observations, closes;

  factory PriceHistory.fromJson(Map<String, dynamic> json) {
    List<PriceObservation> read(String key) {
      final rows = json[key];
      if (rows is! List) return const [];
      return [
        for (final row in rows)
          if (row is Map) _observation(Map<String, dynamic>.from(row)),
      ].whereType<PriceObservation>().toList();
    }

    return PriceHistory(observations: read('observations'), closes: read('closes'));
  }

  int closesFor(String market) =>
      closes.where((row) => row.market == market).length;

  /// Median line of the saved closes for one player, club and week.
  /// Books that disagree contribute their own line. No close is null.
  double? closeLine({
    required String market,
    required int season,
    required int week,
    required String team,
    required String player,
  }) {
    final club = team.toUpperCase();
    final name = player.toLowerCase();
    final lines = <double>[
      for (final row in closes)
        if (row.market == market &&
            row.season == season &&
            row.week == week &&
            row.line != null &&
            (row.home == club || row.away == club) &&
            row.player.toLowerCase().contains(name) &&
            name.isNotEmpty)
          row.line!,
    ];
    if (lines.isEmpty) return null;
    lines.sort();
    return lines[lines.length ~/ 2];
  }
}

PriceObservation? _observation(Map<String, dynamic> json) {
  final decimal = (json['decimal'] as num?)?.toDouble();
  final at = json['at'] as String?;
  final market = json['market'] as String?;
  final book = json['book'] as String?;
  final eventId = json['eventId'] as String?;
  final outcome = json['outcome'] as String?;
  if (decimal == null ||
      decimal <= 1 ||
      at == null ||
      market == null ||
      book == null ||
      eventId == null ||
      outcome == null) {
    return null;
  }
  return PriceObservation(
    at: at,
    source: json['source'] as String? ?? 'saved',
    book: book,
    eventId: eventId,
    market: market,
    outcome: outcome,
    player: json['player'] as String? ?? '',
    decimal: decimal,
    kickoff: json['kickoff'] as String?,
    season: (json['season'] as num?)?.toInt(),
    week: (json['week'] as num?)?.toInt(),
    away: json['away'] as String?,
    home: json['home'] as String?,
    line: (json['line'] as num?)?.toDouble(),
  );
}

int _int(Object? value) => value is num ? value.toInt() : 0;

/// How many real closing prop prices a market needs before they replace
/// last season's median in the walk-forward. Set before any of those
/// closes existed.
const savedCloseGate = 1000;

/// Odds API market keys for the four prop stats the walk-forward scores.
const propCloseMarkets = <String, String>{
  'passing_yards': 'player_pass_yds',
  'rushing_yards': 'player_rush_yds',
  'receiving_yards': 'player_reception_yds',
  'receptions': 'player_receptions',
};

/// The test line. [median] is last season's median. [close] is used only
/// when that market already has [realCloseGate] saved closing prices.
double walkForwardTestLine({
  required double median,
  required double? close,
  required int closesForMarket,
}) {
  if (close != null && close.isFinite && closesForMarket >= savedCloseGate) {
    return close;
  }
  return median;
}

/// Plain-English report for one market. A market with no graded card says
/// the report is unavailable.
String selfGradeSentence(SelfGradeReport report, String market) {
  final row = report.markets[market];
  final label = row?.label ?? _fallbackLabel(market);
  if (row == null || row.graded == 0) {
    final saved = row?.savedPrices ?? 0;
    final sources = _sourceSentence(report);
    return 'Coach has not graded any $label yet. Saved prices for that market: $saved. '
        'A grade needs a card that stored Coach\'s chance and side before kickoff, then the final result and a later closing price. '
        'Until those exist, this report is unavailable. $sources'
        'This is a record of the cards, not a pick and not a betting edge.';
  }
  final decided = row.graded - row.pushes;
  final hits = row.hits;
  final chance = row.meanChance;
  final clv = row.meanClv;
  final chanceText = chance == null
      ? 'The average chance on those cards is unavailable.'
      : 'The chance on the card averaged ${(chance * 100).toStringAsFixed(1)} percent.';
  final resultText = decided == 0
      ? 'Every graded card pushed.'
      : 'The side on the card happened $hits of $decided times, with ${row.pushes} pushes.';
  final clvText = clv == null
      ? 'Closing-line value is unavailable because a later price was not saved.'
      : clv >= 0
      ? 'Against the closing price, the card\'s price was ${(clv * 100).toStringAsFixed(1)} cents better on average.'
      : 'Against the closing price, the card\'s price was ${(clv.abs() * 100).toStringAsFixed(1)} cents shorter on average.';
  return 'Coach has graded ${row.graded} $label. $chanceText $resultText $clvText '
      'That is the record of those cards. It is not a pick and it does not claim a betting edge.';
}

String gradeMarketForQuestion(String question) {
  final text = question.toLowerCase();
  if (text.contains('receiving') && text.contains('yard')) {
    return 'player_reception_yds';
  }
  if (text.contains('reception')) return 'player_receptions';
  if (text.contains('rush')) return 'player_rush_yds';
  if (text.contains('pass')) return 'player_pass_yds';
  if (text.contains('total')) return 'totals';
  if (text.contains('spread')) return 'spreads';
  if (text.contains('moneyline') || text.contains('money line')) return 'h2h';
  return 'player_reception_yds';
}

bool asksForGrade(String question) {
  final grade = RegExp(
    r'how good|report card|closing[- ]line value|\bclv\b',
    caseSensitive: false,
  ).hasMatch(question);
  if (!grade) return false;
  return RegExp(
    r'coach|prop|receiving|reception|rush|pass|spread|total|moneyline|report card|\bclv\b',
    caseSensitive: false,
  ).hasMatch(question);
}

String _fallbackLabel(String market) => switch (market) {
  'player_reception_yds' => 'receiving yards props',
  'player_receptions' => 'reception props',
  'player_rush_yds' => 'rushing yards props',
  'player_pass_yds' => 'passing yards props',
  'spreads' => 'spreads',
  'totals' => 'totals',
  'h2h' => 'moneylines',
  _ => market,
};

class BookPriceBook {
  const BookPriceBook({
    required this.book,
    required this.status,
    required this.prices,
    required this.closes,
    this.detail = '',
  });

  final String book, status, detail;
  final int prices, closes;
  bool get unavailable => status != 'ok';
}

class SavedBookPrice {
  const SavedBookPrice({
    required this.book,
    required this.market,
    required this.outcome,
    required this.player,
    required this.decimal,
    this.line,
    this.playerId,
  });

  final String book, market, outcome, player;
  final double decimal;
  final double? line;
  final String? playerId;
}

class BookPriceCoverage {
  const BookPriceCoverage({
    required this.books,
    required this.consensusAdopted,
    required this.consensusReason,
    required this.notice,
    this.prices = const [],
  });

  final List<BookPriceBook> books;
  final bool consensusAdopted;
  final String consensusReason, notice;
  final List<SavedBookPrice> prices;

  static const empty = BookPriceCoverage(
    books: [],
    consensusAdopted: false,
    consensusReason: 'Two-sided closes are unavailable.',
    notice: 'Logged-out prop prices are unavailable. This is a comparison, not a pick.',
  );

  factory BookPriceCoverage.fromJson(Map<String, dynamic> json) {
    final books = <BookPriceBook>[];
    final rawBooks = json['books'];
    if (rawBooks is List) {
      for (final row in rawBooks) {
        if (row is! Map) continue;
        books.add(
          BookPriceBook(
            book: row['book'] as String? ?? '',
            status: row['status'] as String? ?? 'unavailable',
            prices: _int(row['prices']),
            closes: _int(row['closes']),
            detail: row['detail'] as String? ?? '',
          ),
        );
      }
    }
    final prices = <SavedBookPrice>[];
    final rawPrices = json['observations'];
    if (rawPrices is List) {
      for (final row in rawPrices) {
        if (row is! Map) continue;
        final decimal = (row['decimal'] as num?)?.toDouble();
        if (decimal == null || decimal <= 1) continue;
        prices.add(
          SavedBookPrice(
            book: row['book'] as String? ?? '',
            market: row['market'] as String? ?? '',
            outcome: row['outcome'] as String? ?? '',
            player: row['player'] as String? ?? '',
            decimal: decimal,
            line: (row['line'] as num?)?.toDouble(),
            playerId: row['playerId'] as String?,
          ),
        );
      }
    }
    return BookPriceCoverage(
      books: books,
      consensusAdopted: json['consensusAdopted'] == true,
      consensusReason: json['consensusReason'] as String? ?? 'unavailable',
      notice: json['notice'] as String? ?? BookPriceCoverage.empty.notice,
      prices: prices,
    );
  }
}

bool asksForBookPrices(String question) {
  final text = question.toLowerCase();
  final book = RegExp(
    r'betrivers|fanduel|bovada|draftkings|betmgm|caesars|espn bet|fanatics|hard rock|pinnacle|per[- ]book',
  ).hasMatch(text);
  final prop = RegExp(
    r'prop|passing|rushing|receiving|reception|touchdown',
  ).hasMatch(text);
  final price = RegExp(r'price|odds|\bline\b|close').hasMatch(text);
  return book && prop && price;
}

/// Counts from the public file, and a saved price only when one was stored.
/// A missing number stays unavailable.
String bookPriceSentence(
  BookPriceCoverage coverage, {
  String question = '',
  String? player,
}) {
  if (coverage.books.isEmpty && coverage.prices.isEmpty) {
    return coverage.notice;
  }
  final saved = coverage.books.where((book) => !book.unavailable && book.prices > 0);
  final blocked = coverage.books.where((book) => book.unavailable);
  final counts = saved.isEmpty
      ? 'No logged-out book has a saved prop price.'
      : saved
          .map((book) => '${book.book} ${book.prices} prices, ${book.closes} closes')
          .join('; ');
  final missing = blocked.isEmpty
      ? ''
      : ' Unavailable: ${blocked.map((book) => book.book).join(', ')}.';
  final shown = _matchingPrices(coverage, question, player);
  final priceText = shown ?? 'The price on this page is unavailable.';
  final consensus = coverage.consensusAdopted
      ? 'The no-vig consensus is on the card.'
      : 'The no-vig consensus is not on the card. ${coverage.consensusReason}';
  return '$counts.$missing $priceText $consensus ${coverage.notice}';
}

String? _matchingPrices(BookPriceCoverage coverage, String question, String? player) {
  if (coverage.prices.isEmpty) return null;
  final wanted = (player ?? '').toLowerCase();
  final market = _questionMarket(question);
  final rows = [
    for (final row in coverage.prices)
      if ((wanted.isEmpty || row.player.toLowerCase().contains(wanted)) &&
          (market == null || row.market == market))
        row,
  ];
  if (rows.isEmpty) return null;
  final shown = rows.take(6).map((row) {
    final line = row.line == null ? 'unavailable line' : row.line.toString();
    return '${row.book} ${row.player} ${row.outcome} $line at ${row.decimal}';
  });
  final extra = rows.length > 6 ? ' ${rows.length - 6} more saved prices are not listed here.' : '';
  return '${shown.join('; ')}.$extra';
}

String? _questionMarket(String question) {
  final text = question.toLowerCase();
  if (text.contains('reception') && !text.contains('yard')) return 'player_receptions';
  if (text.contains('receiving')) return 'player_reception_yds';
  if (text.contains('rush')) return 'player_rush_yds';
  if (text.contains('attempt')) return 'player_pass_attempts';
  if (text.contains('completion')) return 'player_pass_completions';
  if (text.contains('touchdown') || text.contains(' td')) return 'player_pass_tds';
  if (text.contains('pass')) return 'player_pass_yds';
  return null;
}

String _sourceSentence(SelfGradeReport report) {
  if (report.sources.isEmpty) return '';
  final blocked = [
    for (final source in report.sources)
      if (source.unavailable) source.source,
  ];
  if (blocked.isEmpty) return '';
  return 'Checked and unavailable: ${blocked.join(', ')}. ';
}
