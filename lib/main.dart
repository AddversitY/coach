import 'package:flutter/material.dart';

import 'coach/coach_workspace.dart';
import 'data/published_snapshot.dart';
import 'theme/coach_theme.dart';

void main() => runApp(const OddsEdgeApp());

class OddsEdgeApp extends StatelessWidget {
  const OddsEdgeApp({super.key, this.snapshotLoader});
  final Future<PublishedSnapshot> Function()? snapshotLoader;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Coach',
    debugShowCheckedModeBanner: false,
    theme: coachTheme(),
    home: CoachWorkspace(snapshotLoader: snapshotLoader),
  );
}
