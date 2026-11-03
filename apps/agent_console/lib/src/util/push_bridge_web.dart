// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import '../api/tongyu_api.dart';

@JS('tongyuClearPush')
external JSPromise<JSAny?> _tongyuClearPush();

@JS('tongyuDisablePush')
external JSPromise<JSAny?> _tongyuDisablePush(JSString server, JSString token);

@JS('tongyuPreparePush')
external JSPromise<JSAny?> _tongyuPreparePush(JSString server, JSString token);

@JS('tongyuPushStatus')
external JSObject _tongyuPushStatus();

@JS('tongyuEnablePush')
external JSPromise<JSAny?> _tongyuEnablePush(JSString server, JSString token);

extension type _PushStatus(JSObject _) implements JSObject {
  external JSString? get stage;
}

extension type _JsError(JSObject _) implements JSObject {
  external JSString? get message;
}

/// 推送订阅状态变化时自增，供顶部横幅等界面同步刷新。
/// 卡片开启成功后靠它让横幅立即收起，不用等下次切回页面。
final ValueNotifier<int> _pushRevision = ValueNotifier<int>(0);
Listenable get pushStateListenable => _pushRevision;
void notifyPushStateChanged() => _pushRevision.value++;

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
    await _tongyuClearPush().toDart;
  } catch (_) {}
}

Future<String> disableBackgroundPush(TongYuApi api) async {
  try {
    await _tongyuDisablePush(api.server.toJS, api.token.toJS).toDart;
    return '后台消息提醒已关闭';
  } catch (_) {
    return '关闭失败，请检查网络后重试';
  }
}

Future<bool> pushNeedsEnable(TongYuApi api) async {
  try {
    await _tongyuPreparePush(api.server.toJS, api.token.toJS).toDart;
  } catch (_) {}
  try {
    final stage = _PushStatus(_tongyuPushStatus()).stage?.toDart;
    return stage != 'enabled';
  } catch (_) {
    return true;
  }
}

Future<String> enableBackgroundPush(TongYuApi api) async {
  try {
    // 权限请求留在用户点击事件中，避免 Safari 丢失手势授权。
    final result =
        await _tongyuEnablePush(api.server.toJS, api.token.toJS).toDart;
    return result?.dartify()?.toString() ?? '已开启后台消息提醒';
  } catch (error) {
    final message = _pushErrorText(error);
    if (message.isNotEmpty) return message;
    return '未能开启。请允许浏览器通知后重试。';
  }
}

String _pushErrorText(Object error) {
  try {
    final message = _JsError(error as JSObject).message?.toDart;
    if (message != null && message.trim().isNotEmpty) return message.trim();
  } catch (_) {}
  final text = error.toString().trim();
  const prefix = 'Exception: ';
  if (text.startsWith(prefix)) return text.substring(prefix.length).trim();
  return text == 'null' ? '' : text;
}
