// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;

/// Web / PWA：把 Flutter 路由叠层同步进 History，让 iPhone 边缘滑动与安卓返回键一致。
///
/// 只在我们主动 pushState 的层数内处理 popstate，避免误吞站外历史。
class BrowserHistoryGate {
  int _depth = 0;

  /// popstate 已带走浏览器历史、等待本地 pop 完成对账的层数。
  /// pop 的 whenComplete 跑在 popstate 监听器之后（微任务），布尔守卫接不住，
  /// 用计数才能保证手势弹掉的那层不再补一次 history.back。
  int _reconcilePops = 0;
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
    if (_reconcilePops > 0) {
      // 这层是浏览器返回弹掉的，历史已经走掉，再补 back 会多退一条真实历史。
      _reconcilePops -= 1;
      return;
    }
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

  /// [onBrowserBack] 返回是否真的发起了本地 pop；只有发起了才登记对账层，
  /// 否则后续按钮返回会漏补 history.back。
  StreamSubscription<void> listen(bool Function() onBrowserBack) {
    return html.window.onPopState.listen((_) {
      if (_ignoreNextPop) {
        _ignoreNextPop = false;
        return;
      }
      if (_depth <= 0) return;
      _depth -= 1;
      if (onBrowserBack()) _reconcilePops += 1;
    });
  }
}
