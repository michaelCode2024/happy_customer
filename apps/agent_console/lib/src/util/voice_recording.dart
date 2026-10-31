import 'dart:typed_data';
export 'voice_recording_stub.dart'
    if (dart.library.html) 'voice_recording_web.dart'
    if (dart.library.io) 'voice_recording_io.dart';

class RecordedVoice {
  const RecordedVoice(this.bytes, this.contentType, this.duration);
  final Uint8List bytes;
  final String contentType;
  final Duration duration;
  String get fileName {
    final extension = contentType.contains('wav')
        ? 'wav'
        : contentType.contains('mp4') || contentType.contains('aac')
            ? 'm4a'
            : contentType.contains('ogg')
                ? 'ogg'
                : 'webm';
    return '语音-${DateTime.now().millisecondsSinceEpoch}.$extension';
  }
}
