import 'dart:io';

import 'package:pasteboard/pasteboard.dart';
import 'package:tongyu_agent_console/src/util/clipboard_paste_api.dart';

/// 安装包从系统剪贴板读复制来的文件路径。网页没有这条，走粘贴事件。
Future<List<PastedClipboardFile>> readNativeClipboardFiles() async {
  final paths = await Pasteboard.files();
  final files = <PastedClipboardFile>[];
  for (final path in paths) {
    final file = File(path);
    if (!await file.exists()) continue;
    final name = path.replaceAll('\\', '/').split('/').last;
    files.add(PastedClipboardFile(
      fileName: name,
      reportedType: null,
      bytes: await file.readAsBytes(),
    ));
  }
  return files;
}
