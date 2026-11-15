import 'package:flutter/material.dart';

import '../data/published_snapshot.dart';
import '../domain/eastern.dart';
import '../theme/edge_theme.dart';

class SnapshotSourceBar extends StatelessWidget {
  const SnapshotSourceBar({
    super.key,
    required this.published,
    required this.loading,
    required this.snapshot,
    required this.error,
    required this.now,
    required this.onSwitch,
    required this.onRefresh,
  });
  final bool published, loading;
  final PublishedSnapshot? snapshot;
  final String? error;
  final DateTime now;
  final VoidCallback onSwitch, onRefresh;

  String _checkedLabel() {
    final at = snapshot?.scheduleAt;
    if (at == null) return 'Schedule unavailable';
    final age = now.difference(at);
    if (age.inMinutes < 1) return 'Checked just now';
    if (age.inMinutes < 60) return 'Checked ${age.inMinutes}m ago';
    if (age.inHours < 24) return 'Checked ${age.inHours}h ago';
    return 'Checked ${formatEastern(at)}';
  }

  @override
  Widget build(BuildContext context) {
    final stale = snapshot?.stale(now) ?? false;
    final status = !published
        ? 'Invented prices and matchups'
        : loading
        ? 'Checking schedule…'
        : error != null
        ? 'Update failed${snapshot == null
              ? ''
              : stale
              ? ' · outdated schedule'
              : ' · saved schedule'}'
        : stale
        ? 'Schedule is outdated · ${_checkedLabel()}'
        : _checkedLabel();
    final sourceContent = Tooltip(
      message: 'About this data',
      excludeFromSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _showDetails(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  published
                      ? Icons.calendar_month_outlined
                      : Icons.science_outlined,
                  size: 14,
                  color: EdgeColors.textTertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          published
                              ? snapshot?.hasPrices == true
                                    ? 'NFL · limited price coverage'
                                    : 'NFL schedule · prices unavailable'
                              : 'Sample props',
                          style: EdgeType.label.copyWith(
                            fontSize: 12,
                            color: EdgeColors.textSecondary,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                        Text(
                          status,
                          style: EdgeType.label.copyWith(
                            fontSize: 11,
                            color: error != null || stale
                                ? EdgeColors.warn
                                : EdgeColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final source = Semantics(
      key: const Key('snapshot-source-details'),
      button: true,
      label: 'About this data',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: EdgeSpace.tap),
        child: sourceContent,
      ),
    );
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1152),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: EdgeColors.border.withValues(alpha: .4),
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final controls = <Widget>[
                    TextButton(
                      key: const Key('switch-snapshot-mode'),
                      onPressed: onSwitch,
                      style: TextButton.styleFrom(
                        textStyle: EdgeType.label.copyWith(fontSize: 12),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: Text(published ? 'Sample props' : 'Actual games'),
                    ),
                    if (published && error != null)
                      IconButton(
                        tooltip: 'Reload published schedule',
                        onPressed: loading ? null : onRefresh,
                        icon: const Icon(Icons.refresh, size: 18),
                      ),
                  ];
                  if (constraints.maxWidth < 600 &&
                      MediaQuery.textScalerOf(context).scale(1) > 1.2) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        source,
                        Wrap(alignment: WrapAlignment.end, children: controls),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: source),
                      ...controls,
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showDetails(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('About this preview', style: EdgeType.title),
                const SizedBox(height: 12),
                Text(
                  snapshot?.hasPrices == true
                      ? 'Actual games use a published NFL schedule. Prices cover one limited NFL pilot and are timestamped snapshots, with prices unavailable outside that coverage. The separate sample mode contains invented matchups and prices.'
                      : 'Actual games use a published NFL schedule. Player research uses dated historical records. Sportsbook prices are not connected. The separate sample mode contains invented matchups and prices.',
                  style: EdgeType.body,
                ),
                if (snapshot?.quoteAt != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Price snapshot ${formatEastern(snapshot!.quoteAt!, year: true)}',
                    style: EdgeType.label,
                  ),
                ],
                const SizedBox(height: 12),
                const Text(
                  'Historical player box scores and model reports have their own cutoffs. They are not live roster or injury confirmations. The simulator is experimental and has no demonstrated betting edge.',
                  style: EdgeType.body,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Schedule: nflverse · CC BY 4.0. Changes may occur after the snapshot. Scheduled refreshes run twice daily; no continuous odds feed.',
                  style: EdgeType.label,
                ),
                if (snapshot != null)
                  Text(
                    'Schedule fetched ${formatEastern(snapshot!.scheduleAt, year: true)}',
                    style: EdgeType.label,
                  ),
                const SelectableText(
                  'https://github.com/nflverse/nflverse-data\nhttps://creativecommons.org/licenses/by/4.0/',
                  style: EdgeType.label,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
