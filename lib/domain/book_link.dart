/// Hosts a saved Odds API link may use. The path must come from the
/// response. Coach does not build a bet-slip URL from a team name.
const bookLinkSuffixes = <String, List<String>>{
  'fanduel': ['fanduel.com'],
  'draftkings': ['draftkings.com'],
  'betmgm': ['betmgm.com'],
  'williamhill_us': ['caesars.com', 'williamhill.com'],
  'espnbet': ['espnbet.com', 'thescore.bet'],
  'fanatics': ['fanatics.com'],
  'betrivers': ['betrivers.com'],
  'hardrockbet': ['hardrock.bet', 'hardrocksportsbook.com'],
  'ballybet': ['ballybet.com'],
  'fliff': ['fliff.com'],
};

/// An https link returned for this book, or null when the snapshot has
/// none or the host is not that book's domain.
String? permittedBookLink(String? raw, String bookId) {
  if (raw == null || raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
    return null;
  }
  if (uri.host.isEmpty || uri.query.contains('apiKey')) return null;
  final suffixes = bookLinkSuffixes[bookId];
  if (suffixes == null) return null;
  final host = uri.host.toLowerCase();
  for (final suffix in suffixes) {
    if (host == suffix || host.endsWith('.$suffix')) return uri.toString();
  }
  return null;
}
