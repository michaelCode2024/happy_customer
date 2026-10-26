import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// 只有 FontLoader 真正成功时才为 true。
final ValueNotifier<bool> webEmojiFontReady = ValueNotifier<bool>(!kIsWeb);

/// 本轮加载结束（成功或放弃），避免失败后 UI 永久等待。
final ValueNotifier<bool> webEmojiFontSettled = ValueNotifier<bool>(!kIsWeb);

bool _webEmojiFontLoading = false;
int _webEmojiFontFailCount = 0;

const List<String> kWebEmojiFontFallback = <String>['ChatEmoji'];

List<String>? get kWebEmojiFontFallbackOrNull =>
    kIsWeb ? kWebEmojiFontFallback : null;

TextStyle withWebEmojiFallback(TextStyle style) {
  if (!kIsWeb) return style;
  final existing = style.fontFamilyFallback;
  if (existing != null && existing.contains('ChatEmoji')) return style;
  return style.copyWith(fontFamilyFallback: kWebEmojiFontFallback);
}

Future<void> ensureWebEmojiFont() async {
  if (!kIsWeb || webEmojiFontReady.value || _webEmojiFontLoading) {
    return;
  }
  _webEmojiFontLoading = true;
  webEmojiFontSettled.value = false;
  try {
    final response =
        await http.get(Uri.base.resolve('fonts/NotoColorEmoji.ttf'));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('表情字体 HTTP ${response.statusCode}');
    }
    if (response.bodyBytes.isEmpty) {
      throw StateError('表情字体为空');
    }
    final loader = FontLoader('ChatEmoji')
      ..addFont(Future<ByteData>.value(
          ByteData.sublistView(response.bodyBytes)));
    await loader.load();
    _webEmojiFontFailCount = 0;
    webEmojiFontReady.value = true;
    webEmojiFontSettled.value = true;
  } catch (e) {
    _webEmojiFontFailCount += 1;
    debugPrint('表情字体加载失败($_webEmojiFontFailCount): $e');
    if (_webEmojiFontFailCount >= 3) {
      webEmojiFontSettled.value = true;
    }
  } finally {
    _webEmojiFontLoading = false;
  }
}

Widget wrapWithWebEmojiFallback(Widget child) {
  if (!kIsWeb) return child;
  return DefaultTextStyle.merge(
    style: const TextStyle(fontFamilyFallback: kWebEmojiFontFallback),
    child: child,
  );
}
