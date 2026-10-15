// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:js_util' as js;
import '../api/relaydesk_api.dart';

Stream<String> notificationConversationEvents() =>
    html.window.navigator.serviceWorker?.onMessage
        .where((event) =>
            event.data is Map &&
            event.data['type'] == 'OPEN_CONVERSATION' &&
            event.data['id'] is String)
        .map((event) => event.data['id'] as String) ??
    const Stream.empty();
Future<String?> initialNotificationConversation() async =>
    Uri.base.queryParameters['conversation'];

Future<void> disableBackgroundAlerts() async {
  try {
    await js.promiseToFuture<Object?>(
        js.callMethod(html.window, 'tongyuClearPush', []));
  } catch (_) {}
}

Future<String> disableBackgroundPush(RelayDeskApi api) async {
  try {
    await js.promiseToFuture<Object?>(js
        .callMethod(html.window, 'tongyuDisablePush', [api.server, api.token]));
    return '后台消息提醒已关闭';
  } catch (_) {
    return '关闭失败，请检查网络后重试';
  }
}

Future<String> enableBackgroundPush(RelayDeskApi api) async {
  try {
    // 权限请求留在用户点击事件中，避免 Safari 丢失手势授权。
    final result = await js.promiseToFuture<Object?>(js
        .callMethod(html.window, 'tongyuEnablePush', [api.server, api.token]));
    return result?.toString() ?? '已开启后台消息提醒';
  } catch (_) {
    return '未能开启。请使用 HTTPS，在 iPhone 上先添加到主屏幕，再允许通知。';
  }
}
