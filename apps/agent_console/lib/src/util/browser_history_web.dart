// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;

/// Web / PWA：把 Flutter 路由叠层同步进 History，让 iPhone 边缘滑动与安卓返回键一致。
///
/// 只在我们主动 pushState 的层数内处理 popstate，避免误吞站外历史。
class BrowserHistoryGate {
  int _depth = 0;
  bool _consumingBrowserPop = false;
  bool _ignoreNextPop = false;

  void push(String name) {
    // state 带上标记，便于区分本应用压栈与外站历史。
    html.window.history.pushState(
      <String, Object>{'tongyuNav': name, 'depth': _depth + 1},
      '',
      html.window.location.href,
    );
    _depth += 1;
  }

  void syncAfterLocalPop() {
    if (_consumingBrowserPop) return;
    if (_depth <= 0) return;
    _depth -= 1;
    // 页面按钮返回时补一次 history.back；紧随其后的 popstate 只对账、不再弹路由。
    _ignoreNextPop = true;
    html.window.history.back();
  }

  /// 卸掉本门闸压过的全部 History（切底栏卸会话页时用），避免留下幽灵条目让下次边缘滑动退出控制台。
  void drain() {
    while (_depth > 0) {
      syncAfterLocalPop();
    }
  }

  StreamSubscription<void> listen(void Function() onBrowserBack) {
    return html.window.onPopState.listen((_) {
      if (_ignoreNextPop) {
        _ignoreNextPop = false;
        return;
      }
      if (_depth <= 0) return;
      _depth -= 1;
      _consumingBrowserPop = true;
      try {
        onBrowserBack();
      } finally {
        _consumingBrowserPop = false;
      }
    });
  }
}
