import 'package:flutter/material.dart';

/// One place for the console's colour and shape decisions.
///
/// The console is a tool an agent stares at for eight hours, so the palette is
/// deliberately quiet: a single blue accent carries every action, and colour is
/// otherwise reserved for meaning (unread, resolved, AI, internal note). Using
/// [ColorScheme.fromSeed] with one seed keeps light and dark in step without a
/// second palette to maintain.
class RelayTheme {
  const RelayTheme._();

  static const Color seed = Color(0xFF356AE6);

  /// The accent used for visitor messages: neutral, so the agent's own replies
  /// are the only blue thing in the thread.
  static const Color visitorBubbleLight = Color(0xFFF1F3F7);
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
      seedColor: const Color(0xFF86A8FF),
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
          isDark ? const Color(0xFF15161A) : const Color(0xFFF7F8FA),
      visualDensity: VisualDensity.compact,
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: scheme.outlineVariant.withAlpha(isDark ? 90 : 140),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: isDark ? const Color(0xFF1E1F24) : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
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
      tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    );
  }

  /// The bubble background for the visitor's side of the thread.
  static Color visitorBubble(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark ? visitorBubbleDark : visitorBubbleLight;

  /// The colour a tag chip is tinted with. Tags carry a colour name from the
  /// server, but the console shows the name inside a neutral chip: a tenant's
  /// free-text colour must not be able to produce unreadable text.
  static Color tagTint(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
          ? scheme.secondaryContainer.withAlpha(120)
          : scheme.secondaryContainer.withAlpha(180);
}
