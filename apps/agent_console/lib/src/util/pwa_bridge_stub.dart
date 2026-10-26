import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool get browserOffline => false;

/// 原生端没有网页可见性；工作台在前台即视为可见。
bool get browserVisible => true;
Map<String, dynamic> pwaStatus() => {};
Future<String> pwaAction(String action) async => '';

/// 安卓安装包用通知 setNumber 做桌面角标；网页走 Badging API。
void setAppBadge(int count) {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  const MethodChannel('tongyu/alerts')
      .invokeMethod<void>('setBadge', {'count': count}).catchError((_) {});
}
