import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/theme.dart';
import 'package:tongyu_agent_console/src/ui/error_banner.dart';

/// 代码块的语言，只用来选 tokenizer 和左上角的徽标。
enum CodeLanguage {
  html('HTML'),
  javascript('JavaScript'),
  plain('');

  const CodeLanguage(this.label);

  final String label;
}

/// 同一段接入逻辑的不同贴法。选中哪个 tab 就复制哪一份代码。
class CodeVariant {
  const CodeVariant({
    required this.label,
    required this.code,
    this.language = CodeLanguage.html,
  });

  final String label;
  final String code;
  final CodeLanguage language;
}

/// 控制台里的代码块。
///
/// 全站表面都是白卡，只有这里落深色：代码要在一屏里被立刻认出「这是代码，
/// 不是一段要复制的字符串」。靠底色区分比靠描边和等宽字直接得多——改版前
/// 安装代码和上面的入口公钥长得一模一样，读起来像又一个值块。
///
/// 代码不折行，横向滚动。窄屏折行会把 `data-inbox-key="..."` 从中间断开，
/// 看着像坏掉的片段。
class ConsoleCodeBlock extends StatefulWidget {
  const ConsoleCodeBlock({
    super.key,
    this.code = '',
    this.language = CodeLanguage.html,
    this.variants,
    this.emphasis = const <String>[],
    this.copyLabel = '代码',
    this.showLineNumbers = true,
  });

  final String code;
  final CodeLanguage language;

  /// 多贴法时优先于 [code]：顶部渲染成一组 tab。
  final List<CodeVariant>? variants;

  /// 需要点出来「这个值要换成你自己的」的片段，用琥珀色点线下划线标出。
  final List<String> emphasis;

  /// 复制成功提示里的名字，例如「安装代码」。
  final String copyLabel;

  final bool showLineNumbers;

  @override
  State<ConsoleCodeBlock> createState() => _ConsoleCodeBlockState();
}

class _ConsoleCodeBlockState extends State<ConsoleCodeBlock> {
  static const Color _bg = Color(0xFF0F172A);
  static const Color _fg = Color(0xFFE2E8F0);
  static const Color _comment = Color(0xFF64748B);
  static const Color _tag = Color(0xFF7DD3FC);
  static const Color _attr = Color(0xFFC4B5FD);
  static const Color _string = Color(0xFF86EFAC);
  static const Color _punct = Color(0xFF64748B);
  static const Color _keyword = Color(0xFFF0ABFC);
  static const Color _number = Color(0xFFFDE68A);
  static const Color _emphasis = Color(0xFFFDE68A);
  static const Color _gutterInk = Color(0xFF4E5C74);
  static const Color _hairline = Color(0x14FFFFFF);

  static const double _fontSize = 11.5;
  static const double _lineHeight = 21;

  Timer? _reset;
  bool _copied = false;
  int _variant = 0;

  /// 当前选中的那份代码。没有 variants 时就是 [ConsoleCodeBlock.code]。
  CodeVariant get _active {
    final list = widget.variants;
    if (list == null || list.isEmpty) {
      return CodeVariant(
          label: widget.language.label,
          code: widget.code,
          language: widget.language);
    }
    return list[_variant < list.length ? _variant : 0];
  }

