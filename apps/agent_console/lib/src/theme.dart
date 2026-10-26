import 'package:flutter/material.dart';

/// 通语控制台主题：v2 活力改版（B 高密高效 + 视觉活力）。
///
/// 主蓝 #3263ff、正文 #0c1d40、弱文 #637b9e；
/// 辅色青绿 / 琥珀 / 浅紫 / 品红；渐变主按钮与蓝色发光。
class RelayTheme {
  const RelayTheme._();

  /// 品牌主色。
  static const Color seed = Color(0xFF3263FF);
  static const Color blue = Color(0xFF3263FF);
  static const Color blueSoft = Color(0xFFEDF2FF);
  static const Color blueDeep = Color(0xFF244FE8);
  static const Color blueGlow = Color(0x333263FF);

  /// 正文与弱文。
  static const Color ink = Color(0xFF0C1D40);
  static const Color muted = Color(0xFF637B9E);

  /// 辅色。
  static const Color teal = Color(0xFF12B886);
  static const Color tealSoft = Color(0xFFE6FAF3);
  static const Color amber = Color(0xFFF59F00);
  static const Color amberSoft = Color(0xFFFFF4DF);
  static const Color violet = Color(0xFF845EF7);
  static const Color violetSoft = Color(0xFFF3F0FF);
  static const Color magenta = Color(0xFFE64980);
  static const Color magentaSoft = Color(0xFFFFF0F6);

  /// 表面与描边。
  static const Color canvasLight = Color(0xFFEEF2FB);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color surfaceLowLight = Color(0xFFF4F7FF);
  static const Color borderLight = Color(0xFFE7EDF6);
  static const Color borderStrongLight = Color(0xFFD8DEEA);
  static const Color inkLight = ink;
  static const Color inkMutedLight = muted;

  /// 会话列表选中行。
  static const Color listSelectedLight = Color(0xFFEAF0FF);
  static const Color listSelectedDark = Color(0xFF1E283D);

  /// 侧栏轨（客服约 78px）。
  static const double agentRailWidth = 78;
  static const double platformRailWidth = 220;
  static const Color railBackgroundLight = Color(0xFFF5F7FF);
  static const Color railBorderLight = Color(0xFFE7EDF6);

  /// 消息区画布。
  static const Color chatCanvasLight = Color(0xFFF4F7FF);
  static const Color chatCanvasDark = Color(0xFF111418);

  /// 坐席 / 访客气泡。浅色主题用淡蓝底深色字，避免实心蓝过重、字对比度差。
  static const Color agentBubbleLight = Color(0xFFDFE8FF);
  static const Color agentBubbleDark = Color(0xFF3B6AF5);
  static const Color visitorBubbleLight = Color(0xFFFFFFFF);
  static const Color visitorBubbleDark = Color(0xFF2A2F38);

  /// 语义色（对齐 v2 辅色，避免假涨跌装饰色）。
  static const Color success = teal;
  static const Color warning = amber;
  static const Color tertiary = Color(0xFF8992A3);

  /// 圆角基准。
  static const double radiusMd = 12;
  static const double radiusLg = 14;
  static const double radiusXl = 16;

  /// 主按钮渐变。
  static const LinearGradient actionGradient = LinearGradient(
    begin: Alignment(-0.9, -0.4),
    end: Alignment(0.9, 0.6),
    colors: [Color(0xFF5B8CFF), Color(0xFF3263FF), Color(0xFF244FE8)],
    stops: [0.0, 0.55, 1.0],
  );

