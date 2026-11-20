import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odds_edge/coach/briefing_view.dart';
import 'package:odds_edge/coach/stake_calculator.dart';
import 'package:odds_edge/domain/coach_briefing.dart';
import 'package:odds_edge/domain/matchup.dart';
import 'package:odds_edge/domain/recent_evidence.dart';
import 'package:odds_edge/theme/coach_theme.dart';

Future<void> _loadType() async {
  final inter = FontLoader('Inter')
    ..addFont(rootBundle.load('assets/fonts/Inter-Regular.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Inter-Medium.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Inter-SemiBold.ttf'))
    ..addFont(rootBundle.load('assets/fonts/Inter-Bold.ttf'));
  final fraunces = FontLoader('Fraunces')
    ..addFont(rootBundle.load('assets/fonts/Fraunces-SemiBold.ttf'));
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await Future.wait([inter.load(), fraunces.load(), icons.load()]);
}

void main() {
  setUpAll(() async {
    if (Platform.environment['SCREENSHOT'] != '1') return;
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadType();
  });

  testWidgets('phone shots of the rematch, the stake box, and a prop board', (
    tester,
  ) async {
    if (Platform.environment['SCREENSHOT'] != '1') return;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final evidence = RecentEvidence.fromJson(
      jsonDecode(File('assets/nfl-recent-evidence.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    final matchup = MatchupContext.fromJson(
      jsonDecode(File('assets/nfl-matchup.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    final brief = interpretQuestion(
      question: 'why did the Texans beat the Colts so badly after losing earlier?',
      evidence: evidence,
      players: null,
      ratings: null,
      snaps: matchup.snaps,
      injuries: [
        for (final row in matchup.injuries)
          InjuryNote(
            week: row.week,
            team: row.team,
            player: row.player,
            position: row.position,
            status: row.status,
            injury: row.injury,
          ),
      ],
    );
    expect(brief, isNotNull);
    await _paint(
      tester,
      BriefingView(brief: brief!),
      '/opt/cursor/artifacts/texans-colts-rematch.png',
    );
    await tester.tap(find.text('Since the earlier meeting'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _save(tester, '/opt/cursor/artifacts/texans-colts-rematch-open.png');

    await _paint(
      tester,
      const StakeCalculator(
        initial: 50,
        legs: [
          (label: 'Side A', book: 'FanDuel', decimal: 1.91),
          (label: 'Side B', book: 'DraftKings', decimal: 1.91),
        ],
      ),
      '/opt/cursor/artifacts/stake-split.png',
    );
  });
}

Future<void> _paint(WidgetTester tester, Widget child, String path) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: coachTheme(),
      home: Scaffold(
        backgroundColor: CoachColors.background,
        body: RepaintBoundary(
          key: const Key('shot'),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await _save(tester, path);
}

Future<void> _save(WidgetTester tester, String path) async {
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('shot')),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}
