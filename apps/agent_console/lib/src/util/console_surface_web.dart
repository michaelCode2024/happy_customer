// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
String? loadTabConsoleSurface() {
  final explicit = Uri.base.queryParameters['surface'];
  if (explicit == 'agent' || explicit == 'platform') return explicit;
  try { return html.window.sessionStorage['liaoqiao.consoleSurface']; } catch (_) { return null; }
}
void saveTabConsoleSurface(String value) {
  try { html.window.sessionStorage['liaoqiao.consoleSurface'] = value; } catch (_) {}
}
