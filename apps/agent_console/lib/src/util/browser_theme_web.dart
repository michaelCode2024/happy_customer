// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:js_util' as js;

String _hex(int rgb) =>
    '#${(rgb & 0xffffff).toRadixString(16).padLeft(6, '0')}';

/// 网页底色与底部安全区用页面底色。顶栏可以另给颜色，登录蓝头滚走后要换回浅色。
void syncBrowserTheme(int rgb, bool dark, {int? topRgb}) {
  final color = _hex(rgb);
  final top = _hex(topRgb ?? rgb);
  if (js.hasProperty(html.window, 'tongyuSyncTheme')) {
    js.callMethod(html.window, 'tongyuSyncTheme', [color, dark, top]);
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

void markAppReady() =>
    html.window.dispatchEvent(html.CustomEvent('tongyu-app-ready'));