  static const LinearGradient tealGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF20C997), Color(0xFF12B886)],
  );

  static const LinearGradient loginHeroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFF2A4FFF),
      Color(0xFF3263FF),
      Color(0xFF5B4FD6),
      Color(0xFF845EF7),
    ],
    stops: [0.0, 0.35, 0.78, 1.0],
  );

  static const LinearGradient workspaceWash = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFEEF3FF), Color(0xFFF5F7FB), Color(0xFFF7F3FF)],
    stops: [0.0, 0.4, 1.0],
  );

  static List<BoxShadow> softShadow(Brightness brightness) => [
        BoxShadow(
          color: brightness == Brightness.dark
              ? Colors.black.withOpacity(0.35)
              : const Color(0x143263FF),
          blurRadius: 30,
          offset: const Offset(0, 10),
        ),
        BoxShadow(
          color: brightness == Brightness.dark
              ? Colors.black.withOpacity(0.2)
              : const Color(0x0A0C1D40),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ];

  static List<BoxShadow> cardShadow(Brightness brightness) => [
        BoxShadow(
          color: brightness == Brightness.dark
              ? Colors.black.withOpacity(0.4)
              : const Color(0x1A3263FF),
          blurRadius: 36,
          offset: const Offset(0, 12),
        ),
        BoxShadow(
          color: brightness == Brightness.dark
              ? Colors.black.withOpacity(0.2)
              : const Color(0x0A0C1D40),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ];

  static List<BoxShadow> popShadow([Color color = blue]) => [
        BoxShadow(
          color: color.withOpacity(0.22),
          blurRadius: 40,
          offset: const Offset(0, 14),
        ),
      ];

  static List<BoxShadow> agentBubbleShadow() => [
        BoxShadow(
          color: blue.withOpacity(0.20),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ];

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    );
    return _base(scheme.copyWith(
      primary: seed,
      primaryContainer: blueSoft,
      onPrimary: Colors.white,
      onPrimaryContainer: blueDeep,
      secondary: muted,
      secondaryContainer: const Color(0xFFEEF2F8),
      tertiary: violet,
      tertiaryContainer: violetSoft,
      surface: surfaceLight,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFF7F9FD),
      surfaceContainer: const Color(0xFFF1F4FA),
      surfaceContainerHigh: const Color(0xFFEBEFF7),
      surfaceContainerHighest: surfaceLowLight,
      outlineVariant: borderLight,
      outline: muted,
      onSurface: ink,
      onSurfaceVariant: muted,
      error: const Color(0xFFE5484D),
    ));
  }

  static ThemeData dark() {
    // Light-only product: keep the method for MaterialApp wiring,
    // but never expose a dark palette to agents.
    return light();
  }

  // Web CanvasKit 必须用本地清单字体；系统名与 Plus Jakarta（仅 CSS @font-face）
  // Skia 都看不见，写进 fallback 只会触发 gstatic 拉片、国内闪方框。
  static const List<String> _fontFamily = <String>[
    'SportsChinese',
  ];

  // ChatEmoji 由 web_emoji_font.dart 首屏后注册；封掉 gstatic 后气泡 emoji 靠它。
  static const List<String> _cjkFallback = <String>['ChatEmoji'];

  static ThemeData _base(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    final textTheme = ThemeData(
      brightness: scheme.brightness,
      useMaterial3: true,
      colorScheme: scheme,
    ).textTheme.apply(
      fontFamily: _fontFamily.first,
      fontFamilyFallback: _cjkFallback,
    );

    final radius = BorderRadius.circular(radiusLg);

    // 不要把 fontFamily 挂到 ThemeData 根上：CanvasKit 会让 Material Icons
    // 跟着走中文字体栈，图标变空白。中文只通过 textTheme 注入。
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: textTheme.copyWith(
        titleLarge: textTheme.titleLarge?.copyWith(
            fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.2),
        titleMedium: textTheme.titleMedium
            ?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
        titleSmall: textTheme.titleSmall
            ?.copyWith(fontSize: 13.5, fontWeight: FontWeight.w600),
        bodyMedium: textTheme.bodyMedium?.copyWith(fontSize: 13, height: 1.55),
        bodySmall: textTheme.bodySmall?.copyWith(fontSize: 12, height: 1.5),
        labelMedium: textTheme.labelMedium
            ?.copyWith(fontSize: 12, fontWeight: FontWeight.w600),
        labelSmall: textTheme.labelSmall?.copyWith(fontSize: 11),
        headlineSmall: textTheme.headlineSmall?.copyWith(
          fontSize: 25,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
      ),
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(size: 20, color: scheme.onSurfaceVariant),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(56, 32),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          // 按钮会用这份 textStyle 换掉默认字体。不带中文字体时，中文标签在 CanvasKit 上是空的。
          textStyle: _buttonText(13, FontWeight.w500),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusMd)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          minimumSize: const Size(72, 34),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          textStyle: _buttonText(13, FontWeight.w500),
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusMd)),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: BorderSide(color: scheme.outlineVariant, width: 1.5),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd)),
        side: BorderSide(color: scheme.outlineVariant),
        showCheckmark: false,
        labelStyle: _buttonText(12, FontWeight.w500),
        backgroundColor: scheme.surface,
        selectedColor: scheme.primaryContainer,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      fontFamilyFallback: _cjkFallback,
      scaffoldBackgroundColor: isDark ? const Color(0xFF0F1218) : canvasLight,
      appBarTheme: AppBarTheme(
        toolbarHeight: 54,
        titleSpacing: 16,
        shape: Border(bottom: BorderSide(color: scheme.outlineVariant.withOpacity(0.85))),
        scrolledUnderElevation: 0,
        backgroundColor:
            isDark ? const Color(0xFF171B22) : Colors.white.withOpacity(0.92),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          fontFamily: _fontFamily.first,
          fontFamilyFallback: _cjkFallback,
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor:
            isDark ? const Color(0xFF171B22) : railBackgroundLight,
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
          minimumSize: const Size(64, 34),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          textStyle: _buttonText(13, FontWeight.w600),
          elevation: 0,
          shadowColor: blueGlow,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusMd)),
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface.withOpacity(0.96),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: blueGlow,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: scheme.outlineVariant.withOpacity(0.9)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
          fontFamily: _fontFamily.first,
          fontFamilyFallback: _cjkFallback,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusXl)),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        dividerColor: scheme.outlineVariant,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 13),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
        headingRowHeight: 40,
        dataRowMinHeight: 52,
        dataRowMaxHeight: 60,
        horizontalMargin: 16,
        columnSpacing: 20,
        headingTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
        dataTextStyle: TextStyle(fontSize: 13, color: scheme.onSurface),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(_buttonText(13, FontWeight.w500)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
          ),
          side: WidgetStatePropertyAll(
              BorderSide(color: scheme.outlineVariant)),
        ),
      ),
      visualDensity: VisualDensity.compact,
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
        labelStyle: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        helperStyle: TextStyle(
          fontSize: 11.5,
          color: scheme.onSurfaceVariant.withAlpha(170),
        ),
        errorMaxLines: 2,
        filled: true,
        fillColor: isDark ? const Color(0xFF1F2430) : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        dense: true,
        visualDensity: VisualDensity.compact,
      ),
      // 桌面大屏下 SnackBar 默认贴底居中，容易挡住输入框；加边距并允许关闭。
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        insetPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd)),
      ),
      tooltipTheme:
          const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    );
  }

  /// 按钮的 textStyle 会整份替换默认字体。中文必须写在这里，不能只靠 textTheme。
  static TextStyle _buttonText(double size, FontWeight weight) => TextStyle(
        fontFamily: _fontFamily.first,
        fontFamilyFallback: _cjkFallback,
        fontSize: size,
        fontWeight: weight,
      );

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

  /// 多色头像托：按 seed 轮转辅色，避免满屏同色灰块。
  static Color avatarTray(String seed, {bool soft = true}) {
    final palettes = soft
        ? const [
            Color(0xFFE8EFFF),
            Color(0xFFDFF7EC),
            Color(0xFFFFF1DD),
            Color(0xFFEEE8FF),
            Color(0xFFFFE4EF),
          ]
        : const [
            Color(0xFF6B87C8),
            Color(0xFF2F9E6F),
            Color(0xFFC4842A),
            Color(0xFF6F55D8),
            Color(0xFFC43D72),
          ];
    var h = 0;
    for (final c in seed.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return soft ? palettes[h % palettes.length] : palettes[h % palettes.length];
  }

  static Color avatarInk(String seed) {
    const inks = [
      Color(0xFF6B87C8),
      Color(0xFF2F9E6F),
      Color(0xFFC4842A),
      Color(0xFF6F55D8),
      Color(0xFFC43D72),
    ];
    var h = 0;
    for (final c in seed.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return inks[h % inks.length];
  }
}
