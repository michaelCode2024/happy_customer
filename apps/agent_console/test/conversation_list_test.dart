import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/state/session_controller.dart';
import 'package:relaydesk_agent_console/src/state/workbench_controller.dart';
import 'package:relaydesk_agent_console/src/ui/conversation_list.dart';

void main() {
  for (final width in [300.0, 340.0, 390.0]) {
    testWidgets('queue count stays clear of filters at ${width.toInt()}px',
        (tester) async {
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final api = RelayDeskApi(
        server: 'https://chat.example.com',
        client: MockClient((request) async => http.Response.bytes(
              utf8.encode(jsonEncode({
                'items': [
                  {
                    'id': 'conversation-1',
                    'visitorId': 'visitor-1',
                    'visitorName': '访客',
                    'subject': '很长的订单咨询标题需要截断不能盖住右边的时间',
                    'status': 'OPEN',
                    'lastMessagePreview': '请问这个订单什么时候发货？',
                    'updatedAt': DateTime.now().toUtc().toIso8601String(),
                    'agentUnread': 124,
                  }
                ],
                'queued': 999,
              })),
              200,
            )),
      );
      final workbench = WorkbenchController(api: api);
      addTearDown(() {
        workbench.dispose();
        api.close();
      });
      await workbench.refreshConversations();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: ConversationListPanel(
              workbench: workbench,
              session: SessionController(),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final queue = tester.getRect(find.text('99+').first);
      final all = tester.getRect(find.text('全部').first);
      expect(queue.bottom, lessThanOrEqualTo(all.top));
      expect(queue.right, lessThanOrEqualTo(width));
    });
  }
}
