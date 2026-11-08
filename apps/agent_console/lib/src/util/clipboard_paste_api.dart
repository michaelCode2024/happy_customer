import 'dart:typed_data';

/// 网页粘贴监听的句柄。安装包上 [cancel] 什么都不做。
class WebImagePasteBinding {
  WebImagePasteBinding([this._cancel]);

  final void Function()? _cancel;

  void cancel() => _cancel?.call();
}

/// 一次粘贴交出来的文件。截图没有原始文件名时 [fileName] 为空。
class PastedClipboardFile {
  const PastedClipboardFile({
    required this.fileName,
    required this.reportedType,
    required this.bytes,
  });

  final String fileName;
  final String? reportedType;
  final Uint8List bytes;
}
