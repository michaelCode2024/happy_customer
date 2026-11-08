import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tongyu_agent_console/src/util/document_picker_stub.dart'
    if (dart.library.html) 'package:tongyu_agent_console/src/util/document_picker_web.dart'
    if (dart.library.io) 'package:tongyu_agent_console/src/util/document_picker_io.dart'
    as documents;

/// A file the agent chose, already read into memory.
///
/// The console uploads through the authenticated API, so the bytes are needed
/// either way; keeping the path as well would only matter for very large files,
/// and the server caps those.
class PickedAttachment {
  const PickedAttachment({
    required this.fileName,
    required this.contentType,
    required this.bytes,
  });

  final String fileName;
  final String contentType;
  final Uint8List bytes;

  int get sizeBytes => bytes.length;

  bool get isImage => contentType.startsWith('image/');
}

/// Where attachments come from.
///
/// An interface for the same reason as [CredentialStore]: picking a file is a
/// platform channel, so tests substitute an implementation instead of mocking
/// the plugin. It also keeps the desktop file-picker question in one place —
/// swapping in a real file chooser later means writing one class, not editing
/// the composer.
abstract class AttachmentPicker {
  /// Opens the image library. Returns null when the agent cancels.
  Future<PickedAttachment?> pickImage();

  /// Opens the camera. Returns null when the agent cancels.
  Future<PickedAttachment?> pickCamera();

  /// Opens the file browser. Returns null when the agent cancels.
  Future<PickedAttachment?> pickFile();

  /// True when [pickFile] can offer more than the image library.
  bool get supportsArbitraryFiles;
}

/// The default picker, built on `image_picker`.
///
/// `image_picker` covers the album and camera. Documents go through the
/// platform file chooser, including the browser file input.
class ImageAttachmentPicker implements AttachmentPicker {
  ImageAttachmentPicker({ImagePicker? picker})
      : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  bool get supportsArbitraryFiles => true;

  @override
  Future<PickedAttachment?> pickImage() => _pick(ImageSource.gallery);

  @override
  Future<PickedAttachment?> pickCamera() => _pick(ImageSource.camera);

  Future<PickedAttachment?> _pick(ImageSource source) async {
    final file = await _picker.pickImage(
      source: source,
      // Screenshots of a phone screen are large; the server caps uploads, and
      // downscaling on the client keeps a shift's worth of traffic reasonable.
      maxWidth: 2400,
      maxHeight: 2400,
      imageQuality: 88,
    );
    if (file == null) {
      return null;
    }
    return _read(file);
  }

  @override
  Future<PickedAttachment?> pickFile() async {
    final file = await documents.pickDocument();
    return file == null ? null : _read(file);
  }

  Future<PickedAttachment> _read(XFile file) async {
    final bytes = await file.readAsBytes();
    return PickedAttachment(
      fileName: file.name.isEmpty ? 'attachment' : file.name,
      contentType: contentTypeForAttachment(file.name, file.mimeType),
      bytes: bytes,
    );
  }
}

/// A picker that only ever presents images chosen by a test.
@visibleForTesting
class FakeAttachmentPicker implements AttachmentPicker {
  FakeAttachmentPicker({this.image});

  PickedAttachment? image;

  @override
  bool get supportsArbitraryFiles => false;

  @override
  Future<PickedAttachment?> pickImage() async => image;

  @override
  Future<PickedAttachment?> pickCamera() async => image;

  @override
  Future<PickedAttachment?> pickFile() async => image;
}

/// Guesses a media type from the file name, preferring whatever the platform
/// reported. The server validates the type against an allow-list, so a wrong
/// guess is rejected rather than stored.
///
/// `application/octet-stream` is what browsers put on a file whose type they
/// did not recognise. The extension is a better guess, and the server already
/// rejects a bare octet-stream.
String contentTypeForAttachment(String fileName, String? reported) {
  final raw = reported?.split(';').first.trim() ?? '';
  if (raw.contains('/') && raw != 'application/octet-stream') {
    return raw;
  }
  final dot = fileName.lastIndexOf('.');
  final extension = dot >= 0 ? fileName.substring(dot + 1).toLowerCase() : '';
  switch (extension) {
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'heic':
      return 'image/heic';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'pdf':
      return 'application/pdf';
    case 'txt':
      return 'text/plain';
    case 'mp4':
      return 'video/mp4';
    case 'mov':
      return 'video/quicktime';
    case 'zip':
      return 'application/zip';
    case 'doc':
      return 'application/msword';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xls':
      return 'application/vnd.ms-excel';
    case 'xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    default:
      return 'application/octet-stream';
  }
}