  @override
  void didUpdateWidget(covariant ConsoleCodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_variant >= (widget.variants?.length ?? 0)) _variant = 0;
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await copyToClipboard(context, _active.code, widget.copyLabel);
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    final code = active.code;
    final tokens = _tokenize(code, active.language);
    final lines = code.isEmpty ? 0 : '\n'.allMatches(code).length + 1;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(RelayTheme.radiusMd),
        border: Border.all(color: _hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
        _header(),
        if (code.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
            child: Text('当前入口暂未提供该渠道的接入内容。',
                style: RelayTheme.codeText(
                    fontSize: 11.5, height: 1.7, color: _comment)),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.showLineNumbers) _gutter(lines),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(right: 16),
                    child: SelectableText.rich(
                      TextSpan(
                          children: [
                            for (final token in tokens) ..._spans(token)
                          ]),
                      style: RelayTheme.codeText(
                          fontSize: _fontSize,
                          height: _lineHeight / _fontSize,
                          color: _fg),
                      cursorColor: _tag,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ]),
    );
  }

  Widget _header() => Container(
        height: 36,
        padding: const EdgeInsets.only(left: 12, right: 7),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: _hairline)),
        ),
        child: Row(children: [
          Expanded(child: _tabs()),
          _copyButton(),
        ]),
      );

  /// 多贴法渲染成一组 tab；只有一种贴法时退回一个静态语言徽标。
  Widget _tabs() {
    final list = widget.variants;
    if (list == null || list.isEmpty) {
      if (widget.language.label.isEmpty) return const SizedBox.shrink();
      return Align(
          alignment: Alignment.centerLeft,
          child: _chip(widget.language.label, true));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (var i = 0; i < list.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => setState(() {
                _variant = i;
                _copied = false;
              }),
              child: _chip(list[i].label, i == _variant),
            ),
          ),
      ]),
    );
  }

  Widget _chip(String label, bool selected) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? const Color(0x17FFFFFF) : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: RelayTheme.codeText(
                fontSize: 11, height: 1.4, color: selected ? _fg : _comment)),
      );

  Widget _copyButton() => Semantics(
        button: true,
        label: _copied ? '已复制' : '复制${widget.copyLabel}',
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: _active.code.isEmpty ? null : _copy,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: _copied ? const Color(0x4D12B886) : _hairline),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(_copied ? Icons.check_rounded : Icons.copy_rounded,
                  size: 12, color: _copied ? _string : const Color(0xFFCBD5E1)),
              const SizedBox(width: 5),
              Text(_copied ? '已复制' : '复制',
                  style: RelayTheme.codeText(
                      fontSize: 11,
                      height: 1.4,
                      color: _copied ? _string : const Color(0xFFCBD5E1))),
            ]),
          ),
        ),
      );

  Widget _gutter(int lines) => Padding(
        padding: const EdgeInsets.only(right: 11, left: 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 1; i <= lines; i++)
              SizedBox(
                height: _lineHeight,
                child: Text('$i',
                    style: RelayTheme.codeText(
                        fontSize: 11, height: _lineHeight / 11, color: _gutterInk)),
              ),
          ],
        ),
      );

  List<TextSpan> _spans(_Token token) {
    final base = TextStyle(color: _colorOf(token.kind));
    for (final key in widget.emphasis) {
      if (key.isEmpty) continue;
      final at = token.text.indexOf(key);
      if (at < 0) continue;
      final rest = at + key.length;
      return [
        if (at > 0)
          TextSpan(text: token.text.substring(0, at), style: base),
        TextSpan(
          text: key,
          style: const TextStyle(
            color: _emphasis,
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.dotted,
            decorationColor: _emphasis,
          ),
        ),
        if (rest < token.text.length)
          TextSpan(text: token.text.substring(rest), style: base),
      ];
    }
    return [TextSpan(text: token.text, style: base)];
  }

  static Color _colorOf(_Kind kind) => switch (kind) {
        _Kind.comment => _comment,
        _Kind.tag => _tag,
        _Kind.attr => _attr,
        _Kind.string => _string,
        _Kind.punct => _punct,
        _Kind.keyword => _keyword,
        _Kind.number => _number,
        _Kind.plain => _fg,
      };
}

enum _Kind { plain, comment, tag, attr, string, punct, keyword, number }

class _Token {
  const _Token(this.text, this.kind);

  final String text;
  final _Kind kind;
}

List<_Token> _tokenize(String code, CodeLanguage language) =>
    switch (language) {
      CodeLanguage.html => _tokenizeHtml(code),
      CodeLanguage.javascript => _tokenizeJs(code),
      CodeLanguage.plain => _tokenizeLoose(code),
    };

bool _isDigit(int code) => code >= 0x30 && code <= 0x39;

bool _isWord(int code) =>
    (code >= 0x41 && code <= 0x5A) ||
    (code >= 0x61 && code <= 0x7A) ||
    code == 0x5F ||
    code == 0x24;

List<_Token> _tokenizeHtml(String src) {
  final out = <_Token>[];
  var i = 0;
  final n = src.length;
  while (i < n) {
    if (src.startsWith('<!--', i)) {
      final end = src.indexOf('-->', i + 4);
      final stop = end < 0 ? n : end + 3;
      out.add(_Token(src.substring(i, stop), _Kind.comment));
      i = stop;
      continue;
    }
    if (src[i] == '<') {
      final end = src.indexOf('>', i);
      final stop = end < 0 ? n : end + 1;
      out.addAll(_htmlTag(src.substring(i, stop)));
      i = stop;
      continue;
    }
    final next = src.indexOf('<', i);
    final stop = next < 0 ? n : next;
    out.add(_Token(src.substring(i, stop), _Kind.plain));
    i = stop;
  }
  return out;
}

