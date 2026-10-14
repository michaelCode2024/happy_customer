// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

String? loadTabConsoleSurface() {
  final explicit = Uri.base.queryParameters['surface'];
  if (explicit == 'agent' || explicit == 'platform') return explicit;
  try {
    return html.window.sessionStorage['liaoqiao.consoleSurface'];
  } catch (_) {
    return null;
  }
}

void saveTabConsoleSurface(String value) {
  try {
    html.window.sessionStorage['liaoqiao.consoleSurface'] = value;
  } catch (_) {}
  // 官网显式指定企业/平台入口；页内切换时同步 URL，刷新后仍回到用户选择的门面。
  if (value == 'agent' || value == 'platform') {
    final uri = Uri.base;
    final query = Map<String, String>.from(uri.queryParameters)
      ..['surface'] = value;
    html.window.history
        .replaceState(null, '', uri.replace(queryParameters: query).toString());
  }
}
