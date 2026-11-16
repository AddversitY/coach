import 'package:flutter/material.dart';

/// Paper, stone and graphite. Color is reserved for meaningful data states.
class CoachColors {
  static const background = Color(0xFFF4F4F0);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceHigh = Color(0xFFE9EAE5);
  static const border = Color(0xFFCFD2CA);
  static const text = Color(0xFF222722);
  static const textSecondary = Color(0xFF555D55);
  static const textTertiary = Color(0xFF656D65);
  static const accent = Color(0xFF303A32);
  static const onAccent = Colors.white;
  static const warn = Color(0xFF81552D);
  static const bad = Color(0xFF953C35);
}

class CoachType {
  static const display = TextStyle(
    fontFamily: 'Fraunces',
    fontWeight: FontWeight.w600,
    fontSize: 48,
    letterSpacing: -1.7,
    height: 1.05,
    color: CoachColors.text,
  );
  static const title = TextStyle(
    fontFamily: 'Fraunces',
    fontWeight: FontWeight.w600,
    fontSize: 28,
    letterSpacing: -.7,
    height: 1.16,
    color: CoachColors.text,
  );
  static const body = TextStyle(
    fontFamily: 'Inter',
    fontSize: 15,
    height: 1.65,
    color: CoachColors.text,
  );
  static const label = TextStyle(
    fontFamily: 'Inter',
    fontSize: 12,
    height: 1.5,
    color: CoachColors.textSecondary,
  );
  static const number = TextStyle(
    fontFamily: 'Inter',
    fontWeight: FontWeight.w600,
    fontFeatures: [FontFeature.tabularFigures()],
    letterSpacing: -.7,
    color: CoachColors.text,
  );
}

ThemeData coachTheme() => ThemeData(
  useMaterial3: true,
  brightness: Brightness.light,
  fontFamily: 'Inter',
  scaffoldBackgroundColor: CoachColors.background,
  colorScheme: const ColorScheme.light(
    primary: CoachColors.accent,
    onPrimary: Colors.white,
    secondary: CoachColors.accent,
    onSecondary: Colors.white,
    surface: CoachColors.surface,
    onSurface: CoachColors.text,
    outline: CoachColors.border,
    error: CoachColors.bad,
  ),
  textTheme: const TextTheme(
    displayLarge: CoachType.display,
    titleLarge: CoachType.title,
    bodyLarge: CoachType.body,
    bodyMedium: CoachType.body,
    bodySmall: CoachType.label,
    labelLarge: CoachType.label,
  ),
  iconTheme: const IconThemeData(color: CoachColors.textSecondary, size: 20),
  dividerTheme: const DividerThemeData(
    color: CoachColors.border,
    space: 1,
    thickness: 1,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: CoachColors.background,
    foregroundColor: CoachColors.text,
    elevation: 0,
    scrolledUnderElevation: 0,
  ),
  inputDecorationTheme: const InputDecorationTheme(
    hintStyle: CoachType.label,
    filled: false,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
  ),
  iconButtonTheme: IconButtonThemeData(
    style: IconButton.styleFrom(
      foregroundColor: CoachColors.text,
      minimumSize: const Size(48, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
    ),
  ),
  chipTheme: ChipThemeData(
    backgroundColor: Colors.transparent,
    selectedColor: CoachColors.surfaceHigh,
    labelStyle: CoachType.label,
    side: const BorderSide(color: CoachColors.border),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
  ),
  listTileTheme: const ListTileThemeData(
    textColor: CoachColors.text,
    iconColor: CoachColors.textSecondary,
    titleTextStyle: CoachType.body,
    subtitleTextStyle: CoachType.label,
    minVerticalPadding: 12,
  ),
  expansionTileTheme: const ExpansionTileThemeData(
    backgroundColor: Colors.transparent,
    collapsedBackgroundColor: Colors.transparent,
    iconColor: CoachColors.textSecondary,
    collapsedIconColor: CoachColors.textSecondary,
    shape: Border(bottom: BorderSide(color: CoachColors.border)),
    collapsedShape: Border(bottom: BorderSide(color: CoachColors.border)),
  ),
  bottomSheetTheme: const BottomSheetThemeData(
    backgroundColor: CoachColors.background,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: CoachColors.text,
      minimumSize: const Size(48, 48),
      side: const BorderSide(color: CoachColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
    ),
  ),
  progressIndicatorTheme: const ProgressIndicatorThemeData(
    color: CoachColors.accent,
  ),
  textSelectionTheme: TextSelectionThemeData(
    cursorColor: CoachColors.accent,
    selectionColor: CoachColors.border.withValues(alpha: .7),
    selectionHandleColor: CoachColors.accent,
  ),
);
