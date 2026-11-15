import 'package:flutter/material.dart';

/// Consistent readable cards on phone, with two research columns on desktop.
class ResearchGrid extends StatelessWidget {
  const ResearchGrid({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final two =
          box.maxWidth >= 820 &&
          MediaQuery.textScalerOf(context).scale(1) <= 1.3;
      final width = two ? (box.maxWidth - 16) / 2 : box.maxWidth;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}
