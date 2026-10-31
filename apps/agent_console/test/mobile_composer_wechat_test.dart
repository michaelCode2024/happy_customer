import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/theme.dart';
import 'package:tongyu_agent_console/src/ui/chat_panel.dart';
import 'package:tongyu_agent_console/src/util/attachment_picker.dart';

class _Picker implements AttachmentPicker {
  @override
  bool get supportsArbitraryFiles => true;
  @override
  Future<PickedAttachment?> pickImage() async => null;
  @override
  Future<PickedAttachment?> pickCamera() async => null;
  @override
  Future<PickedAttachment?> pickFile() async => null;
}

/// 手机输入栏按微信形态统一：左语音、中输入框、右「+」，有内容时「+」换成绿色「发送」。
/// 访客端（packages/widget）用同一组数值，这里锁住高度与底边，防止两端再次长歪。
void main() {
  Future<void> pumpPhone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final conversation = {
      'id': 'c1',
      'visitorId': 'v1',
      'visitorName': '微信栏验收',
      'status': 'OPEN',
      'assigneeId': 'a1',
      'acceptedAt': '2026-10-15T00:00:00Z'
    };
    final api = TongYuApi(
        server: 'http://localhost',
        client: MockClient((request) async {
          Object body = {'items': []};
          if (request.url.path.endsWith('/conversations'))
            body = {
              'items': [conversation]
            };
          if (request.url.path.endsWith('/c1'))
            body = {'conversation': conversation};
          if (request.url.path.endsWith('/messages'))
            body = {
              'lastSequence': 1,
              'items': [
                {
                  'id': 'm1',
                  'conversationId': 'c1',
                  'sequence': 1,
                  'senderType': 'VISITOR',
                  'messageType': 'TEXT',
                  'content': '在吗'
                }
              ]
            };
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
        }));
    final workbench = WorkbenchController(api: api, selfId: 'a1');
    await workbench.refreshConversations();
    await workbench.select('c1');
    await tester.pumpWidget(MaterialApp(
        theme: RelayTheme.light(),
        home: Scaffold(
            body: ChatPanel(
                workbench: workbench,
                picker: _Picker(),
                assistDraft: ValueNotifier(null),
                onOpenProfile: () {}))));
    await tester.pumpAndSettle();
    // 控制器会调度“送达回执”定时器，推进假时钟把它跑完，避免测试结束时仍有 pending timer。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-composer')), findsOneWidget);
  }

  /// 输入框外框：带 minHeight 44 的那个容器（内含 1px 描边）。
  final _inputBox = find.byWidgetPredicate((w) =>
      w is Container &&
      w.constraints != null &&
      w.constraints!.minHeight == 44);
  final _sendButton =
      find.ancestor(of: find.text('发送'), matching: find.byType(FilledButton));

  testWidgets('空输入只有语音与「+」，三者同高同底边', (tester) async {
    await pumpPhone(tester);
    final mic = tester.getRect(find.byTooltip('语音'));
    final plus = tester.getRect(find.byTooltip('展开工具'));
    final box = tester.getRect(_inputBox);
    expect(mic.height, 44);
    expect(plus.height, 44);
    expect(box.height, 44);
    expect(mic.bottom, plus.bottom);
    expect(box.bottom, plus.bottom);
    expect(find.text('发送'), findsNothing);
  });

  testWidgets('输入内容后「+」换成 58x44 主色发送', (tester) async {
    await pumpPhone(tester);
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开工具'), findsNothing);
    final send = tester.getRect(_sendButton);
    final box = tester.getRect(_inputBox);
    expect(send.height, 44);
    expect(send.width, greaterThanOrEqualTo(58));
    expect(send.bottom, box.bottom);
    // 格局借微信，配色仍是项目蓝渐变。
    final chrome = tester.widget<DecoratedBox>(find
        .ancestor(of: find.text('发送'), matching: find.byType(DecoratedBox))
        .first);
    expect((chrome.decoration as BoxDecoration).gradient,
        RelayTheme.actionGradient);
  });

  testWidgets('表情收进「+」面板，与访客端一致', (tester) async {
    await pumpPhone(tester);
    await tester.tap(find.byTooltip('展开工具'));
    await tester.pumpAndSettle();
    expect(find.text('表情'), findsOneWidget);
    expect(find.text('相册'), findsOneWidget);
    expect(find.text('拍摄'), findsOneWidget);
    await tester.tap(find.text('表情'));
    await tester.pumpAndSettle();
    expect(find.text('😀'), findsOneWidget);
    await tester.tap(find.text('😀'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        contains('😀'));
  });

  testWidgets('语音模式换成 44 高按住说话，右侧仍是「+」', (tester) async {
    await pumpPhone(tester);
    await tester.tap(find.byTooltip('语音'));
    await tester.pumpAndSettle();
    final hold = tester.getRect(find.ancestor(
        of: find.text('按住 说话'), matching: find.byType(AnimatedContainer)));
    final mic = tester.getRect(find.byTooltip('键盘'));
    expect(hold.height, 44);
    expect(hold.bottom, mic.bottom);
    expect(find.byTooltip('展开工具'), findsOneWidget);
    expect(find.text('发送'), findsNothing);
  });
}
