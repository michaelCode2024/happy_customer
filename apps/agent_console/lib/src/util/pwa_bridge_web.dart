// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:js_util' as js;
import 'dart:convert';

bool get browserOffline => html.window.navigator.onLine == false;

/// 页面是否正被用户看着。服务端据此跳过推送，避免盯屏时手机重复响。
bool get browserVisible => html.document.visibilityState == 'visible';
Map<String, dynamic> pwaStatus() {
  try {
    return Map<String, dynamic>.from(
        jsonDecode(js.callMethod<String>(html.window, 'tongyuPwaStatus', []))
            as Map);
  } catch (_) {
    return {};
  }
}

Future<String> pwaAction(String action) async {
  try {
    final result = await js.promiseToFuture<Object?>(
        js.callMethod(html.window, 'tongyuPwaAction', [action]));
    return result?.toString() ?? '';
  } catch (_) {
    return '操作未完成，请检查网络或浏览器设置后重试';
  }
}

void setAppBadge(int count) {
  try {
    js.callMethod(html.window, 'tongyuSetBadge', [count]);
  } catch (_) {}
}
