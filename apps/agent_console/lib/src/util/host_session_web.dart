// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js;

bool get isHostedConsole => Uri.base.queryParameters['embedded'] == '1';
void closeHostedConsole() {
  final origin = Uri.base.queryParameters['parentOrigin'];
  final event = {'source': 'tongyu', 'type': 'close'};
  if (origin != null && origin != '*') {
    html.window.parent?.postMessage(event, origin);
  } else if (js.hasProperty(html.window, 'flutter_inappwebview')) {
    final bridge = js.getProperty<Object>(html.window, 'flutter_inappwebview');
    js.callMethod<Object?>(
        bridge, 'callHandler', ['tongyuHost', jsonEncode(event)]);
  }
}

Stream<String> hostSessions() {
  final stream = StreamController<String>();
  final origin = Uri.base.queryParameters['parentOrigin'];
  StreamSubscription<html.MessageEvent>? listener;
  stream.onListen = () {
    if (!isHostedConsole) return;
    if (origin != null && origin != '*') {
      listener = html.window.onMessage.listen((event) {
        if (event.origin != origin ||
            !js.callMethod<bool>(js.getProperty(html.window, 'Object'), 'is', [
              js.getProperty(event, 'source'),
              js.getProperty(html.window, 'parent')
            ])) return;
        try {
          final data =
              event.data is String ? jsonDecode(event.data) : event.data;
          if (data is Map &&
              data['type'] == 'authenticate' &&
              data['identityToken'] is String)
            stream.add(data['identityToken'] as String);
        } catch (_) {}
      });
      html.window.parent
          ?.postMessage({'source': 'tongyu', 'type': 'host-ready'}, origin);
    } else if (js.hasProperty(html.window, '__tongyuHostIdentity')) {
      final credentials =
          js.getProperty<Object?>(html.window, '__tongyuHostIdentity');
      if (credentials != null) {
        final token = js.getProperty<Object?>(credentials, 'identityToken');
        if (token is String) stream.add(token);
      }
      js.setProperty(html.window, '__tongyuHostIdentity', null);
    }
  };
  stream.onCancel = () => listener?.cancel();
  return stream.stream;
}

// 仅定位业务宿主指定的会话；详情及消息仍由服务端校验租户和渠道权限。
String? get hostConversationId {
  final id = Uri.base.queryParameters['conversationId'] ?? Uri.base.queryParameters['conversation'];
  return id != null &&
          RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id)
      ? id
      : null;
}
