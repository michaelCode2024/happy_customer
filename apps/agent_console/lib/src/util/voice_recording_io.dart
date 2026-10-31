import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:record/record.dart';

import 'package:tongyu_agent_console/src/util/voice_recording.dart';

/// 安卓、iOS 与桌面端录音。输出 AAC（m4a），服务端按 audio/mp4 接收。
class VoiceRecorder {
  AudioRecorder? _recorder;
  DateTime? _started;
  String? _path;

  Future<void> start() async {
    final recorder = _recorder ??= AudioRecorder();
    try {
      final allowed = await recorder.hasPermission();
      if (!allowed) {
        throw StateError('请允许使用麦克风后重试');
      }
      final path =
          '${Directory.systemTemp.path}${Platform.pathSeparator}tongyu-voice-${DateTime.now().microsecondsSinceEpoch}.m4a';
      await recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      _path = path;
      _started = DateTime.now();
    } on StateError {
      rethrow;
    } catch (error) {
      cancel();
      throw StateError(_micMessage(error));
    }
  }

  Future<RecordedVoice> stop() async {
    final started = _started;
    final recorder = _recorder;
    if (started == null || recorder == null) {
      throw StateError('没有正在录制的语音');
    }
    _started = null;
    try {
      final stopped = await recorder.stop();
      final filePath = stopped ?? _path;
      _path = null;
      if (filePath == null) {
        throw StateError('读取录音失败');
      }
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      if (file.existsSync()) {
        await file.delete();
      }
      final duration = DateTime.now().difference(started);
      if (duration.inMilliseconds < 500 || bytes.isEmpty) {
        throw StateError('录音时间太短，请重试');
      }
      return RecordedVoice(bytes, 'audio/mp4', duration);
    } on StateError {
      cancel();
      rethrow;
    } catch (error) {
      cancel();
      throw StateError(_micMessage(error));
    }
  }

  void cancel() {
    final recorder = _recorder;
    final path = _path;
    _recorder = null;
    _path = null;
    _started = null;
    if (recorder != null) {
      unawaited(() async {
        try {
          await recorder.cancel();
        } catch (_) {}
        try {
          await recorder.dispose();
        } catch (_) {}
      }());
    }
    if (path != null) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          file.deleteSync();
        }
      } catch (_) {}
    }
  }
}

String _micMessage(Object error) {
  if (error is MissingPluginException) {
    return '请允许使用麦克风后重试';
  }
  return '无法录音：请检查麦克风权限后重试';
}
