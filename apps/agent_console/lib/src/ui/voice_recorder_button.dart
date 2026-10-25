import 'dart:async';
import 'package:flutter/material.dart';
import '../util/voice_recording.dart';

class VoiceRecorderButton extends StatelessWidget {
  const VoiceRecorderButton(
      {super.key,
      required this.onRecorded,
      this.enabled = true,
      this.recorderFactory,
      this.color,
      this.iconSize = 22});
  final Future<void> Function(RecordedVoice) onRecorded;
  final bool enabled;
  final VoiceRecorder Function()? recorderFactory;
  final Color? color;
  final double iconSize;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: '录制语音',
      icon: Icon(Icons.mic_none_outlined,
          size: iconSize,
          color: enabled
              ? (color ?? scheme.onSurfaceVariant)
              : scheme.outline),
      onPressed: !enabled
          ? null
          : () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => _RecordingDialog(
                  onRecorded: onRecorded, recorderFactory: recorderFactory)),
    );
  }
}

class _RecordingDialog extends StatefulWidget {
  const _RecordingDialog({required this.onRecorded, this.recorderFactory});
  final Future<void> Function(RecordedVoice) onRecorded;
  final VoiceRecorder Function()? recorderFactory;
  @override
  State<_RecordingDialog> createState() => _RecordingDialogState();
}

class _RecordingDialogState extends State<_RecordingDialog> {
  late final _recorder = widget.recorderFactory?.call() ?? VoiceRecorder();
  Timer? _timer;
  int _seconds = 0;
  bool _recording = false, _busy = false;
  RecordedVoice? _voice;
  String? _error;
  @override
  void dispose() {
    _timer?.cancel();
    _recorder.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
      _voice = null;
    });
    try {
      await _recorder.start();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _seconds = 0;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _seconds++);
        if (_seconds >= 120) unawaited(_stop());
      });
    } catch (e) {
      if (mounted)
        setState(() => _error = e is StateError ? e.message.toString() : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    _timer?.cancel();
    setState(() {
      _busy = true;
      _recording = false;
    });
    try {
      final voice = await _recorder.stop();
      if (mounted) setState(() => _voice = voice);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _use() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onRecorded(_voice!);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '语音上传失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('录制语音'),
        content: SizedBox(
            width: 300,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_recording
                      ? '正在录音：$_seconds 秒'
                      : _voice == null
                          ? '点击开始录音，允许浏览器使用麦克风。'
                          : '录音完成：${(_voice!.duration.inMilliseconds / 1000).toStringAsFixed(1)} 秒'),
                  const SizedBox(height: 12),
                  const Text('最长120秒。添加后点击聊天中的发送按钮，才会发给客户。'),
                  if (_busy)
                    const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator()),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error))),
                ])),
        actions: [
          TextButton(
              onPressed:
                  _busy && _voice != null ? null : () => Navigator.pop(context),
              child: const Text('取消录音')),
          if (_voice != null)
            TextButton(
                onPressed: _busy ? null : _start, child: const Text('重新录制')),
          FilledButton(
              onPressed: _busy
                  ? null
                  : _recording
                      ? _stop
                      : _voice == null
                          ? _start
                          : _use,
              child: Text(_recording
                  ? '停止录音'
                  : _voice == null
                      ? '开始录音'
                      : '添加语音')),
        ],
      ));
}
