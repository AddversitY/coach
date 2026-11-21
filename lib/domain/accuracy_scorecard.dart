/// Weekly comparison of Coach's chance and the book's no-vig close.
///
/// Numbers come from the scorecard file. A missing week stays unavailable.
/// This is not a pick.
class AccuracyScorecard {
  const AccuracyScorecard({
    required this.season,
    required this.notice,
    required this.weeks,
    required this.seasonToDate,
  });

  final int? season;
  final String notice;
  final List<ScoreWeek> weeks;
  final ScoreWeek seasonToDate;

  static const empty = AccuracyScorecard(
    season: null,
    notice: 'The accuracy scorecard has not loaded.',
    weeks: [],
    seasonToDate: ScoreWeek.unavailable,
  );

  factory AccuracyScorecard.fromJson(Map<String, dynamic> json) {
    final weeks = <ScoreWeek>[];
    final rawWeeks = json['weeks'];
    if (rawWeeks is List) {
      for (final row in rawWeeks) {
        if (row is Map) {
          weeks.add(ScoreWeek.fromJson(Map<String, dynamic>.from(row)));
        }
      }
    }
    final season = json['seasonToDate'];
    return AccuracyScorecard(
      season: json['season'] is num ? (json['season'] as num).toInt() : null,
      notice: json['notice'] as String? ?? '',
      weeks: weeks,
      seasonToDate: season is Map
          ? ScoreWeek.fromJson(Map<String, dynamic>.from(season), seasonTotal: true)
          : ScoreWeek.unavailable,
    );
  }

  ScoreWeek? week(int number) {
    for (final row in weeks) {
      if (row.week == number) return row;
    }
    return null;
  }

  /// Season sentence, or one week when the question names it.
  String answer(String question) {
    final text = question.toLowerCase();
    final named = RegExp(r'week\s+(\d+)').firstMatch(text);
    if (named != null) {
      final row = week(int.parse(named.group(1)!));
      return row?.sentence ??
          'Week ${named.group(1)} is unavailable. No closing prices were saved for that week.';
    }
    if (RegExp(r'\bthis week\b').hasMatch(text) && weeks.isNotEmpty) {
      for (final row in weeks) {
        if (row.status == 'pending') return row.sentence;
      }
      for (final row in weeks.reversed) {
        if (row.scored) return row.sentence;
      }
      return weeks.last.sentence;
    }
    if (seasonToDate.sentence.isEmpty) return ScoreWeek.unavailable.sentence;
    return seasonToDate.sentence;
  }
}

class ScoreWeek {
  const ScoreWeek({
    required this.sentence,
    required this.status,
    this.season,
    this.week,
    this.picks = 0,
    this.coachCloser = 0,
    this.bookCloser = 0,
    this.coachBrier,
    this.bookBrier,
    this.coachLogLoss,
    this.bookLogLoss,
  });

  final String sentence, status;
  final int? season, week;
  final int picks, coachCloser, bookCloser;
  final double? coachBrier, bookBrier, coachLogLoss, bookLogLoss;

  bool get scored => status == 'scored' && coachBrier != null && bookBrier != null;

  static const unavailable = ScoreWeek(
    sentence:
        'This season is unavailable. No finished week has a saved closing price and a final result.',
    status: 'unavailable',
  );

  factory ScoreWeek.fromJson(Map<String, dynamic> json, {bool seasonTotal = false}) {
    return ScoreWeek(
      sentence: json['sentence'] as String? ??
          (seasonTotal
              ? unavailable.sentence
              : 'Week ${json['week']} is unavailable. No closing prices were saved for that week.'),
      status: json['status'] as String? ?? 'unavailable',
      season: (json['season'] as num?)?.toInt(),
      week: (json['week'] as num?)?.toInt(),
      picks: (json['picks'] as num?)?.toInt() ?? 0,
      coachCloser: (json['coachCloser'] as num?)?.toInt() ?? 0,
      bookCloser: (json['bookCloser'] as num?)?.toInt() ?? 0,
      coachBrier: (json['coachBrier'] as num?)?.toDouble(),
      bookBrier: (json['bookBrier'] as num?)?.toDouble(),
      coachLogLoss: (json['coachLogLoss'] as num?)?.toDouble(),
      bookLogLoss: (json['bookLogLoss'] as num?)?.toDouble(),
    );
  }
}

/// Overall accuracy, not a single prop market's old report card.
bool asksForAccuracy(String question) {
  final text = question.toLowerCase();
  if (!RegExp(r'how accurate|accuracy scorecard|\bscorecard\b').hasMatch(text)) {
    return false;
  }
  return RegExp(r'coach|week|season|scorecard|accurate').hasMatch(text);
}
