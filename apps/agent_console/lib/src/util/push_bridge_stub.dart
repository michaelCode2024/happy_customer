import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../api/tongyu_api.dart';

final _conversationEvents = StreamController<String>.broadcast();
Stream<String> notificationConversationEvents() {
  if (defaultTargetPlatform != TargetPlatform.android)
    return const Stream.empty();
  const MethodChannel('tongyu/alerts').setMethodCallHandler((call) async {
    if (call.method == 'conversation' && call.arguments is String)
      _conversationEvents.add(call.arguments as String);
  });
  return _conversationEvents.stream;
}

Future<String?> initialNotificationConversation() async {
  if (defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    return await const MethodChannel('tongyu/alerts')
        .invokeMethod<String>('initialConversation');
  } catch (_) {
    return null;
  }
}

Future<String> disableBackgroundPush(TongYuApi api) async {
  await disableBackgroundAlerts();
  return '后台接待提醒已关闭';
}

Future<void> disableBackgroundAlerts() async {
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      await const MethodChannel('tongyu/alerts')
          .invokeMethod<void>('disableBackground');
    } catch (_) {}
  }
}

/// 安卓安装包：本机轮询值班（非 FCM）。iOS 请用 PWA / 浏览器通知。
Future<String> enableBackgroundPush(TongYuApi api) async {
  if (defaultTargetPlatform != TargetPlatform.android) {
    return '此设备请使用网页版（PWA）开启浏览器通知';
  }
  try {
    return await const MethodChannel('tongyu/alerts').invokeMethod<String>(
            'enableBackground',
            {'server': api.server, 'token': api.token}) ??
        '安卓本机消息提醒已开启（进程内轮询，非云推送）';
  } catch (_) {
    return '后台提醒未开启，请允许系统通知权限后重试';
  }
}
