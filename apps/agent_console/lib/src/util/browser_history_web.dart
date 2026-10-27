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
    // 必须带上引擎认识的 flutter 标记。网页引擎只维护「来源 + 一条 flutter」；
    // 不认识的条目会再 go(-1)，同一次边缘滑动就会连退两层。
    html.window.history.pushState(
      <String, Object>{
        'flutter': true,
        'tongyuNav': name,
        'depth': _depth + 1,
      },
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
    // 引擎看到这条后退还会再发一次 popRoute / pushRoute，用计数把那一次吃掉。
    _ignoreNextPop = true;
    _suppressEnginePops += 1;
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
      // 先占对账名额：pop 的 whenComplete 可能紧跟这次监听，
      // 若等回调返回再加，会误补一次 history.back，视觉上再退一层。
      _reconcilePops += 1;
      // 引擎的 popRoute / pushRoute 是异步平台消息，比这次 popstate 晚到。
      // 同一次手势里后到的那条不能再卸一层。
      if (!claimSingleBrowserPop()) return;
      _suppressEnginePops += 1;
      if (!onBrowserBack()) {
        _reconcilePops -= 1;
        if (_suppressEnginePops > 0) _suppressEnginePops -= 1;
      }
    });
  }
}

/// 按钮返回的 history.back，以及手势已经卸过的那一层，都会让网页引擎再发一次路由消息。
/// 每记一次，引擎消息到来时减一，避免同一下再卸一层。
int _suppressEnginePops = 0;

/// 吃掉一次「引擎跟着 history.back 再弹/再推」的消息。没有待吃的返回 false。
bool consumeBrowserEnginePopSuppression() {
  if (_suppressEnginePops <= 0) return false;
  _suppressEnginePops -= 1;
  return true;
}

bool _popThisTurn = false;

/// 同一次手势里网页引擎和本页监听都会收到返回。先到的卸一层，后到的放过。
bool claimSingleBrowserPop() {
  if (_popThisTurn) return false;
  _popThisTurn = true;
  scheduleMicrotask(() => _popThisTurn = false);
  return true;
}
