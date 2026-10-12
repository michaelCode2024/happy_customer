import 'dart:async';
// Web 条件导入将浏览器文件选择与原生客户端隔离。
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';

Future<XFile?> pickDocument() async {
  final result = Completer<XFile?>();
  final input = html.FileUploadInputElement()..style.display = 'none';
  html.document.body!.append(input);
  void finish(XFile? file) {
    input.remove();
    if (!result.isCompleted) result.complete(file);
  }

  input.addEventListener('cancel', (_) => finish(null));
  input.onChange.listen((_) async {
    final files = input.files;
    if (files == null || files.isEmpty) {
      finish(null);
      return;
    }
    final file = files.first;
    final reader = html.FileReader();
    reader.onError.listen((_) {
      input.remove();
      if (!result.isCompleted) result.completeError(StateError('文件读取失败'));
    });
    reader.onLoad.listen((_) => finish(XFile.fromData(
        reader.result as Uint8List,
        name: file.name,
        mimeType: file.type)));
    reader.readAsArrayBuffer(file);
  });
  input.click();
  return result.future;
}
