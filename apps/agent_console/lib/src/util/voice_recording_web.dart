import 'dart:async';
import 'dart:typed_data';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:js_util' as js;
import 'voice_recording.dart';

class VoiceRecorder {
  html.MediaStream? _stream;
  html.MediaRecorder? _recorder;
  final List<html.Blob> _chunks = [];
  DateTime? _started;
  int _generation = 0;
  Future<void> start() async {
    final generation = ++_generation;
    final media = html.window.navigator.mediaDevices;
    if (media == null || !js.hasProperty(html.window, 'MediaRecorder')) {
      throw StateError('此浏览器不支持录音，请使用Chrome或Edge，并通过HTTPS或localhost访问');
    }
    var expired = false;
    final pending = media.getUserMedia({'audio': true});
    pending.then((stream) {
      if (expired || generation != _generation) {
        for (final track in stream.getTracks()) {
          track.stop();
        }
      }
    }, onError: (Object _) {});
    try {
      final stream =
          await pending.timeout(const Duration(seconds: 20), onTimeout: () {
        expired = true;
        throw StateError('麦克风授权超时，请允许站点使用麦克风后重试');
      });
      if (generation != _generation) throw StateError('录音已取消');
      _stream = stream;
      final mime = [
        'audio/webm;codecs=opus',
        'audio/mp4',
        'audio/ogg;codecs=opus'
      ].firstWhere(html.MediaRecorder.isTypeSupported, orElse: () => '');
      final recorder =
          html.MediaRecorder(stream, mime.isEmpty ? {} : {'mimeType': mime});
      _recorder = recorder;
      _chunks.clear();
      recorder.addEventListener('dataavailable', (event) {
        final blob = js.getProperty<html.Blob>(event, 'data');
        if (blob.size > 0 && generation == _generation) _chunks.add(blob);
      });
      recorder.start(250);
      _started = DateTime.now();
    } catch (e) {
      cancel();
      if (e is StateError) rethrow;
      throw StateError('无法录音：请检查麦克风连接，并允许浏览器使用麦克风');
    }
  }

  Future<RecordedVoice> stop() async {
    final recorder = _recorder;
    if (recorder == null) throw StateError('没有正在录制的语音');
    final stopped = Completer<void>();
    recorder.addEventListener('stop', (_) {
      if (!stopped.isCompleted) stopped.complete();
    });
    recorder.addEventListener('error', (_) {
      if (!stopped.isCompleted) stopped.completeError(StateError('录音设备发生错误'));
    });
    final duration = DateTime.now().difference(_started!);
    try {
      recorder.stop();
      await stopped.future.timeout(const Duration(seconds: 5));
      final mime = recorder.mimeType ?? 'audio/webm';
      final blob = html.Blob(List<html.Blob>.of(_chunks), mime);
      if (duration.inMilliseconds < 500 || blob.size == 0)
        throw StateError('录音时间太短，请重试');
      final reader = html.FileReader();
      final read = Completer<Uint8List>();
      reader.onLoad.listen((_) => read.complete(reader.result as Uint8List));
      reader.onError.listen((_) => read.completeError(StateError('读取录音失败')));
      reader.readAsArrayBuffer(blob);
      return RecordedVoice(
          await read.future.timeout(const Duration(seconds: 5)),
          mime,
          duration);
    } finally {
      cancel();
    }
  }

  void cancel() {
    _generation++;
    final recorder = _recorder;
    if (recorder != null && recorder.state != 'inactive') recorder.stop();
    for (final track in _stream?.getTracks() ?? <html.MediaStreamTrack>[]) {
      track.stop();
    }
    _stream = null;
    _recorder = null;
    _started = null;
    _chunks.clear();
  }
}
