import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 应用只消费一次底部安全距离，子页面和导航栏不再各自叠加。
class AppSafeArea extends StatelessWidget {
  const AppSafeArea({super.key, required this.child, this.browserBottom = 0});
  final Widget child;
  final double browserBottom;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottom = media.viewInsets.bottom > 0
        ? 0.0
        : math.max(media.padding.bottom, browserBottom);
    return MediaQuery(
      data: media.copyWith(
          padding: media.padding.copyWith(bottom: bottom),
          viewPadding: media.viewPadding.copyWith(
              bottom: math.max(media.viewPadding.bottom, browserBottom))),
      child: SafeArea(top: false, left: false, right: false, child: child),
    );
  }
}
