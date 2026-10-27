import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 浏览器手势已经滑过一次。这里只留一帧把路由收掉，避免再播一整段返回。
///
/// 用 0 会在 [Navigator] 正在处理 pop 的同一次 flush 里同步进入 dismissed，
/// 路由来不及真正卸掉，残层还在，看起来就像又退了一次。
const Duration browserPopReverseDuration = Duration(milliseconds: 1);

/// 可由浏览器历史返回（iOS 书签包边缘手势、浏览器后退）弹出的页面路由。
///
/// popstate 到达前系统已经播过一次滑动返回动画，Flutter 再按默认时长 pop
/// 会让用户看到第二次返回动画。[popFromBrowser] 只收掉本层，不再播这段转场；
/// 页内返回按钮仍走普通 pop，保留原有动画。
/// 不用 removeRoute：Web 上它跳过 ModalRoute 收尾，会留下挡点击的残层。
class BrowserBackPageRoute<T> extends MaterialPageRoute<T> {
  BrowserBackPageRoute({required super.builder, super.settings});

  bool _snapOff = false;

  /// 网页上边缘滑动交给浏览器历史。Flutter 自己的返回手势再播一次，看起来就是退了两下。
  @override
  bool get popGestureEnabled => kIsWeb ? false : super.popGestureEnabled;

  /// [MaterialPageRoute.didPop] 会用这个时长覆盖 controller.reverseDuration，
  /// 事先改 controller 会被盖掉，仍播完整转场。
  @override
  Duration get reverseTransitionDuration =>
      _snapOff ? browserPopReverseDuration : super.reverseTransitionDuration;

  /// 浏览器历史已经走掉一条，这里只瞬时卸掉对应页面，不再播动画。
  void popFromBrowser() {
    _snapOff = true;
    final transition = controller;
    unawaited(navigator?.maybePop().then((_) {
      finishBrowserPop(transition);
      if (isCurrent) _snapOff = false;
    }));
  }
}

/// 把已经开始的返回转场收到终点。
///
/// 必须等 [Navigator.pop] 这次 flush 结束再收。收得太早（时长为 0）时，
/// 路由还算在栈上，dismissed 不会触发卸层，页面会留在树上。
void finishBrowserPop(AnimationController? transition) {
  if (transition == null) return;
  if (transition.status != AnimationStatus.reverse) return;
  transition.value = transition.lowerBound;
}

/// 网页引擎的系统返回：浏览器已经播过滑动，这里只卸当前页，不再播第二段转场。
Future<bool> popNavigatorWithoutTransition(NavigatorState navigator) {
  if (!navigator.canPop()) return Future<bool>.value(false);
  ModalRoute<dynamic>? top;
  navigator.popUntil((route) {
    top = route is ModalRoute<dynamic> ? route : null;
    return true;
  });
  final route = top;
  if (route is BrowserBackPageRoute<dynamic>) {
    route._snapOff = true;
  }
  final controller = route?.controller;
  return navigator.maybePop().then((popped) {
    finishBrowserPop(controller);
    if (route is BrowserBackPageRoute<dynamic> && route.isCurrent) {
      route._snapOff = false;
    }
    return popped;
  });
}

/// iOS 网页默认的 Cupertino 转场自带边缘手势。PWA 的边缘滑动已经由浏览器历史接管，
/// 这里只保留按钮返回的滑动，不再挂第二套手势。
class WebSlideTransitionsBuilder extends PageTransitionsBuilder {
  const WebSlideTransitionsBuilder();

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      CupertinoPageTransition.delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return CupertinoPageTransition(
      primaryRouteAnimation: animation,
      secondaryRouteAnimation: secondaryAnimation,
      linearTransition: false,
      child: child,
    );
  }
}
