import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/state/workbench_controller.dart';
import 'package:relaydesk_agent_console/src/ui/reception_guidance.dart';

void main() {
  testWidgets('历史队列不弹窗，新客户提醒不抢选择，关闭不重弹，接待后人数同步', (tester) async {
    var incoming = false;
    var claimed = false;
    var failClaim = false;
    Map<String, dynamic> row(String id, {bool other = false}) => {
          'id': id,
          'visitorId': id,
          'visitorName': '客户$id',
          'status': 'OPEN',
          'assigneeId':
              other ? 'other' : (id == 'new' && claimed ? 'self' : null),
          'acceptedAt': id == 'new' && claimed ? '2026-10-15T00:00:00Z' : null,
          'lastMessagePreview': '你好，请问有客服吗？',
        };
    final api = RelayDeskApi(
        server: 'http://localhost',
        client: MockClient((r) async {
          Object body = {};
          if (r.url.path.endsWith('/claim')) {
            if (failClaim) return http.Response('{"error":"已被其他客服接待"}', 409);
            claimed = true;
          } else if (r.url.path.endsWith('/conversations')) {
            final queue = r.url.queryParameters['filter'] == 'reception';
            body = {
              'items': [
                if (incoming && (!queue || !claimed)) row('new'),
                row('old'),
                if (!queue) row('other', other: true)
              ],
              'queued': incoming && !claimed ? 2 : 1,
              'receptionWaiting': incoming && !claimed ? 2 : 1
            };
          } else if (r.url.path.endsWith('/new')) {
            body = {'conversation': row('new')};
          } else if (r.url.path.endsWith('/old')) {
            body = {'conversation': row('old')};
          } else if (r.url.path.endsWith('/new/messages')) {
            body = {
              'items': [
                {
                  'id': 'visitor-message',
                  'conversationId': 'new',
                  'sequence': 1,
                  'senderType': 'VISITOR',
                  'content': '你好，请问有客服吗？'
                },
                {
                  'id': 'system-message',
                  'conversationId': 'new',
                  'sequence': 2,
                  'senderType': 'SYSTEM',
                  'content': '已分配给客服'
                },
              ]
            };
          } else {
            body = {'items': []};
          }
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
        }));
    final controller = WorkbenchController(api: api, selfId: 'self');
    addTearDown(controller.dispose);
    addTearDown(api.close);
    await controller.refreshConversations();
    await controller.select('old');
    expect(controller.receptionNotice, isNull);
    expect(controller.receptionWaiting, 1);
    incoming = true;
    await controller.refreshConversations(silent: true);
    expect(controller.selectedId, 'old');
    expect(controller.receptionNotice?.id, 'new');
    expect(controller.receptionNoticePreview, '你好，请问有客服吗？');
    for (final width in [390.0, 1200.0]) {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ReceptionGuidance(
                  workbench: controller,
                  onShowQueue: () {},
                  onOpen: (_) {},
                  child: const Text('当前会话')))));
      await tester.pumpAndSettle();
      expect(find.text('有 2 位客户正在等待接待'), findsOneWidget);
      expect(find.text('查看并接待'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    controller.dismissReceptionNotice();
    await controller.refreshConversations(silent: true);
    expect(controller.receptionNotice, isNull);
    await controller.setSearch('不会命中');
    await controller.showReceptionQueue();
    expect(controller.search, isEmpty);
    expect(controller.selectedId, 'old');
    await controller.select('new');
    failClaim = true;
    await controller.claim();
    expect(controller.threadError, isNotNull);
    expect(controller.claiming, isFalse);
    expect(controller.receptionWaiting, 2);
    failClaim = false;
    await controller.claim();
    expect(controller.threadError, isNull);
    expect(controller.receptionWaiting, 1);
    expect(controller.selected!.assigneeId, 'self');
    expect(controller.receptionNotice, isNull);
    await tester.pump(const Duration(seconds: 1));
  });
}
