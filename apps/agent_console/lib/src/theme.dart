import 'package:flutter/material.dart';

/// 通语控制台主题：紧凑的中文企业工作台。
///
/// 特征：蓝色主色、会话选中浅蓝、白色聊天画布、
/// 浅蓝坐席气泡、浅灰访客气泡、紧凑的信息密度。
class RelayTheme {
  const RelayTheme._();

  /// 接近腾讯 IM / 企点常用主色，避免发紫。
  static const Color seed = Color(0xFF4263EB);

  /// 会话列表选中行。
  static const Color listSelectedLight = Color(0xFFEEF2FF);
  static const Color listSelectedDark = Color(0xFF1A2A40);

  /// 消息区画布（微信/腾讯 IM 常见浅灰）。
  static const Color chatCanvasLight = Color(0xFFF4F6F9);
  static const Color chatCanvasDark = Color(0xFF111418);

  /// 浅色模式坐席气泡为浅蓝，访客气泡为浅灰。
  static const Color agentBubbleLight = Color(0xFFDDEBFF);
  static const Color agentBubbleDark = Color(0xFF3B82F6);
  static const Color visitorBubbleLight = Color(0xFFFFFFFF);
  static const Color success = Color(0xFF31977C);
  static const Color warning = Color(0xFFFF7D00);
  static const Color tertiary = Color(0xFF8992A3);
  static const Color visitorBubbleDark = Color(0xFF2A2F38);

  static List<BoxShadow> softShadow(Brightness brightness) => [
        BoxShadow(
          color: brightness == Brightness.dark
              ? Colors.black.withOpacity(0.35)
              : const Color(0xFF0F172A).withOpacity(0.04),
          blurRadius: 16,
          offset: const Offset(0, 4),
        ),
      ];

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    );
    return _base(scheme.copyWith(
      primary: seed,
      primaryContainer: const Color(0xFFEEF2FF),
      onPrimary: Colors.white,
      onPrimaryContainer: const Color(0xFF0B4DB8),
      secondary: const Color(0xFF5B6B7C),
      surface: Colors.white,
      surfaceContainerHighest: const Color(0xFFF5F7FC),
      outlineVariant: const Color(0xFFE7ECF4),
      outline: tertiary,
      onSurface: const Color(0xFF202B3D),
      onSurfaceVariant: const Color(0xFF637186),
      error: const Color(0xFFF53F3F),
    ));
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5BA3FF),
      brightness: Brightness.dark,
    );
    return _base(scheme.copyWith(
      primary: const Color(0xFF5BA3FF),
      primaryContainer: const Color(0xFF1A2A40),
      surface: const Color(0xFF171B22),
      surfaceContainerHighest: const Color(0xFF222733),
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

    final radius = BorderRadius.circular(16);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: textTheme.copyWith(
        bodyMedium: textTheme.bodyMedium?.copyWith(fontSize: 13, height: 1.6),
        bodySmall: textTheme.bodySmall?.copyWith(fontSize: 12, height: 1.5),
        titleMedium: textTheme.titleMedium
            ?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
        titleSmall: textTheme.titleSmall
            ?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
        headlineSmall: textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(size: 20, color: scheme.onSurfaceVariant),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(64, 34),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          minimumSize: const Size(80, 36),
          side: BorderSide(color: scheme.outlineVariant),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: BorderSide(color: scheme.outlineVariant, width: 1.5),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: BorderSide(color: scheme.outlineVariant),
        showCheckmark: false,
        labelStyle: const TextStyle(fontSize: 12),
        backgroundColor: scheme.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
      fontFamilyFallback: _cjkFallback,
      // 国内 IM 控制台：整页浅灰底，三栏贴边，少「浮卡片」。
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF0F1218) : const Color(0xFFF5F7FC),
      appBarTheme: AppBarTheme(
        toolbarHeight: 68,
        titleSpacing: 24,
        shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        scrolledUnderElevation: 0,
        backgroundColor: isDark ? const Color(0xFF171B22) : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          fontFamilyFallback: _cjkFallback,
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: isDark ? const Color(0xFF171B22) : Colors.white,
        indicatorColor: scheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.primary, size: 22),
        unselectedIconTheme:
            IconThemeData(color: scheme.onSurfaceVariant, size: 22),
        labelType: NavigationRailLabelType.none,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xFF171B22) : Colors.white,
        indicatorColor: scheme.primaryContainer,
        height: 60,
        elevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: seed,
          foregroundColor: Colors.white,
          minimumSize: const Size(72, 36),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      cardTheme: CardTheme(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: const Color(0x0A1F2329),
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
          fontFamilyFallback: _cjkFallback,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
        dataRowMinHeight: 64,
        dataRowMaxHeight: 72,
        horizontalMargin: 20,
        columnSpacing: 24,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          side:
              WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        ),
      ),
      visualDensity: VisualDensity.standard,
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: scheme.outlineVariant,
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        hintStyle: TextStyle(
          fontSize: 13,
          color: scheme.onSurfaceVariant.withAlpha(160),
        ),
        labelStyle: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        helperStyle: TextStyle(
          fontSize: 12,
          color: scheme.onSurfaceVariant.withAlpha(170),
        ),
        errorMaxLines: 2,
        filled: true,
        fillColor: isDark ? const Color(0xFF1F2430) : Colors.white,
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
          borderSide: BorderSide(color: scheme.primary, width: 1.2),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        dense: true,
        visualDensity: VisualDensity.compact,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      tooltipTheme:
          const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    );
  }

  static Color chatCanvas(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark ? chatCanvasDark : chatCanvasLight;

  static Color agentBubble(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark ? agentBubbleDark : agentBubbleLight;

  static Color visitorBubble(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
          ? visitorBubbleDark
          : visitorBubbleLight;

  static Color listSelected(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
          ? listSelectedDark
          : listSelectedLight;

  static Color tagTint(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
          ? scheme.secondaryContainer.withAlpha(120)
          : scheme.secondaryContainer.withAlpha(180);
}
