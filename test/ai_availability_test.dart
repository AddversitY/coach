import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:odds_edge/data/repository.dart';
import 'package:odds_edge/domain/assistant.dart';

void main() {
  test('Coach preserves a validated daily-limit reply from HTTP 429', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'available': false,
          'answer': 'Free allowance exhausted',
          'cited': [],
          'failureReason': 'provider_daily_limit',
        }),
        429,
      ),
    );
    final repo = BackendRepository('https://coach.example', client: client);
    final reply = await repo.coach({'question': 'Explain this'});
    expect(reply.available, false);
    expect(reply.failureReason, 'provider_daily_limit');
    repo.close();
  });
  test(
    'unknown provider diagnostics cannot become a displayed failure category',
    () {
      final reply = AssistantReply.fromJson({
        'available': false,
        'answer': 'Unavailable',
        'cited': [],
        'failureReason': 'private raw error',
      });
      expect(reply.failureReason, isNull);
    },
  );
}
