import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 只把底部安全距离写进 MediaQuery，不把每个页面整体上移。
///
/// Home 条那一截由贴底的导航栏、输入栏自己画进背景里。键盘弹起时改为 0，
/// 避免和 viewInsets 叠成两段空白。
class AppSafeArea extends StatelessWidget {
  const AppSafeArea({super.key, required this.child, this.browserBottom = 0});
  final Widget child;
  final double browserBottom;

  /// 贴底栏应让出的高度。键盘弹起时为 0。
  static double resolveBottom(MediaQueryData media, double browserBottom) =>
      media.viewInsets.bottom > 0
          ? 0.0
          : math.max(media.padding.bottom, browserBottom);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottom = resolveBottom(media, browserBottom);
    final physical = media.viewInsets.bottom > 0
        ? 0.0
        : math.max(media.viewPadding.bottom, browserBottom);
    return MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(bottom: bottom),
        viewPadding: media.viewPadding.copyWith(bottom: physical),
      ),
      child: child,
    );
  }
}
