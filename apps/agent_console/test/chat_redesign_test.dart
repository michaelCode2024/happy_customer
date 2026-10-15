import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/state/workbench_controller.dart';
import 'package:relaydesk_agent_console/src/theme.dart';
import 'package:relaydesk_agent_console/src/ui/chat_panel.dart';
import 'package:relaydesk_agent_console/src/util/attachment_picker.dart';

class _Picker implements AttachmentPicker {
  @override
  bool get supportsArbitraryFiles => true;
  @override
  Future<PickedAttachment?> pickImage() async => null;
  @override
  Future<PickedAttachment?> pickFile() async => null;
}

void main() {
  testWidgets('最新消息自动进入视口，阅读历史时保留位置', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    var count = 40;
    final conversation = {
      'id': 'c1',
      'visitorId': 'v1',
      'visitorName': '滚动验收',
      'status': 'OPEN'
    };
    final api = RelayDeskApi(
        server: 'http://localhost',
        client: MockClient((request) async {
          Object body = {};
          if (request.url.path.endsWith('/conversations'))
            body = {
              'items': [conversation]
            };
          if (request.url.path.endsWith('/c1'))
            body = {'conversation': conversation};
          if (request.url.path.endsWith('/pins')) body = {'items': []};
          if (request.url.path.endsWith('/messages'))
            body = {
              'lastSequence': count,
              'items': List.generate(
                  count,
                  (i) => {
                        'id': 'm${i + 1}',
                        'conversationId': 'c1',
                        'sequence': i + 1,
                        'senderType': 'VISITOR',
                        'messageType': 'TEXT',
                        'content': '消息 ${i + 1}' +
                            (i % 3 == 0 ? '\n不同高度的消息\n验收内容' : ''),
                        'createdAt': '2026-10-12T06:00:00Z',
                      }),
            };
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
        }));
    final controller = WorkbenchController(api: api);
    await controller.refreshConversations();
    await controller.select('c1');
    await tester.pumpWidget(MaterialApp(
        theme: RelayTheme.light(),
        home: Scaffold(
            body: ChatPanel(
                workbench: controller,
                picker: _Picker(),
                showInlineAssist: false))));
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    ScrollPosition position() => tester
        .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first)
        .position;
    expect(position().pixels, closeTo(position().maxScrollExtent, 1));
    expect(find.text('消息 40\n不同高度的消息\n验收内容').hitTestable(), findsOneWidget);
    count = 41;
    await controller.reloadSelected();
    await tester.pumpAndSettle();
    expect(position().pixels, closeTo(position().maxScrollExtent, 1));
    expect(find.text('消息 41').hitTestable(), findsOneWidget);
    await tester.drag(list, const Offset(0, 450));
    await tester.pumpAndSettle();
    final historyOffset = position().pixels;
    expect(position().maxScrollExtent - historyOffset, greaterThan(80));
    count = 42;
    await controller.reloadSelected();
    await tester.pumpAndSettle();
    expect(position().pixels, closeTo(historyOffset, 1));
    await tester.tap(find.text('回到最新消息'));
    await tester.pumpAndSettle();
    expect(position().pixels, closeTo(position().maxScrollExtent, 1));
    expect(find.text('消息 42').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    api.close();
  });

  for (final width in [390.0, 760.0, 1440.0]) {
    testWidgets(
        'chat actions and composer fit ${width.toInt()}px; mobile can return',
        (tester) async {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final conversation = {
        'id': 'c1',
        'visitorId': 'v1',
        'visitorName': '客户名称很长时仍可正常处理',
        'status': 'OPEN',
        'updatedAt': '2026-10-12T01:00:00Z',
      };
      final api = RelayDeskApi(
          server: 'http://localhost',
          client: MockClient((request) async {
            Object body = {};
            if (request.url.path.endsWith('/conversations'))
              body = {
                'items': [conversation],
                'queued': 1
              };
            if (request.url.path.endsWith('/c1'))
              body = {'conversation': conversation};
            if (request.url.path.endsWith('/messages') ||
                request.url.path.endsWith('/pins'))
              body = {'items': [], 'lastSequence': 0};
            return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
          }));
      final controller = WorkbenchController(api: api);
      final draft = ValueNotifier<AssistResult?>(null);
      await controller.refreshConversations();
      await controller.select('c1');
      await tester.pumpWidget(MaterialApp(
          theme: RelayTheme.light(),
          home: Scaffold(
              body: ChatPanel(
            workbench: controller,
            picker: _Picker(),
            assistDraft: draft,
            onOpenProfile: () {},
          ))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if(width>=760) expect(find.text('回复客户'), findsOneWidget);
      else {
        expect(tester.getSize(find.byKey(const ValueKey('mobile-composer'))).height,lessThan(160));
        await tester.tap(find.byTooltip('展开工具')); await tester.pumpAndSettle();
      }
      final field = find.byType(TextField).first;
      await tester.tap(find.text('内部备注'));
      draft.value = const AssistResult(task: 'SUGGEST', text: 'AI 建议只进入公开回复草稿');
      await tester.pump();
      expect(
          tester.widget<TextField>(field).controller!.text, draft.value!.text);
      expect(find.text('写一条内部备注，访客看不到'), findsNothing);
      await tester.tap(field);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(controller.messages, isEmpty,
          reason: 'Enter must not accidentally send a message');
      if (width < 760) {
        await tester.tap(find.byTooltip('返回会话列表'));
        await tester.pumpAndSettle();
        expect(controller.selectedId, isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      api.close();
      draft.dispose();
    });
  }
}
