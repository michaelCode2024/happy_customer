import 'voice_recording.dart';

class VoiceRecorder {
  Future<void> start() async => throw StateError('当前客户端暂不支持录音，请使用浏览器');
  Future<RecordedVoice> stop() async => throw StateError('没有正在录制的语音');
  void cancel() {}
}
