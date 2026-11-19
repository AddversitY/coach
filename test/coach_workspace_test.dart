import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/coach/coach_workspace.dart';
import 'package:odds_edge/data/published_snapshot.dart';
import 'package:odds_edge/domain/assistant.dart';
import 'package:odds_edge/domain/coach_telemetry.dart';
import 'package:odds_edge/domain/coach_books.dart';
import 'package:odds_edge/domain/odds.dart';
import 'package:odds_edge/theme/coach_theme.dart';
import 'package:odds_edge/main.dart' as app;

import 'game_outlook_test.dart' show gameOutlookFixture;
import 'coach_research_summary_test.dart' show researchSummaryFixture;
import 'game_research_test.dart'
    show event, now, fixtureData, dataWith, recorded;

void main() {
  testWidgets('public app entry point opens Coach without the legacy shell', (
    tester,
  ) async {
    await tester.pumpWidget(const app.OddsEdgeApp());
    expect(find.byType(CoachWorkspace), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  final board = OddsBoard(events: [event], quotes: const [], fetchedAt: now);
  PublishedSnapshot snapshot() => PublishedSnapshot(
    board: board,
    props: board,
    generatedAt: now,
    scheduleAt: now,
    oddsMessage: 'No saved prices',
  );
  Widget frame({
    Future<AssistantReply> Function(Map<String, dynamic>)? ask,
    Future<PublishedSnapshot> Function()? loader,
    Future<CoachTelemetry> Function()? telemetryLoader,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>)? gameLoader,
    Future<Map<String, dynamic>> Function()? evaluationLoader,
  }) => MaterialApp(
    theme: coachTheme(),
    home: CoachWorkspace(
      snapshotLoader: loader ?? () async => snapshot(),
      playerLoader: () async => fixtureData(),
      clock: () => now,
      ask: ask,
      telemetryLoader: telemetryLoader,
      gameAnalysisLoader: gameLoader,
      evaluationLoader: evaluationLoader,
    ),
  );
  Future<void> send(WidgetTester tester, String q) async {
    await tester.enterText(find.byKey(const Key('coach-composer')), q);
    await tester.tap(find.byKey(const Key('coach-send')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'whole-game research leads with one summary while exact-selection answers retain their decision',
    (tester) async {
      await tester.pumpWidget(
        frame(
          gameLoader: (payload) async {
            final raw = gameOutlookFixture(event, now),
                comparison = researchSummaryFixture();
            comparison.addAll({
              'basis': 'evidence_completeness',
              'action': 'pass',
              'hasEdge': false,
              'recommendationsReady': false,
            });
            for (final option in comparison['options']) {
              option['selection'] = null;
            }
            comparison['summary']['leadingMarkets'] = [];
            comparison['summary']['primary'] = !(payload['question'] as String)
                .contains('spread');
            raw['comparison'] = comparison;
            return raw;
          },
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Analyze Bills');
      expect(find.text('THE RESEARCH READ'), findsOneWidget);
      expect(find.text('Resolve the lineup questions first'), findsNothing);
      await send(tester, 'Bills spread line -3.5');
      expect(find.text('Resolve the lineup questions first'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'availability expiry retains dated graphs while withdrawing decisions and price comparisons',
    (tester) async {
      await tester.pumpWidget(
        frame(
          gameLoader: (_) async {
            final report = gameOutlookFixture(event, now);
            report['weather'] = [
              {
                'id': 'old-weather',
                'eventId': event.id,
                'kind': 'weather',
                'source': 'Test weather',
                'observedAt': now
                    .subtract(const Duration(minutes: 36))
                    .toIso8601String(),
                'value': {'windMph': 10},
              },
            ];
            report['visualEvidence'] = {
              'focus': 'team',
              'selectedTeam': event.home,
              'cutoff': '2026-11-12',
              'teams': [
                {
                  'name': event.home,
                  'code': 'BUF',
                  'samples': [
                    {
                      'date': '2026-11-08',
                      'label': '11-08',
                      'value': 24,
                      'secondary': 17,
                    },
                  ],
                },
              ],
              'priceComparison': {'offers': []},
            };
            return report;
          },
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Bills spread');
      expect(find.text('Exact-selection prices'), findsOneWidget);
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(find.text('THE MATCHUP / RECENT FORM'), findsOneWidget);
      expect(find.textContaining('Recorded history retained.'), findsOneWidget);
      expect(find.text('Exact-selection prices'), findsNothing);
      expect(find.text('Resolve the lineup questions first'), findsNothing);
      expect(
        find.textContaining('Availability or weather evidence has expired.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'price-shopping questions answer from saved prices without game research or AI',
    (tester) async {
      var gameCalls = 0, aiCalls = 0;
      Selection side(String market, String outcome, double? point) => Selection(
        eventId: event.id,
        market: market,
        outcome: outcome,
        point: point,
        rules: 'game_market_unverified',
      );
      OddsQuote price(String book, Selection s, double decimal) => OddsQuote(
        selection: s,
        bookId: book,
        book: book,
        provider: 'test',
        decimal: decimal,
        sourceAt: now.subtract(const Duration(minutes: 3)),
        collectedAt: now.subtract(const Duration(minutes: 1)),
      );
      final priced = OddsBoard(
        events: [event],
        quotes: [
          price('draftkings', side('h2h', event.home, null), 1.8),
          price('draftkings', side('h2h', event.away, null), 2.05),
          price('fanduel', side('h2h', event.home, null), 1.85),
          price('fanduel', side('h2h', event.away, null), 2.0),
        ],
        fetchedAt: now.subtract(const Duration(minutes: 1)),
      );
      await tester.pumpWidget(
        frame(
          loader: () async => PublishedSnapshot(
            board: board,
            props: priced,
            generatedAt: now,
            scheduleAt: now,
            oddsMessage: 'Saved prices',
          ),
          gameLoader: (_) async {
            gameCalls++;
            return {};
          },
          ask: (_) async {
            aiCalls++;
            return const AssistantReply(
              available: false,
              answer: '',
              cited: [],
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'best price on the moneyline');
      expect(find.text('Best saved prices'), findsOneWidget);
      expect(find.textContaining('1.85'), findsNothing);
      expect(find.textContaining('fanduel'), findsWidgets);
      expect(gameCalls, 0);
      expect(aiCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a parlay request builds one ticket at one book from saved prices',
    (tester) async {
      Selection side(String outcome) => Selection(
        eventId: event.id,
        market: 'h2h',
        outcome: outcome,
        rules: 'game_market_unverified',
      );
      OddsQuote price(String book, String outcome, double decimal) => OddsQuote(
        selection: side(outcome),
        bookId: book,
        book: book,
        provider: 'test',
        decimal: decimal,
        sourceAt: now.subtract(const Duration(minutes: 3)),
        collectedAt: now.subtract(const Duration(minutes: 1)),
      );
      final priced = OddsBoard(
        events: [event],
        quotes: [
          price('draftkings', event.home, 1.8),
          price('draftkings', event.away, 2.05),
          price('fanduel', event.home, 1.8),
          price('fanduel', event.away, 2.25),
        ],
        fetchedAt: now.subtract(const Duration(minutes: 1)),
      );
      await tester.pumpWidget(
        frame(
          loader: () async => PublishedSnapshot(
            board: board,
            props: priced,
            generatedAt: now,
            scheduleAt: now,
            oddsMessage: 'Saved prices',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'build me a 2 leg parlay');
      // One game cannot make a two-game ticket; straight bets still show.
      expect(find.text('Best bets from saved prices'), findsOneWidget);
      expect(find.textContaining('Not enough separate games'), findsOneWidget);
      expect(find.text('Straight bets'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a missing-price player prop still leads with a recorded chart without AI',
    (tester) async {
      await tester.pumpWidget(frame());
      await tester.pumpAndSettle();
      await send(tester, 'Recorded Quarterback passing yards over 245.5');
      expect(find.text('THE PLAYER / RECENT FORM'), findsOneWidget);
      expect(find.text('Requested line'), findsOneWidget);
      expect(find.text('245.5'), findsOneWidget);
      // The prop card shows the record against the requested line by window.
      await tester.scrollUntilVisible(
        find.text('Past results and market prices, not a validated forecast.'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Passing yards over 245.5 · record'), findsOneWidget);
      expect(find.text('Last 5'), findsOneWidget);
      expect(find.text('Last 10'), findsOneWidget);
      expect(
        find.text('Past results and market prices, not a validated forecast.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone has one conversation with contextual follow-ups and no navigation pages',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(frame());
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Research'), findsNothing);
      expect(
        find.textContaining('open-ended AI not connected'),
        findsOneWidget,
      );
      await send(tester, 'Show Recorded Quarterback passing yards');
      expect(
        find.textContaining('Recorded Quarterback · Pass yards'),
        findsOneWidget,
      );
      await send(tester, 'What changed?');
      expect(find.textContaining('Pass attempts averaged'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('coach-new-chat')));
      await tester.pumpAndSettle();
      expect(find.text('Read the game.\nQuestion the line.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'a long response opens at its beginning instead of the last player',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: coachTheme(),
          home: CoachWorkspace(
            snapshotLoader: () async => snapshot(),
            clock: () => now,
            playerLoader: () async => dataWith([
              for (var i = 0; i < 14; i++)
                recorded(id: 'qb-$i', name: 'Quarterback $i'),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Explore Buffalo Bills at Kansas City Chiefs');
      expect(find.text('Quarterback 0').hitTestable(), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Buffalo Bills at Kansas City Chiefs')).dy,
        lessThan(400),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'structured game research saves interpretation calls until explicitly requested',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        frame(
          gameLoader: (payload) async => gameOutlookFixture(event, now),
          ask: (payload) async {
            calls++;
            return const AssistantReply(
              available: true,
              answer: 'The dated evidence has limitations.',
              cited: ['team_evidence'],
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Analyze Bills spread -3.5');
      expect(calls, 0);
      expect(find.text('Explain this research'), findsOneWidget);
      await tester.ensureVisible(find.text('Explain this research'));
      await tester.tap(find.text('Explain this research'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('The dated evidence has limitations.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unsupported scope and unknown subjects never reuse a previous game or spend interpretation calls',
    (tester) async {
      var games = 0, calls = 0;
      await tester.pumpWidget(
        frame(
          gameLoader: (payload) async {
            games++;
            return gameOutlookFixture(event, now);
          },
          ask: (payload) async {
            calls++;
            return AssistantReply.unavailable;
          },
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Analyze Bills spread -3.5');
      expect(games, 1);
      await send(tester, 'Lakers total over 221.5');
      expect(games, 1);
      await send(tester, 'Bills first-half spread -3.5');
      expect(
        find.textContaining('Half and quarter markets aren’t supported'),
        findsOneWidget,
      );
      await send(tester, 'Why?');
      expect(
        find.textContaining('Half and quarter markets aren’t supported'),
        findsNWidgets(2),
      );
      expect(games, 1);
      expect(calls, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a numerical clarification completes the same player selection without an AI planner',
    (tester) async {
      Map<String, dynamic>? request;
      await tester.pumpWidget(
        frame(
          gameLoader: (payload) async {
            request = payload;
            return gameOutlookFixture(event, now);
          },
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Recorded Quarterback passing yards under');
      expect(request, isNull);
      expect(
        find.textContaining('Include the numerical under line'),
        findsOneWidget,
      );
      await send(tester, '245.5');
      expect(request, isNotNull);
      expect(
        request!['question'],
        contains('Recorded Quarterback passing yards under 245.5'),
      );
      expect(request!['question'], contains(' on 2026-'));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'book transitions replace prior scope and the all-books control does not reapply the old question filter',
    (tester) async {
      final scopes = <List<String>?>[];
      final questions = <String>[];
      await tester.pumpWidget(
        frame(
          gameLoader: (payload) async {
            final ids = CoachBooks.normalize(
              (payload['context'] as Map)['bookIds'],
            );
            scopes.add(ids);
            questions.add(payload['question'] as String);
            final raw = gameOutlookFixture(
              event,
              now,
              bookId: ids?.length == 1 ? ids!.single : null,
            );
            raw['bookIds'] = ids;
            raw['books'] = [
              for (final id in ['draftkings', 'fanduel', 'betmgm'])
                {'id': id, 'name': CoachBooks.labels[id]},
            ];
            for (final category in raw['categories'] as List) {
              category['rows'] = (category['rows'] as List)
                  .where((row) => ids == null || ids.contains(row['bookId']))
                  .toList();
              category['totalRows'] = (category['rows'] as List).length;
            }
            return raw;
          },
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Analyze Bills spread -3.5 at BetMGM');
      expect(scopes.last, ['betmgm']);
      await send(tester, 'Compare DraftKings and FanDuel');
      expect(scopes.last, ['draftkings', 'fanduel']);
      await send(tester, 'Show the opposing case');
      expect(scopes.last, ['draftkings', 'fanduel']);
      await send(tester, 'All books');
      expect(scopes.last, isNull);
      await send(tester, 'At FanDuel');
      expect(scopes.last, ['fanduel']);
      await tester.ensureVisible(find.text('Explore the evidence').last);
      await tester.tap(find.text('Explore the evidence').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('All books').last);
      await tester.tap(find.text('All books').last);
      await tester.pumpAndSettle();
      expect(scopes.last, isNull);
      expect(questions.last, contains('spread line -3.5'));
      expect(questions.last, contains('all books'));
      expect(questions.last, isNot(contains('FanDuel')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('AI uses retrieved evidence and fails back truthfully', (
    tester,
  ) async {
    Map<String, dynamic>? request;
    await tester.pumpWidget(
      frame(
        ask: (p) async {
          request = p;
          return AssistantReply.unavailable;
        },
      ),
    );
    await tester.pumpAndSettle();
    await send(tester, 'Recorded Quarterback prices');
    expect(request!['question'], 'Recorded Quarterback prices');
    expect(request!['playerEvidence'], isNotEmpty);
    expect(
      find.textContaining('AI interpretation is unavailable'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('enlarged text, failure and retry remain usable', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    bool fail = true;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
        child: frame(
          loader: () async {
            if (fail) throw StateError('offline');
            return snapshot();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry loading data'), findsOneWidget);
    expect(tester.takeException(), isNull);
    fail = false;
    await tester.ensureVisible(find.text('Retry loading data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry loading data'));
    await tester.pumpAndSettle();
    await send(tester, 'Brief me');
    expect(find.text('Let’s start with a game'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'phone runs explicit stress research and keeps push lines unsupported',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: coachTheme(),
          home: CoachWorkspace(
            snapshotLoader: () async => snapshot(),
            analysisHistoryLoader: () async => [],
            validationLoader: () async => {'hasEdge': false, 'adopted': false},
            clock: () => now,
            playerLoader: () async => dataWith([
              for (var i = 0; i < 7; i++)
                recorded(
                  week: i + 3,
                  date: '2026-11-${(i + 1).toString().padLeft(2, '0')}',
                  stats: {'passing_yards': 220 + i * 10, 'attempts': 30 + i},
                ),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await send(
        tester,
        'Stress test Recorded Quarterback over 245.5 passing yards',
      );
      await tester.pumpAndSettle();
      expect(find.text('Stress-test results'), findsOneWidget);
      expect(
        find.textContaining('9 assumption scenarios tested'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await send(
        tester,
        'Stress test Recorded Quarterback over 245 passing yards',
      );
      expect(find.text('Let’s make the inputs explicit'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'phone brings attributed reporter news to Coach without requiring a game',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Map<String, dynamic>? request;
      final report = CoachTelemetry(
        checkedAt: now,
        observations: [
          TelemetryObservation(
            id: 'headline',
            kind: 'news',
            eventId: 'nfl',
            source: 'ESPN NFL RSS',
            observedAt: now,
            value: {
              'title': 'A dated NFL report',
              'author': 'Test Reporter',
              'publishedAt': now.toIso8601String(),
              'url': 'https://www.espn.com/nfl/story/_/id/123/test',
            },
          ),
        ],
        sources: const [
          {'id': 'beat_writers', 'state': 'attributed_headlines'},
        ],
      );
      await tester.pumpWidget(
        frame(
          telemetryLoader: () async => report,
          ask: (payload) async {
            request = payload;
            return const AssistantReply(
              available: true,
              answer: 'An attributed report is available; participation remains unconfirmed.',
              cited: ['team_evidence'],
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Latest reporter news');
      expect(find.text('From the reporters'), findsOneWidget);
      expect(find.text('A dated NFL report'), findsOneWidget);
      expect(find.textContaining('Test Reporter'), findsOneWidget);
      expect(find.text('Read source'), findsOneWidget);
      expect(request!['question'], 'Latest reporter news');
      expect((request!['context'] as Map)['eventId'], isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'phone analyzes the whole game across markets and retains the selected book',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? requestedBook;
      await tester.pumpWidget(
        frame(
          gameLoader: (payload) async {
            requestedBook = (payload['context'] as Map)['bookId'] as String?;
            final result = gameOutlookFixture(
              event,
              now,
              bookId: requestedBook,
            );
            result['decision']['whatWouldChange'] = [
              {'text': 'Confirm official active players before reassessing.'},
              {'text': 'Better future probability accuracy is still required.'},
            ];
            result['visualEvidence'] = {
              'focus': 'team',
              'selectedTeam': event.home,
              'cutoff': '2026-11-12',
              'teams': [
                {
                  'name': event.home,
                  'code': 'BUF',
                  'samples': [
                    {
                      'date': '2026-11-08',
                      'label': '11-08',
                      'value': 24,
                      'secondary': 17,
                      'opponent': 'Other',
                    },
                  ],
                },
              ],
            };
            result['decision']['decidingFactor'] =
                'The exact price needs a fresh check.';
            result['decision']['judgment'] = {
              'text': 'Experimental outlook: 55% for this exact selection, excluding pushes.',
            };
            result['decision']['priceBoundary'] = {
              'minimumDecimal': 2.0,
              'notice': 'Experimental threshold only.',
              'linePolicy': 'A different line requires a new calculation.',
            };
            result['decision']['followUps'] = [
              {
                'label': 'Compare the total',
                'query': 'Analyze ${event.away} at ${event.home} game total',
              },
            ];
            result['context']['teams'][0]['lineupReview'] = {
              'keyAbsences': [
                {
                  'name': 'Recorded Receiver',
                  'status': 'Out',
                  'source': 'NFL.com official injury report',
                  'checkedAt': now.toIso8601String(),
                  'priorRole': {'metric': 'targets', 'recentMean': 4.0},
                },
              ],
              'uncertain': [],
            };
            result['priceCoverage'] = {
              'markets': [
                {
                  'market': 'spreads',
                  'quotes': 0,
                  'books': [],
                  'newestAt': null,
                },
              ],
              'notice': 'Saved observations only.',
            };
            return result;
          },
          evaluationLoader: () async => {
            'resultCollection': {
              'state': 'awaiting_final',
              'checkedAt': now.toIso8601String(),
            },
            'aiProvider': {
              'blockedUntil': now
                  .add(const Duration(hours: 1))
                  .toIso8601String(),
            },
            'errorAudit': {
              'development': {
                'all_games': {'games': 512, 'scoreMae': 7.635},
                'extreme_final_total': {'games': 139, 'scoreMae': 11.260},
              },
            },
            'footballResearch': {
              'cutoff': '2026-11-12',
              'coverage': {'teamGames': 2448, 'seasons': 5},
              'retrospectiveLater': {
                'moneyline': {
                  'games': 407,
                  'brier': 0.2252,
                  'incumbentBrier': 0.2257,
                  'marketBrier': 0.2133,
                  'logLoss': 0.6415,
                  'incumbentLogLoss': 0.6419,
                },
              },
            },
            'regimeResearch': {
              'retrospectiveLater': {
                'totals': {
                  'games': 409,
                  'brier': 0.268,
                  'incumbentBrier': 0.268,
                  'marketBrier': 0.250,
                },
              },
              'vsExistingShadow': {
                'totals': {'incumbentBrier': 0.260},
              },
            },
            'benchmarkCoverage': {'fair_available': 1, 'fair_unavailable': 1},
            'headToHeadProtocol': {
              'notice': 'Same frozen facts; current configured AI only.',
            },
            'audit': {
              'gradedGames': 0,
              'pendingGames': 1,
              'nextStep': 'Wait for captured games to finish.',
              'markets': [
                {
                  'label': 'Spread',
                  'matchedPricedGames': 0,
                  'historical': {
                    'brierDifference': 0.018,
                    'logLossDifference': 0.039,
                    'games': 402,
                  },
                },
              ],
              'notice': 'No demonstrated edge.',
            },
            'capturedGames': 0,
            'gradedGames': 0,
            'pendingGames': 0,
            'unresolved': 0,
            'markets': [
              {
                'market': 'spreads',
                'headToHead': {
                  'games': 1,
                  'coachBrier': 0.2,
                  'aiBrier': 0.3,
                  'marketBrier': 0.25,
                  'coachLogLoss': 0.5,
                  'aiLogLoss': 0.7,
                  'marketLogLoss': 0.6,
                },
                'games': 1,
                'brier': 0.2,
                'priceComparison': {
                  'games': 1,
                  'brierDifference': {'mean': -0.01},
                  'logLossDifference': {'mean': -0.02},
                  'notice': 'Research only.',
                },
                'calibration': [
                  {
                    'lower': 0.6,
                    'upper': 0.8,
                    'predicted': 0.7,
                    'observed': 1.0,
                    'games': 1,
                  },
                ],
              },
            ],
            'notice': 'No settled forecasts yet.',
            'historical': {
              'evaluationGames': 409,
              'markets': {
                'moneyline': {
                  'games': 407,
                  'incumbentBrier': .238,
                  'brier': .226,
                  'marketBrier': .213,
                },
              },
            },
            'productionResearch': {
              'cutoff': '2026-11-12',
              'validation': {
                'QB_passing_yards': {
                  'recorded': 624,
                  'unresolved': 208,
                  'mae': 61.64,
                  'baselineMae': 64.66,
                  'referenceBrier': .236,
                  'baselineReferenceBrier': .250,
                  'interval80Coverage': .81,
                },
              },
            },
            'workloadResearch': {
              'cutoff': '2026-11-12',
              'validation': {
                'QB_attempts': {
                  'recorded': 625,
                  'unresolved': 208,
                  'mae': 7.28,
                  'incumbentMae': 7.84,
                  'last3Mae': 8.14,
                  'last6Mae': 7.89,
                  'interval80Coverage': .81,
                },
              },
            },
            'models': [
              {
                'role': 'shadow',
                'gradedGames': 0,
                'pendingGames': 1,
                'capturedGames': 1,
                'forwardWindow': {'weeksGraded': 0},
              },
            ],
          },
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Bills');
      expect(find.text('THE MATCHUP / RECENT FORM'), findsOneWidget);
      expect(find.text('Scored / game'), findsOneWidget);
      expect(find.textContaining('Experimental outlook: 55%'), findsOneWidget);
      await tester.ensureVisible(find.text('Price reasoning'));
      await tester.tap(find.text('Price reasoning'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Exact-line threshold · +100'),
        findsOneWidget,
      );
      expect(
        find.text('A different line requires a new calculation.'),
        findsOneWidget,
      );
      expect(find.text('Compare the total'), findsOneWidget);
      expect(find.text('Player workload outlook'), findsNothing);
      await tester.ensureVisible(find.text('What would change this answer?'));
      await tester.tap(find.text('What would change this answer?'));
      await tester.pumpAndSettle();
      expect(
        find.text('Confirm official active players before reassessing.'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Explore the evidence'));
      await tester.tap(find.text('Explore the evidence'));
      await tester.pumpAndSettle();
      for (final label in [
        'Spread',
        'Game total',
        'Moneyline',
        'Player props',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Player workload outlook'), findsOneWidget);
      await tester.ensureVisible(find.text('Price coverage'));
      await tester.tap(find.text('Price coverage'));
      await tester.pumpAndSettle();
      expect(find.text('Spread · No matching saved prices'), findsOneWidget);
      expect(find.text('Resolve the lineup questions first'), findsOneWidget);
      await tester.ensureVisible(find.text('Lineup & workload'));
      await tester.tap(find.text('Lineup & workload'));
      await tester.pumpAndSettle();
      expect(
        find.text('Listed quarterback · Listed Quarterback'),
        findsOneWidget,
      );
      expect(find.textContaining('Recorded team share 20%'), findsOneWidget);
      expect(
        find.textContaining('Officially Out · Recorded Receiver'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Workload trial'));
      await tester.tap(find.text('Workload trial'));
      await tester.pumpAndSettle();
      expect(find.text('Recorded Quarterback · 28.1 attempts'), findsOneWidget);
      await tester.ensureVisible(find.text('Prop forecast trial'));
      await tester.tap(find.text('Prop forecast trial'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Recorded Quarterback · 241.5 QB passing yards'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('DraftKings'));
      await tester.tap(find.text('DraftKings'));
      await tester.pumpAndSettle();
      expect(requestedBook, 'draftkings');
      await send(tester, 'Bills moneyline');
      expect(find.text('Player workload outlook'), findsOneWidget);
      await send(tester, 'Coach performance');
      expect(find.text('Coach’s forecast record'), findsOneWidget);
      expect(find.text('No settled forecasts yet.'), findsOneWidget);
      await tester.ensureVisible(find.text('Forward testing'));
      await tester.tap(find.text('Forward testing'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Game scores are checked every 15 minutes'),
        findsOneWidget,
      );
      expect(find.textContaining('0 weeks with results'), findsOneWidget);
      await tester.ensureVisible(find.text('Coach vs AI vs market'));
      await tester.tap(find.text('Coach vs AI vs market'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Brier error · Coach 0.200 / AI 0.300 / Market 0.250',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Missing AI replies are never counted as Coach wins',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Accuracy audit'));
      await tester.tap(find.text('Accuracy audit'));
      await tester.pumpAndSettle();
      expect(find.text('Wait for captured games to finish.'), findsOneWidget);
      expect(
        find.textContaining('Brier 0.018 / Log loss 0.039'),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.text('Market comparison · 1 matched priced games'),
      );
      await tester.tap(find.text('Market comparison · 1 matched priced games'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Brier -0.010 / Log loss -0.020'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Probability calibration'));
      await tester.tap(find.text('Probability calibration'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Predicted 70% / Observed 100%'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Background challenger: 0 games with results'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Research progress'));
      await tester.ensureVisible(find.text('Pregame football-feature trial'));
      await tester.tap(find.text('Pregame football-feature trial'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2448 sourced team-games'), findsOneWidget);
      expect(
        find.textContaining(
          'Trial 0.2252 / Existing challenger 0.2257 / Market 0.2133',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Research progress'));
      await tester.tap(find.text('Research progress'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Current 0.238 / Candidate 0.226 / Market 0.213'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Workload forecast research'));
      await tester.tap(find.text('Workload forecast research'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Candidate 7.28 / Weighted baseline 7.84'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Yards & receptions research'));
      await tester.tap(find.text('Yards & receptions research'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Candidate 61.64 / Baseline 64.66'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'game conversation restores exact selections without an AI planner and resets on new chat',
    (tester) async {
      final questions = <String>[];
      await tester.pumpWidget(
        frame(
          gameLoader: (payload) async {
            questions.add(payload['question'] as String);
            return gameOutlookFixture(event, now);
          },
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Analyze Bills game total over 45.5');
      await send(tester, 'What about the under?');
      expect(questions.last, contains('game total under 45.5'));
      await send(tester, 'At DraftKings?');
      expect(questions.last, contains('under 45.5'));
      expect(questions.last, contains('DraftKings'));
      await send(tester, 'What about the spread?');
      expect(questions.last, isNot(contains('45.5')));
      await tester.ensureVisible(find.text('Explore the evidence').first);
      await tester.tap(find.text('Explore the evidence').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Refresh game analysis').first);
      await tester.tap(find.text('Refresh game analysis').first);
      await tester.pumpAndSettle();
      expect(questions.last, contains('game total over 45.5'));
      final count = questions.length;
      await send(tester, 'What about Unknown Person?');
      expect(questions.length, count);
      expect(find.text('I need a matching research subject'), findsOneWidget);
      await tester.tap(find.byKey(const Key('coach-new-chat')));
      await tester.pumpAndSettle();
      await send(tester, 'What about the under?');
      expect(find.text('Let’s make that specific'), findsOneWidget);
      expect(questions.length, count);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
