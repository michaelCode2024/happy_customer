import 'dart:async';

import 'package:flutter/material.dart';

/// 可由浏览器历史返回（iOS 书签包边缘手势、浏览器后退）弹出的页面路由。
///
/// popstate 到达前系统已经播过一次滑动返回动画，Flutter 再按默认时长 pop
/// 会让用户看到第二次返回动画。[popFromBrowser] 把反向转场时长临时置零、
/// 瞬时收掉本层；页内返回按钮仍走普通 pop，保留原有动画。
/// 不用 removeRoute：Web 上它跳过 ModalRoute 收尾，会留下挡点击的残层。
class BrowserBackPageRoute<T> extends MaterialPageRoute<T> {
  BrowserBackPageRoute({required super.builder, super.settings});

  /// 浏览器历史已经走掉一条，这里只瞬时卸掉对应页面，不再播动画。
  void popFromBrowser() {
    final transition = controller;
    if (transition == null) {
      navigator?.maybePop();
      return;
    }
    // 反向时长是 AnimationController 创建时按 reverseTransitionDuration 定的，
    // 事后改 route.reverseDuration 不会影响这个 controller，仍会播满 300ms。
    final previous = transition.reverseDuration;
    transition.reverseDuration = Duration.zero;
    unawaited(navigator?.maybePop().then((popped) {
      // 被 PopScope 拦下时恢复时长，之后的按钮返回仍有动画。
      if (!popped) transition.reverseDuration = previous;
    }));
  }
}
