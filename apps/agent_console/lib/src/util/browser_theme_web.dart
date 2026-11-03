// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:js_interop';

import 'package:web/web.dart' as web;

@JS('tongyuSyncTheme')
external JSFunction? get _tongyuSyncTheme;

String _hex(int rgb) =>
    '#${(rgb & 0xffffff).toRadixString(16).padLeft(6, '0')}';

/// 网页底色与底部安全区用页面底色。顶栏可以另给颜色，登录蓝头滚走后要换回浅色。
/// 底部安全区若已有贴底栏，必须用栏的颜色，不能再用页面底色。
void syncBrowserTheme(int rgb, bool dark, {int? topRgb, int? bottomRgb}) {
  final color = _hex(rgb);
  final top = _hex(topRgb ?? rgb);
  // 没有贴底栏时传空串，网页不要用页面底色去盖 Home 条。
  final bottom = bottomRgb == null ? '' : _hex(bottomRgb);
  final sync = _tongyuSyncTheme;
  if (sync != null) {
    sync.callAsFunction(
        web.window, color.toJS, dark.toJS, top.toJS, bottom.toJS);
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
