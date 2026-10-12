import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';
import 'package:relaydesk_agent_console/src/util/voice_recording.dart';
import 'package:relaydesk_agent_console/src/ui/voice_recorder_button.dart';

void main() {
  testWidgets('停止录音保留音频，上传失败可重试，取消释放设备', (tester) async {
    final recorder = _TestRecorder();
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: VoiceRecorderButton(
                recorderFactory: () => recorder,
                onRecorded: (voice) async {
                  expect(voice.duration, const Duration(seconds: 2));
                  expect(voice.bytes, [1, 2, 3]);
                  if (++attempts == 1) throw StateError('网络中断');
                }))));
    await tester.tap(find.byTooltip('录制语音'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始录音'));
    await tester.pump();
    expect(find.textContaining('正在录音'), findsOneWidget);
    await tester.tap(find.text('停止录音'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加语音'));
    await tester.pumpAndSettle();
    expect(find.textContaining('语音上传失败'), findsOneWidget);
    await tester.tap(find.text('添加语音'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(recorder.canceled, isTrue);
    expect(find.text('添加语音'), findsNothing);
  });
  testWidgets('录音入口明确显示权限失败，取消不发送', (tester) async {
    var sent = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: VoiceRecorderButton(onRecorded: (_) async {
      sent = true;
    }))));
    await tester.tap(find.byTooltip('录制语音'));
    await tester.pumpAndSettle();
    expect(find.text('开始录音'), findsOneWidget);
    await tester.tap(find.text('开始录音'));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前客户端暂不支持录音'), findsOneWidget);
    await tester.tap(find.text('取消录音'));
    await tester.pumpAndSettle();
    expect(sent, isFalse);
    expect(find.text('开始录音'), findsNothing);
  });
}

class _TestRecorder extends VoiceRecorder {
  bool canceled = false;
  @override
  Future<void> start() async {}
  @override
  Future<RecordedVoice> stop() async => RecordedVoice(
      Uint8List.fromList([1, 2, 3]), 'audio/webm', const Duration(seconds: 2));
  @override
  void cancel() {
    canceled = true;
  }
}
