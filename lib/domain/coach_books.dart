/// Price-filter preferences only; no sportsbook account or personal bets.
class CoachBooks {
  static const labels = <String, String>{
    'draftkings': 'DraftKings',
    'fanduel': 'FanDuel',
    'betmgm': 'BetMGM',
    'williamhill_us': 'Caesars',
    'espnbet': 'ESPN BET',
    'fanatics': 'Fanatics',
    'betrivers': 'BetRivers',
    'hardrockbet': 'Hard Rock Bet',
    'ballybet': 'Bally Bet',
    'fliff': 'Fliff',
  };
  static String _normalize(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  static bool _all(String text) => RegExp(
    r'\b(?:all|every|any)\s+(?:sportsbooks?|books?|prices)\b|\bacross books\b|\bcompare books\b',
    caseSensitive: false,
  ).hasMatch(text);
  static List<String>? normalize(Object? value) {
    if (value == null) return null;
    if (value is! List ||
        value.isEmpty ||
        value.length > labels.length ||
        value.any((id) => id is! String || !labels.containsKey(id)) ||
        value.toSet().length != value.length) {
      throw const FormatException('Invalid book preference.');
    }
    return List<String>.from(value)..sort();
  }

  static List<String>? parse(String text, {List<String>? previous}) {
    if (_all(text)) return null;
    final q = ' ${_normalize(text)} ';
    final matched = [
      for (final book in labels.entries)
        if (q.contains(' ${_normalize(book.value)} ')) book.key,
    ];
    return matched.isEmpty ? normalize(previous) : normalize(matched);
  }

  static bool isPreferenceOnly(String text) {
    var q = _normalize(text);
    final hasBooks =
        _all(text) ||
        labels.values.any((name) => ' $q '.contains(' ${_normalize(name)} '));
    if (!hasBooks) return false;
    for (final name in labels.values) {
      q = q.replaceAll(_normalize(name), '');
    }
    const words = {
      'what',
      'how',
      'about',
      'and',
      'or',
      'at',
      'on',
      'from',
      'compare',
      'versus',
      'vs',
      'across',
      'all',
      'every',
      'any',
      'the',
      'only',
      'books',
      'book',
      'sportsbook',
      'sportsbooks',
      'prices',
      'please',
    };
    return q
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .every(words.contains);
  }
}
