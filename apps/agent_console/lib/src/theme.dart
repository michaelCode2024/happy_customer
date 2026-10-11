import 'package:flutter/material.dart';

/// One place for the console's colour and shape decisions.
///
/// The console is a tool an agent stares at for eight hours, so the palette is
/// deliberately quiet: a single teal accent carries every action, and colour is
/// otherwise reserved for meaning (unread, resolved, AI, internal note). Using
/// [ColorScheme.fromSeed] with one seed keeps light and dark in step without a
/// second palette to maintain.
class RelayTheme {
  const RelayTheme._();

  static const Color seed = Color(0xFF087F72);

  /// The accent used for visitor messages: neutral, so the agent's own replies
  /// are the only accent colour in the thread.
  static const Color visitorBubbleLight = Color(0xFFF0F3F2);
  static const Color visitorBubbleDark = Color(0xFF26282E);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    );
    return _base(scheme);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF68D7B9),
      brightness: Brightness.dark,
    );
    return _base(scheme);
  }

  static ThemeData _base(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF151B1A) : const Color(0xFFF5F7F6),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? const Color(0xFF1B2422) : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: isDark ? const Color(0xFF1B2422) : Colors.white,
        indicatorColor: scheme.primaryContainer,
        labelType: NavigationRailLabelType.all,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xFF1B2422) : Colors.white,
        indicatorColor: scheme.primaryContainer,
        height: 64,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      visualDensity: VisualDensity.compact,
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: scheme.outlineVariant.withAlpha(isDark ? 90 : 140),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: isDark ? const Color(0xFF1D2624) : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        dense: true,
        visualDensity: VisualDensity.compact,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
      ),
      tooltipTheme:
          const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    );
  }

  /// The bubble background for the visitor's side of the thread.
  static Color visitorBubble(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
          ? visitorBubbleDark
          : visitorBubbleLight;

  /// The colour a tag chip is tinted with. Tags carry a colour name from the
  /// server, but the console shows the name inside a neutral chip: a tenant's
  /// free-text colour must not be able to produce unreadable text.
  static Color tagTint(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
          ? scheme.secondaryContainer.withAlpha(120)
          : scheme.secondaryContainer.withAlpha(180);
}
