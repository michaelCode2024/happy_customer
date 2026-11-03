// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';

@JS('tongyuPwaStatus')
external JSString _tongyuPwaStatus();

@JS('tongyuPwaAction')
external JSPromise<JSAny?> _tongyuPwaAction(JSString action);

@JS('tongyuSetBadge')
external void _tongyuSetBadge(JSNumber count);

bool get browserOffline => html.window.navigator.onLine == false;

/// 页面是否正被用户看着。推送不因人在看工作台而延后。
bool get browserVisible => html.document.visibilityState == 'visible';
Map<String, dynamic> pwaStatus() {
  try {
    return Map<String, dynamic>.from(
        jsonDecode(_tongyuPwaStatus().toDart) as Map);
  } catch (_) {
    return {};
  }
}

Future<String> pwaAction(String action) async {
  try {
    final result = await _tongyuPwaAction(action.toJS).toDart;
    return result?.dartify()?.toString() ?? '';
  } catch (_) {
    return '操作未完成，请检查网络或浏览器设置后重试';
  }
}

void setAppBadge(int count) {
  try {
    _tongyuSetBadge(count.toJS);
  } catch (_) {}
}
