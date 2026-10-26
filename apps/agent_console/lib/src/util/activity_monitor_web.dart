// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:js_util' as js_util;

/// 标签页可见且浏览器窗口有焦点，才算「人在看工作台」。
/// 只看可见性不够：坐席切去别的应用、标签页还露着，那也算离开。
/// dart:html 的 Document 没有 hasFocus，跟桌面通知同一套 JS 调用；调用失败时只看可见性。
bool get viewingWorkbench {
  if (html.document.visibilityState != 'visible') return false;
  try {
    return js_util.callMethod(html.document, 'hasFocus', []) as bool? ?? true;
  } catch (_) {
    return true;
  }
}

final List<StreamSubscription<html.Event>> _subscriptions = [];
void Function(bool viewing)? _listener;

void startActivityMonitor(void Function(bool viewing) onChange) {
  stopActivityMonitor();
  _listener = onChange;
  void emit(html.Event _) => _listener?.call(viewingWorkbench);
  _subscriptions.addAll(<StreamSubscription<html.Event>>[
    html.document.onVisibilityChange.listen(emit),
    html.window.onFocus.listen(emit),
    html.window.onBlur.listen(emit),
  ]);
  scheduleMicrotask(() => _listener?.call(viewingWorkbench));
}

void stopActivityMonitor() {
  for (final subscription in _subscriptions) {
    subscription.cancel();
  }
  _subscriptions.clear();
  _listener = null;
}
