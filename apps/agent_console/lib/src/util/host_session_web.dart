// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';

import 'package:web/web.dart' as web;

@JS('flutter_inappwebview')
external JSObject? get _flutterInAppWebView;

@JS('__tongyuHostIdentity')
external JSObject? get _tongyuHostIdentity;

@JS('__tongyuHostIdentity')
external set _tongyuHostIdentity(JSObject? value);

extension type _InAppWebView(JSObject _) implements JSObject {
  external void callHandler(JSString handlerName, JSString args);
}

extension type _HostCredentials(JSObject _) implements JSObject {
  external JSString? get identityToken;
}

bool get isHostedConsole => Uri.base.queryParameters['embedded'] == '1';
void closeHostedConsole() {
  final origin = Uri.base.queryParameters['parentOrigin'];
  final event = {'source': 'tongyu', 'type': 'close'};
  if (origin != null && origin != '*') {
    html.window.parent?.postMessage(event, origin);
  } else {
    final bridge = _flutterInAppWebView;
    if (bridge != null) {
      _InAppWebView(bridge)
          .callHandler('tongyuHost'.toJS, jsonEncode(event).toJS);
    }
  }
}

Stream<String> hostSessions() {
  final stream = StreamController<String>();
  final origin = Uri.base.queryParameters['parentOrigin'];
  JSFunction? listener;
  stream.onListen = () {
    if (!isHostedConsole) return;
    if (origin != null && origin != '*') {
      void onMessage(web.Event raw) {
        final event = raw as web.MessageEvent;
        final parent = web.window.parent;
        if (event.origin != origin ||
            parent == null ||
            event.source != parent) {
          return;
        }
        try {
          final rawData = event.data?.dartify();
          final data = rawData is String ? jsonDecode(rawData) : rawData;
          if (data is Map &&
              data['type'] == 'authenticate' &&
              data['identityToken'] is String) {
            stream.add(data['identityToken'] as String);
          }
        } catch (_) {}
      }

      listener = onMessage.toJS;
      web.window.addEventListener('message', listener);
      html.window.parent
          ?.postMessage({'source': 'tongyu', 'type': 'host-ready'}, origin);
    } else {
      final credentials = _tongyuHostIdentity;
      if (credentials != null) {
        final token = _HostCredentials(credentials).identityToken?.toDart;
        if (token != null) stream.add(token);
        _tongyuHostIdentity = null;
      }
    }
  };
  stream.onCancel = () {
    final current = listener;
    if (current != null) web.window.removeEventListener('message', current);
  };
  return stream.stream;
}

// 仅定位业务宿主指定的会话；详情及消息仍由服务端校验租户和渠道权限。
String? get hostConversationId {
  final id = Uri.base.queryParameters['conversationId'] ??
      Uri.base.queryParameters['conversation'];
  return id != null && RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id) ? id : null;
}
