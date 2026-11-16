import 'odds.dart';

class GameOutlook {
  GameOutlook._(this.raw, this.event, this.createdAt);
  final Map<String, dynamic> raw;
  final SportEvent event;
  final DateTime createdAt;
  String get summary => raw['summary'] as String;
  String get basis => raw['basis'] as String;
  Map<String, dynamic> get score => Map<String, dynamic>.from(raw['score']);
  List<Map<String, dynamic>> get categories => [
    for (final row in raw['categories']) Map<String, dynamic>.from(row),
  ];
  List<Map<String, dynamic>> get projections => [
    for (final row in raw['projections']) Map<String, dynamic>.from(row),
  ];
  factory GameOutlook.fromJson(Map<String, dynamic> raw) {
    if (raw['schemaVersion'] != 1 ||
        raw['available'] != true ||
        raw['hasEdge'] != false ||
        raw['recommendationsReady'] != false ||
        raw['summary'] is! String ||
        raw['summary'].length > 2000 ||
        raw['event'] is! Map ||
        raw['score'] is! Map ||
        raw['categories'] is! List ||
        raw['categories'].length != 4 ||
        raw['projections'] is! List ||
        raw['projections'].length > 60) {
      throw const FormatException('Invalid game analysis');
    }
    final event = SportEvent.fromJson(Map<String, dynamic>.from(raw['event']));
    final at = DateTime.parse(raw['createdAt'] as String).toUtc();
    bool finite(dynamic value) => value is num && value.isFinite;
    final score = raw['score'] as Map;
    for (final key in [
      'home',
      'away',
      'homeWin',
      'tie',
      'marginMedian',
      'totalMedian',
    ]) {
      if (!finite(score[key])) {
        throw const FormatException('Invalid score forecast');
      }
    }
    if (score['home'] < 0 ||
        score['away'] < 0 ||
        score['homeWin'] < 0 ||
        score['tie'] < 0 ||
        score['homeWin'] + score['tie'] > 1.00001) {
      throw const FormatException('Invalid score probability');
    }
    final names = <String>{};
    for (final category in raw['categories']) {
      if (category is! Map ||
          !{'spreads', 'totals', 'h2h', 'props'}.contains(category['market']) ||
          !names.add(category['market']) ||
          category['rows'] is! List ||
          category['rows'].length > 200) {
        throw const FormatException('Invalid market coverage');
      }
      for (final row in category['rows']) {
        if (row is! Map ||
            row['selection'] is! Map ||
            row['selection']['eventId'] != event.id ||
            row['hasEdge'] != false ||
            row['modelValidated'] != false ||
            !finite(row['decimal']) ||
            row['decimal'] <= 1 ||
            row['decimal'] > 1001) {
          throw const FormatException('Invalid quoted candidate');
        }
        for (final key in ['win', 'push', 'loss']) {
          if (!finite(row[key]) || row[key] < 0 || row[key] > 1) {
            throw const FormatException('Invalid candidate probability');
          }
        }
        if ((row['win'] + row['push'] + row['loss'] - 1).abs() > 0.0001) {
          throw const FormatException('Inconsistent candidate probability');
        }
      }
    }
    return GameOutlook._(raw, event, at);
  }
}
