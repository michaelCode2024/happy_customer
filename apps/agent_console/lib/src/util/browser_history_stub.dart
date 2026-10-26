import 'dart:async';

/// 非 Web：系统返回由 Flutter Navigator / 系统返回键处理，不需要 History API。
class BrowserHistoryGate {
  const BrowserHistoryGate();

  /// 打开一层可后退的页面（如手机会话详情）。
  void push(String name) {}

  /// 本地 Navigator 已弹出时，把浏览器历史对齐回去，避免下次边缘滑动空退。
  void syncAfterLocalPop() {}

  /// 非 Web 无 History 可卸，留空实现与 Web 对称。
  void drain() {}

  /// 监听浏览器 / iOS PWA 边缘返回；返回的订阅在 dispose 时取消。
  StreamSubscription<void> listen(void Function() onBrowserBack) =>
      const Stream<void>.empty().listen((_) {});
}
