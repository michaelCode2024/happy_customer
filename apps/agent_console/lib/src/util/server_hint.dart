import 'package:flutter/foundation.dart';

String initialServerHint(String saved, {bool? web, Uri? location}) {
  if (saved.isNotEmpty) {
    return saved;
  }
  const defined = String.fromEnvironment('TONGYU_SERVER', defaultValue: '');
  if (defined.isNotEmpty) {
    return defined;
  }
  final onWeb = web ?? kIsWeb;
  if (!onWeb) {
    // 安装包没有页面来源。未传 dart-define 时连线上；本机联调自行传入 TONGYU_SERVER。
    return 'https://chat.lookfunny.xyz';
  }
  final page = location ?? Uri.base;
  // Flutter web-server preview hosts UI on :8092; API is a different origin.
  if ((page.host == 'localhost' || page.host == '127.0.0.1') &&
      page.port != 18790) {
    return 'http://127.0.0.1:18790';
  }
  return page.scheme == 'http' || page.scheme == 'https' ? page.origin : '';
}
