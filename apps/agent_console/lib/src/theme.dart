import 'package:flutter/material.dart';

/// 通语控制台主题：偏飞书/企微的浅色留白、细边与圆角，主色只承担行动与选中态。
class RelayTheme {
  const RelayTheme._();

  /// 定稿主色，与 Logo 蓝一致。
  static const Color seed = Color(0xFF2F6BFF);

  static const Color visitorBubbleLight = Color(0xFFF2F4F7);
  static const Color visitorBubbleDark = Color(0xFF26282E);

  /// 内容浮层的轻阴影，用来做出「卡片浮在画布上」的层次。
  static List<BoxShadow> softShadow(Brightness brightness) => [
        BoxShadow(
          color: brightness == Brightness.dark
              ? Colors.black.withOpacity(0.35)
              : const Color(0xFF0F172A).withOpacity(0.06),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ];

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    );
    return _base(scheme.copyWith(
      primary: seed,
      primaryContainer: const Color(0xFFE8F0FF),
      onPrimaryContainer: const Color(0xFF1D4ED8),
      surface: Colors.white,
      surfaceContainerHighest: const Color(0xFFF5F7FB),
      outlineVariant: const Color(0xFFE6EAF0),
      onSurface: const Color(0xFF111827),
      onSurfaceVariant: const Color(0xFF6B7280),
    ));
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF82A7FF),
      brightness: Brightness.dark,
    );
    return _base(scheme.copyWith(
      primary: const Color(0xFF82A7FF),
      primaryContainer: const Color(0xFF243552),
      surface: const Color(0xFF171B24),
      surfaceContainerHighest: const Color(0xFF222735),
      outlineVariant: const Color(0xFF303848),
    ));
  }

  static const List<String> _cjkFallback = <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans SC',
    'Source Han Sans SC',
    'WenQuanYi Micro Hei',
    'sans-serif',
  ];

  static ThemeData _base(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    final textTheme = ThemeData(
      brightness: scheme.brightness,
      useMaterial3: true,
      colorScheme: scheme,
    ).textTheme.apply(fontFamilyFallback: _cjkFallback);

    final radius = BorderRadius.circular(12);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: textTheme.copyWith(
        bodyMedium: textTheme.bodyMedium?.copyWith(fontSize: 14, height: 1.55),
        bodySmall: textTheme.bodySmall?.copyWith(fontSize: 12.5, height: 1.5),
        titleMedium:
            textTheme.titleMedium?.copyWith(fontSize: 15.5, fontWeight: FontWeight.w600),
        titleSmall:
            textTheme.titleSmall?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
        headlineSmall: textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(size: 20, color: scheme.onSurfaceVariant),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(64, 36),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          minimumSize: const Size(80, 38),
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: BorderSide(color: scheme.outlineVariant, width: 1.5),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide(color: scheme.outlineVariant),
        showCheckmark: false,
        labelStyle: const TextStyle(fontSize: 13),
        backgroundColor: scheme.surfaceContainerHighest,
      ),
      fontFamilyFallback: _cjkFallback,
      // 外层浅灰画布，内层面板保持纯白，形成参考图那种浮层感。
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF0F1218) : const Color(0xFFEEF1F6),
      appBarTheme: AppBarTheme(
        toolbarHeight: 56,
        scrolledUnderElevation: 0,
        backgroundColor: isDark ? const Color(0xFF171B24) : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          fontFamilyFallback: _cjkFallback,
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: isDark ? const Color(0xFF171B24) : Colors.white,
        indicatorColor: scheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.primary, size: 22),
        unselectedIconTheme:
            IconThemeData(color: scheme.onSurfaceVariant, size: 22),
        labelType: NavigationRailLabelType.none,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xFF171B24) : Colors.white,
        indicatorColor: scheme.primaryContainer,
        height: 64,
        elevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(88, 40),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      cardTheme: CardTheme(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: scheme.outlineVariant.withOpacity(0.9)),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
          fontFamilyFallback: _cjkFallback,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      tabBarTheme: TabBarTheme(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        dividerColor: scheme.outlineVariant,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 13),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStatePropertyAll(scheme.surfaceContainerHighest),
        headingRowHeight: 44,
        dataRowMinHeight: 52,
        dataRowMaxHeight: 64,
        horizontalMargin: 20,
        columnSpacing: 28,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        ),
      ),
      visualDensity: VisualDensity.standard,
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: scheme.outlineVariant.withAlpha(isDark ? 100 : 160),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        hintStyle: TextStyle(
          fontSize: 13,
          color: scheme.onSurfaceVariant.withAlpha(150),
        ),
        labelStyle: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        helperStyle: TextStyle(
          fontSize: 12,
          color: scheme.onSurfaceVariant.withAlpha(170),
        ),
        errorMaxLines: 2,
        filled: true,
        fillColor: isDark ? const Color(0xFF1F2430) : const Color(0xFFF8FAFC),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        dense: true,
        visualDensity: VisualDensity.compact,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tooltipTheme:
          const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    );
  }

  static Color visitorBubble(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
          ? visitorBubbleDark
          : visitorBubbleLight;

  static Color tagTint(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
          ? scheme.secondaryContainer.withAlpha(120)
          : scheme.secondaryContainer.withAlpha(180);
}
