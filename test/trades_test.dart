import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/domain/trades.dart';

void main() {
  test('a trade is quoted only inside the file date and the two clubs', () {
    final book = TradeBook.fromJson(
      jsonDecode(File('assets/nfl-trades.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    final found = book.between(
      name: 'Dontayvion Wicks',
      from: 'GB',
      to: 'PHI',
      after: DateTime.utc(2026, 4, 1),
      before: DateTime.utc(2026, 4, 30),
    );
    expect(found, isNotNull);
    expect(found!.dateLabel, '2026-04-10');
    expect(found.sentence, contains('Source: nflverse trades'));
    expect(found.sentence, isNot(contains('traded away')));
    expect(
      book.between(
        name: 'Dontayvion Wicks',
        from: 'GB',
        to: 'PHI',
        after: DateTime.utc(2026, 5, 1),
        before: DateTime.utc(2026, 6, 1),
      ),
      isNull,
    );
    expect(
      book.between(
        name: 'Dontayvion Wicks',
        from: 'GB',
        to: 'DET',
        after: DateTime.utc(2026, 4, 1),
        before: DateTime.utc(2026, 4, 30),
      ),
      isNull,
    );
  });
}
