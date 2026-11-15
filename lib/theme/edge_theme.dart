import 'package:flutter/material.dart';

/// Neutral charcoal surfaces and a restrained blue accent. Value colors
/// remain separate from navigation and always accompany a text label.
class EdgeColors {
  static const background = Color(0xFF0B0D10);
  static const surface = Color(0xFF14171C);
  static const surfaceHigh = Color(0xFF1C2027);
  static const border = Color(0xFF2A3039);
  static const text = Color(0xFFF4F6FA);
  static const textSecondary = Color(0xFFB5BECC);
  static const textTertiary = Color(0xFF9BA8BA);
  static const accent = Color(0xFF9BC9FF);
  static const good = Color(0xFF69D7B0);
  static const warn = Color(0xFFF1C27A);
  static const bad = Color(0xFFFF918A);
  static const onAccent = Color(0xFF10243A);
}

class EdgeFont {
  static const sans = 'Inter';
  static const display = sans;
  static const brand = 'Fraunces';
}

/// A quiet type hierarchy with tabular figures for comparisons.
class EdgeType {
  static const display = TextStyle(
    fontFamily: EdgeFont.display,
    fontSize: 34,
    fontWeight: FontWeight.w600,
    letterSpacing: -1.1,
    height: 1.15,
    color: EdgeColors.text,
  );
  static const title = TextStyle(
    fontFamily: EdgeFont.sans,
    fontSize: 24,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.7,
    height: 1.2,
    color: EdgeColors.text,
  );
  static const body = TextStyle(
    fontFamily: EdgeFont.sans,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: EdgeColors.text,
  );
  static const label = TextStyle(
    fontFamily: EdgeFont.sans,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.4,
    color: EdgeColors.textSecondary,
  );
  static const number = TextStyle(
    fontFamily: EdgeFont.display,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.6,
    fontFeatures: [FontFeature.tabularFigures()],
    color: EdgeColors.text,
  );
}

class EdgeSpace {
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const page = 20.0;
  static const radius = 16.0;
  static const tap = 48.0;
}

/// Kept so older call sites compile. Accent is chrome, not a value color.
const mint = EdgeColors.accent;
const panel = EdgeColors.surface;

ThemeData edgeTheme() {
  const scheme = ColorScheme.dark(
    primary: EdgeColors.accent,
    onPrimary: EdgeColors.onAccent,
    secondary: EdgeColors.accent,
    onSecondary: EdgeColors.onAccent,
    surface: EdgeColors.surface,
    outline: EdgeColors.border,
    outlineVariant: EdgeColors.border,
    onSurface: EdgeColors.text,
    error: EdgeColors.bad,
    onError: EdgeColors.onAccent,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: EdgeColors.background,
    colorScheme: scheme,
    fontFamily: EdgeFont.sans,
    fontFamilyFallback: const ['Segoe UI', 'sans-serif'],
    textTheme: const TextTheme(
      displayLarge: EdgeType.display,
      headlineMedium: EdgeType.title,
      titleLarge: EdgeType.title,
      titleMedium: EdgeType.body,
      bodyLarge: EdgeType.body,
      bodyMedium: EdgeType.body,
      bodySmall: EdgeType.label,
      labelLarge: EdgeType.label,
    ),
    iconTheme: const IconThemeData(color: EdgeColors.text, size: 22),
    dividerColor: EdgeColors.border,
    dividerTheme: const DividerThemeData(
      color: EdgeColors.border,
      thickness: 1,
      space: 1,
    ),
    splashFactory: InkRipple.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: EdgeColors.background,
      foregroundColor: EdgeColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: EdgeType.title,
    ),
    cardTheme: const CardThemeData(
      color: EdgeColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: EdgeColors.textSecondary,
      textColor: EdgeColors.text,
      titleTextStyle: EdgeType.body,
      subtitleTextStyle: EdgeType.label,
      minVerticalPadding: 12,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: EdgeColors.surface,
      labelStyle: EdgeType.label,
      hintStyle: EdgeType.label,
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: EdgeColors.accent, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: EdgeColors.accent,
        foregroundColor: EdgeColors.onAccent,
        minimumSize: const Size(48, EdgeSpace.tap),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        textStyle: EdgeType.body.copyWith(fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: EdgeColors.accent,
        minimumSize: const Size(48, EdgeSpace.tap),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        textStyle: EdgeType.body.copyWith(fontWeight: FontWeight.w600),
        side: const BorderSide(color: EdgeColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: EdgeColors.accent,
        minimumSize: const Size(48, EdgeSpace.tap),
        textStyle: EdgeType.body.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.transparent,
      selectedColor: EdgeColors.surfaceHigh,
      labelStyle: EdgeType.label.copyWith(color: EdgeColors.text),
      secondaryLabelStyle: EdgeType.label.copyWith(color: EdgeColors.accent),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: EdgeColors.accent,
      thumbColor: EdgeColors.accent,
      trackHeight: 4,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 10),
      showValueIndicator: ShowValueIndicator.onDrag,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: EdgeColors.background,
      elevation: 0,
      height: 68,
      indicatorColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return EdgeType.label.copyWith(
          fontSize: 11,
          color: selected ? EdgeColors.accent : EdgeColors.textSecondary,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? EdgeColors.accent : EdgeColors.textSecondary,
          size: 24,
        );
      }),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: EdgeColors.surface,
      titleTextStyle: EdgeType.title,
      contentTextStyle: EdgeType.body,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: EdgeColors.surfaceHigh,
      contentTextStyle: EdgeType.body,
      behavior: SnackBarBehavior.floating,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: EdgeColors.accent,
    ),
  );
}

Color valueColor(double? value) {
  if (value == null || value == 0) return EdgeColors.textSecondary;
  return value > 0 ? EdgeColors.good : EdgeColors.bad;
}
