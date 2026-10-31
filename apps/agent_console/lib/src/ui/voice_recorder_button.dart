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
          color: enabled ? (color ?? scheme.onSurfaceVariant) : scheme.outline),
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

/// 按住说话。松开发送，上滑取消。录音实现由各端的 [VoiceRecorder] 提供。
class VoiceHoldButton extends StatefulWidget {
  const VoiceHoldButton({
    super.key,
    required this.onRecorded,
    required this.onError,
    this.enabled = true,
    this.recorderFactory,
  });

  final Future<void> Function(RecordedVoice voice) onRecorded;
  final ValueChanged<String> onError;
  final bool enabled;
  final VoiceRecorder Function()? recorderFactory;

  @override
  State<VoiceHoldButton> createState() => _VoiceHoldButtonState();
}

class _VoiceHoldButtonState extends State<VoiceHoldButton> {
  VoiceRecorder? _recorder;
  OverlayEntry? _overlay;
  Timer? _timer;
  bool _fingerDown = false;
  bool _recording = false;
  bool _canceling = false;
  double? _originY;
  int _seconds = 0;

  @override
  void dispose() {
    _timer?.cancel();
    _overlay?.remove();
    _overlay = null;
    _recorder?.cancel();
    super.dispose();
  }

  void _showOverlay() {
    _overlay?.markNeedsBuild();
    if (_overlay != null) return;
    _overlay = OverlayEntry(builder: (context) {
      final canceling = _canceling;
      final scheme = Theme.of(context).colorScheme;
      return IgnorePointer(
        child: Center(
          child: Material(
            color: canceling ? scheme.error : scheme.inverseSurface,
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 168,
              height: 168,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.graphic_eq,
                      color: scheme.onInverseSurface, size: 48),
                  const SizedBox(height: 14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      canceling ? '松开手指，取消发送' : '手指上滑，取消发送',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: scheme.onInverseSurface, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    });
    Overlay.of(context).insert(_overlay!);
  }

  void _hideOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  void _down(PointerDownEvent event) {
    if (!widget.enabled || _fingerDown) return;
    _fingerDown = true;
    _originY = event.position.dy;
    _canceling = false;
    _seconds = 0;
    final recorder = widget.recorderFactory?.call() ?? VoiceRecorder();
    _recorder = recorder;
    setState(() {});
    _showOverlay();
    unawaited(_begin(recorder));
  }

  Future<void> _begin(VoiceRecorder recorder) async {
    try {
      await recorder.start();
      if (!mounted || !_fingerDown || !identical(recorder, _recorder)) {
        recorder.cancel();
        return;
      }
      setState(() => _recording = true);
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        _seconds++;
        if (_seconds >= 120) {
          unawaited(_finish(send: !_canceling));
        }
      });
    } catch (error) {
      if (!identical(recorder, _recorder) && _recorder != null) return;
      _fingerDown = false;
      _recording = false;
      _recorder = null;
      _hideOverlay();
      if (mounted) setState(() {});
      widget.onError(error is StateError ? error.message : '$error');
    }
  }

  void _move(PointerMoveEvent event) {
    if (!_fingerDown || _originY == null) return;
    final canceling = _originY! - event.position.dy > 80;
    if (canceling == _canceling) return;
    setState(() => _canceling = canceling);
    _overlay?.markNeedsBuild();
  }

  Future<void> _finish({required bool send}) async {
    if (!_fingerDown) return;
    _fingerDown = false;
    _timer?.cancel();
    _timer = null;
    final recorder = _recorder;
    final wasRecording = _recording;
    _recorder = null;
    _recording = false;
    _canceling = false;
    _hideOverlay();
    if (mounted) setState(() {});
    if (recorder == null) return;
    if (!send || !wasRecording) {
      recorder.cancel();
      return;
    }
    try {
      final voice = await recorder.stop();
      await widget.onRecorded(voice);
    } catch (error) {
      if (mounted) {
        widget.onError(error is StateError ? error.message : '$error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: widget.enabled ? _down : null,
      onPointerMove: _move,
      onPointerUp: (_) => unawaited(_finish(send: !_canceling)),
      onPointerCancel: (_) => unawaited(_finish(send: false)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // 与输入框同一套主题皮肤，仅按下时加深一档。
          color: _fingerDown ? scheme.surfaceContainerHighest : scheme.surface,
          borderRadius: BorderRadius.circular(9),
          border:
              Border.all(color: scheme.outlineVariant.withValues(alpha: .6)),
        ),
        child: Text(
          '按住 说话',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: widget.enabled ? scheme.onSurface : scheme.outline,
          ),
        ),
      ),
    );
  }
}
