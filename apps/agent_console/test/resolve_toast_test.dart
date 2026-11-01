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

void main() {
  testWidgets('标记解决只浮一条小提示，不再占用顶栏布局', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final conversation = {
      'id': 'c1',
      'visitorId': 'v1',
      'visitorName': '提示卡验收',
      'status': 'OPEN',
      'assigneeId': 'a1',
      'updatedAt': '2026-11-01T01:00:00Z',
    };
    final api = TongYuApi(
        server: 'http://localhost',
        client: MockClient((request) async {
          Object body = {};
          if (request.url.path.endsWith('/status')) {
            conversation['status'] = 'RESOLVED';
            body = {'conversation': conversation};
          } else if (request.url.path.endsWith('/conversations')) {
            body = {
              'items': [conversation]
            };
          } else if (request.url.path.endsWith('/c1')) {
            body = {'conversation': conversation};
          } else if (request.url.path.endsWith('/messages') ||
              request.url.path.endsWith('/pins')) {
            body = {'items': [], 'lastSequence': 0};
          }
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
        }));
    final controller = WorkbenchController(api: api, selfId: 'a1');
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

    final headerTop =
        tester.getTopLeft(find.byKey(const ValueKey('desk-resolve-mark'))).dy;
    await tester.tap(find.byKey(const ValueKey('desk-resolve-mark')));
    await tester.pumpAndSettle();

    // 小提示卡浮在窗口右上角，不是把工作区往下挤的 MaterialBanner。
    final toast = find.byKey(const ValueKey('desk-resolve-toast'));
    expect(toast, findsOneWidget);
    expect(find.byType(MaterialBanner), findsNothing);
    expect(tester.getTopLeft(find.text('提示卡验收')).dy, closeTo(headerTop, 1));
    final toastRect = tester.getRect(toast);
    expect(toastRect.width, lessThan(340));
    expect(toastRect.right, greaterThan(1280 - 32));
    expect(toastRect.top, lessThan(80));

    await tester.tap(find.byKey(const ValueKey('desk-resolve-view-resolved')));
    await tester.pumpAndSettle();
    expect(controller.filter, QueueFilter.resolved);
    expect(find.byKey(const ValueKey('desk-resolve-toast')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    api.close();
  });

  testWidgets('小提示 5 秒后自动消失', (tester) async {
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final conversation = {
      'id': 'c1',
      'visitorId': 'v1',
      'visitorName': '自动消失验收',
      'status': 'OPEN',
      'assigneeId': 'a1',
    };
    final api = TongYuApi(
        server: 'http://localhost',
        client: MockClient((request) async {
          Object body = {};
          if (request.url.path.endsWith('/status')) {
            conversation['status'] = 'RESOLVED';
            body = {'conversation': conversation};
          } else if (request.url.path.endsWith('/conversations')) {
            body = {
              'items': [conversation]
            };
          } else if (request.url.path.endsWith('/c1')) {
            body = {'conversation': conversation};
          } else if (request.url.path.endsWith('/messages') ||
              request.url.path.endsWith('/pins')) {
            body = {'items': [], 'lastSequence': 0};
          }
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
        }));
    final controller = WorkbenchController(api: api, selfId: 'a1');
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

    await tester.tap(find.byKey(const ValueKey('desk-resolve-mark')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desk-resolve-toast')), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desk-resolve-toast')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    api.close();
  });
}
