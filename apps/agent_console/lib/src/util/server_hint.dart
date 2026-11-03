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
    // 安装包没有页面来源。未传 TONGYU_SERVER 时默认线上地址。
    return 'https://chat.lookfunny.xyz';
  }
  final page = location ?? Uri.base;
  // 工作台预览固定在 :8094。用户端 H5 用 :8091，店主端用 :8092，不要互相占用。
  // 本机 API 是另一个源。
  if ((page.host == 'localhost' || page.host == '127.0.0.1') &&
      page.port != 18790) {
    return 'http://127.0.0.1:18790';
  }
  return page.scheme == 'http' || page.scheme == 'https' ? page.origin : '';
}
