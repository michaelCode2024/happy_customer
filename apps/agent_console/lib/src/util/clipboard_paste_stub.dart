import 'package:tongyu_agent_console/src/util/clipboard_paste_api.dart';

WebImagePasteBinding bindWebImagePaste({
  required bool Function() accept,
  required void Function(List<PastedClipboardFile> files) onFiles,
}) =>
    WebImagePasteBinding();
