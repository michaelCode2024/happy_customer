// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:js_util' as js;

/// 网页底色、安全区域与 Flutter 使用同一个主题表面色，不能写死白色。
void syncBrowserTheme(int rgb, bool dark) {
  final color = '#${(rgb & 0xffffff).toRadixString(16).padLeft(6, '0')}';
  if (js.hasProperty(html.window, 'tongyuSyncTheme')) {
    js.callMethod(html.window, 'tongyuSyncTheme', [color, dark]);
  }
}

/// iOS 网页引擎可能不把 CSS 安全距离传给 MediaQuery，补齐后交由 Flutter 统一消费。
html.DivElement? _safeAreaProbe;
double get browserSafeBottom {
  final body = html.document.body;
  if (body == null) return 0;
  final probe = _safeAreaProbe ??= html.DivElement()
    ..style.cssText =
        'position:fixed;visibility:hidden;pointer-events:none;padding-bottom:env(safe-area-inset-bottom,0px)';
  if (probe.parent == null) body.append(probe);
  final raw = probe.getComputedStyle().paddingBottom;
  return double.tryParse(raw.replaceAll('px', '')) ?? 0;
}

void markAppReady() => html.window.dispatchEvent(html.CustomEvent('tongyu-app-ready'));