/// 一个标签内部的着色：`<`/`>`/`=` 是标点，标签名一个色，属性名一个色，
/// 引号里的值一个色。
List<_Token> _htmlTag(String tag) {
  final out = <_Token>[];
  var i = 0;
  final n = tag.length;
  if (tag.startsWith('</', i)) {
    out.add(const _Token('</', _Kind.punct));
    i = 2;
  } else if (tag.startsWith('<', i)) {
    out.add(const _Token('<', _Kind.punct));
    i = 1;
  }
  final nameStart = i;
  while (i < n && (_isWord(tag.codeUnitAt(i)) || tag.codeUnitAt(i) == 0x2D)) {
    i++;
  }
  if (i > nameStart) out.add(_Token(tag.substring(nameStart, i), _Kind.tag));
  while (i < n) {
    final c = tag[i];
    if (c == '>' || c == '=' || c == '/') {
      out.add(_Token(c, _Kind.punct));
      i++;
      continue;
    }
    if (c == '"' || c == "'") {
      var j = i + 1;
      while (j < n && tag[j] != c) {
        j++;
      }
      final stop = j < n ? j + 1 : n;
      out.add(_Token(tag.substring(i, stop), _Kind.string));
      i = stop;
      continue;
    }
    if (c.trim().isEmpty) {
      final start = i;
      while (i < n && tag[i].trim().isEmpty) {
        i++;
      }
      out.add(_Token(tag.substring(start, i), _Kind.plain));
      continue;
    }
    final start = i;
    while (i < n && !'=/>"\' \t\n'.contains(tag[i])) {
      i++;
    }
    out.add(_Token(tag.substring(start, i), _Kind.attr));
  }
  return out;
}

const Set<String> _jsKeywords = {
  'const', 'let', 'var', 'await', 'async', 'function', 'return', 'new', //
  'if', 'else', 'for', 'of', 'in', 'import', 'from', 'export', 'null',
  'true', 'false', 'typeof', 'class', 'this',
};

List<_Token> _tokenizeJs(String src) {
  final out = <_Token>[];
  var i = 0;
  final n = src.length;
  while (i < n) {
    final c = src[i];
    if (src.startsWith('//', i)) {
      var end = src.indexOf('\n', i);
      if (end < 0) end = n;
      out.add(_Token(src.substring(i, end), _Kind.comment));
      i = end;
      continue;
    }
    if (src.startsWith('/*', i)) {
      final end = src.indexOf('*/', i + 2);
      final stop = end < 0 ? n : end + 2;
      out.add(_Token(src.substring(i, stop), _Kind.comment));
      i = stop;
      continue;
    }
    if (c == '"' || c == "'" || c == '`') {
      var j = i + 1;
      while (j < n && src[j] != c) {
        if (src[j] == r'\') j++;
        j++;
      }
      final stop = j < n ? j + 1 : n;
      out.add(_Token(src.substring(i, stop), _Kind.string));
      i = stop;
      continue;
    }
    if (_isDigit(src.codeUnitAt(i))) {
      var j = i;
      while (j < n &&
          (_isDigit(src.codeUnitAt(j)) || src.codeUnitAt(j) == 0x2E)) {
        j++;
      }
      out.add(_Token(src.substring(i, j), _Kind.number));
      i = j;
      continue;
    }
    if (_isWord(src.codeUnitAt(i))) {
      var j = i;
      while (j < n && _isWord(src.codeUnitAt(j))) {
        j++;
      }
      final word = src.substring(i, j);
      out.add(_Token(
          word, _jsKeywords.contains(word) ? _Kind.keyword : _Kind.plain));
      i = j;
      continue;
    }
    out.add(_Token(c, _Kind.plain));
    i++;
  }
  return out;
}

/// HTTP 报文、URL、JSON 混在一起的场景：只挑出真正有信息量的部分着色，
/// 其余保持正文色，避免整块花花绿绿。
final RegExp _loosePattern = RegExp(
    r'''https?://[^\s"'<>]+|"(?:[^"\\]|\\.)*"|\b(?:POST|GET|PUT|PATCH|DELETE|HEAD)\b''');

List<_Token> _tokenizeLoose(String src) {
  final out = <_Token>[];
  var cursor = 0;
  for (final match in _loosePattern.allMatches(src)) {
    if (match.start > cursor) {
      out.add(_Token(src.substring(cursor, match.start), _Kind.plain));
    }
    final text = match.group(0)!;
    final kind = text.startsWith('http')
        ? _Kind.tag
        : text.startsWith('"')
            ? _Kind.string
            : _Kind.keyword;
    out.add(_Token(text, kind));
    cursor = match.end;
  }
  if (cursor < src.length) {
    out.add(_Token(src.substring(cursor), _Kind.plain));
  }
  return out;
}
