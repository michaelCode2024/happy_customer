import 'dart:typed_data';
export 'voice_recording_stub.dart'
    if (dart.library.html) 'voice_recording_web.dart';

class RecordedVoice {
  const RecordedVoice(this.bytes, this.contentType, this.duration);
  final Uint8List bytes;
  final String contentType;
  final Duration duration;
  String get fileName =>
      '语音-${DateTime.now().millisecondsSinceEpoch}.${contentType.contains('mp4') ? 'm4a' : 'webm'}';
}
