import 'dart:async';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:tongyu_agent_console/src/util/clipboard_paste_api.dart';

/// 在捕获阶段听 `paste`。文件字节只存在于这次事件里，事后读剪贴板要权限。
///
/// `files` 里是从资源管理器复制来的文件（PDF、压缩包等）。没有文件、但有文字时不拦，
/// 留给输入框贴文字；只有图片条目时当作截图。
WebImagePasteBinding bindWebImagePaste({
  required bool Function() accept,
  required void Function(List<PastedClipboardFile> files) onFiles,
}) {
  var reading = false;
  void listener(html.Event event) {
    if (reading || !accept()) return;
    if (event is! html.ClipboardEvent) return;
    final data = event.clipboardData;
    if (data == null) return;
    final files = _clipboardFiles(data);
    if (files.isEmpty) return;
    event.preventDefault();
    event.stopPropagation();
    reading = true;
    unawaited(() async {
      try {
        final pasted = <PastedClipboardFile>[];
        for (final file in files) {
          final bytes = await _readFile(file);
          if (bytes == null || bytes.isEmpty) continue;
          final reported = file.type.trim();
          pasted.add(PastedClipboardFile(
            fileName: file.name,
            reportedType: reported.isEmpty ? null : reported,
            bytes: bytes,
          ));
        }
        if (pasted.isNotEmpty) onFiles(pasted);
      } finally {
        reading = false;
      }
    }());
  }

  html.document.addEventListener('paste', listener, true);
  return WebImagePasteBinding(() {
    html.document.removeEventListener('paste', listener, true);
  });
}

List<html.File> _clipboardFiles(html.DataTransfer data) {
  final copied = <html.File>[];
  final files = data.files;
  if (files != null) {
    for (var i = 0; i < files.length; i++) {
      copied.add(files[i]);
    }
  }
  if (copied.isNotEmpty) return copied;

  final items = data.items;
  if (items == null) return copied;
  final fromItems = <html.File>[];
  final count = items.length ?? 0;
  for (var i = 0; i < count; i++) {
    final item = items[i];
    if (item.kind != 'file') continue;
    final file = item.getAsFile();
    if (file == null) continue;
    fromItems.add(file);
  }
  if (fromItems.isEmpty) return copied;
  // 图文一起复制时，图片条目跟着文字走，不单独当附件。
  if (_plainText(data).isNotEmpty &&
      fromItems.every((file) => file.type.startsWith('image/'))) {
    return copied;
  }
  return fromItems;
}

String _plainText(html.DataTransfer data) {
  try {
    return data.getData('text/plain');
  } catch (_) {
    return '';
  }
}

Future<Uint8List?> _readFile(html.File file) {
  final reader = html.FileReader();
  final done = Completer<Uint8List?>();
  reader.onLoad.listen((_) {
    if (!done.isCompleted) done.complete(_asBytes(reader.result));
  });
  reader.onError.listen((_) {
    if (!done.isCompleted) done.complete(null);
  });
  reader.readAsArrayBuffer(file);
  return done.future;
}

Uint8List? _asBytes(Object? result) {
  if (result is Uint8List) return result;
  if (result is ByteBuffer) return Uint8List.view(result);
  return null;
}
