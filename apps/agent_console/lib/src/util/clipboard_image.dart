import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:tongyu_agent_console/src/util/clipboard_files_stub.dart'
    if (dart.library.io) 'package:tongyu_agent_console/src/util/clipboard_files_io.dart'
    as native_files;
import 'package:tongyu_agent_console/src/util/clipboard_paste_api.dart';
import 'package:tongyu_agent_console/src/util/clipboard_paste_stub.dart'
    if (dart.library.html) 'package:tongyu_agent_console/src/util/clipboard_paste_web.dart'
    as web_paste;

export 'package:tongyu_agent_console/src/util/clipboard_paste_api.dart';

/// Ctrl+V / Cmd+V 粘贴截图：安装包走系统剪贴板，网页走粘贴事件。
///
/// 手机安装包没有硬件粘贴键，不开放。网页不用 `navigator.clipboard.read`，
/// 那个接口要剪贴板权限；截图只在用户按下粘贴时、由粘贴事件交出来。
bool get supportsClipboardImagePaste =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;

/// 网页上注册粘贴监听。安装包上是空操作，安装包仍在按键处理里读系统剪贴板。
WebImagePasteBinding bindWebImagePaste({
  required bool Function() accept,
  required void Function(List<PastedClipboardFile> files) onFiles,
}) =>
    web_paste.bindWebImagePaste(accept: accept, onFiles: onFiles);

/// 安装包上复制的文件。网页返回空列表。
Future<List<PastedClipboardFile>> readNativeClipboardFiles() =>
    native_files.readNativeClipboardFiles();

/// What the hint text should call the shortcut on this machine.
String get pasteShortcutLabel =>
    defaultTargetPlatform == TargetPlatform.macOS ? '⌘V' : 'Ctrl+V';

/// An image read from the system clipboard, ready for the upload API.
class ClipboardImage {
  const ClipboardImage({
    required this.bytes,
    required this.contentType,
    required this.extension,
  });

  final Uint8List bytes;
  final String contentType;

  /// Filename suffix without the leading dot.
  final String extension;
}

/// Reads an image from the clipboard, or returns null when the user copied
/// plain text instead.
///
/// The composer never consumes the Ctrl+V key event, so the TextField still
/// runs its own native paste. We only *additionally* queue an attachment when
/// the clipboard has no text flavour — otherwise copying a sentence from a
/// word processor (which often carries a bitmap too) would send both.
Future<ClipboardImage?> readClipboardImage() async {
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && (data.text ?? '').isNotEmpty) return null;
  } catch (_) {
    // No text flavour on the clipboard (the usual case for a screenshot), or
    // the platform refused the read. Either way, keep probing for an image.
  }

  Uint8List? raw;
  try {
    raw = await Pasteboard.image;
  } catch (_) {
    // Missing plugin, denied permission, no image flavour: stay quiet. Native
    // text paste has already happened; nothing else needs to be reported.
    return null;
  }
  if (raw == null || raw.isEmpty) return null;

  return normalizedClipboardImage(raw);
}

/// Turns whatever the platform handed us into something the server accepts.
///
/// macOS, Linux and the web give PNG. Windows wraps the clipboard's DIB in a
/// BITMAPFILEHEADER and returns an uncompressed BMP — a 1080p screenshot is
/// roughly 8 MB, so re-encoding to PNG keeps pasted images in line with the
/// downscaled ones from the image picker.
Future<ClipboardImage?> normalizedClipboardImage(Uint8List bytes) async {
  final type = imageTypeFromBytes(bytes);
  if (type == 'image/bmp') {
    final png = await _toPng(bytes);
    // Skia should decode BMP, but if it cannot, the server already allows
    // image/bmp — uploading the original beats silently dropping the paste.
    return png ??
        ClipboardImage(
            bytes: bytes, contentType: 'image/bmp', extension: 'bmp');
  }
  if (type != null) {
    return ClipboardImage(
      bytes: bytes,
      contentType: type,
      extension: _extensionFor(type),
    );
  }
  // Unknown signature: let the engine try to decode it rather than uploading
  // bytes the message bubble could never render.
  return _toPng(bytes);
}

/// Sniffs the real image format instead of trusting a platform-specific
/// extension (the Windows temp file has none at all).
String? imageTypeFromBytes(Uint8List bytes) {
  bool startsWith(List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (startsWith(const [0x42, 0x4D])) return 'image/bmp';
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      bytes.length >= 12 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}

String _extensionFor(String contentType) => switch (contentType) {
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => 'png',
    };

/// Decodes through the Flutter engine and re-encodes as PNG.
Future<ClipboardImage?> _toPng(Uint8List bytes) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    return ClipboardImage(
      bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      contentType: 'image/png',
      extension: 'png',
    );
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
