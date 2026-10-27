import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 应用只消费一次底部安全距离，子页面和导航栏不再各自叠加。
class AppSafeArea extends StatelessWidget {
  const AppSafeArea({super.key, required this.child, this.browserBottom = 0});
  final Widget child;
  final double browserBottom;

  /// 需要让出的底部高度。外层补色和这里必须用同一个值，否则色带会差几像素。
  static double resolveBottom(MediaQueryData media, double browserBottom) =>
      media.viewInsets.bottom > 0
          ? 0.0
          : math.max(media.padding.bottom, browserBottom);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottom = resolveBottom(media, browserBottom);
    return MediaQuery(
      data: media.copyWith(
          padding: media.padding.copyWith(bottom: bottom),
          viewPadding: media.viewPadding.copyWith(
              bottom: math.max(media.viewPadding.bottom, browserBottom))),
      child: SafeArea(top: false, left: false, right: false, child: child),
    );
  }
}
