import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/state/session_controller.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/ui/conversation_list.dart';

/// 已结束会话的列表请求：走「全部分片 + status=RESOLVED」，而不是靠一个「含已解决」开关。
void main() {
  final closedAt = DateTime.utc(2026, 10, 30, 9, 30);

  TongYuApi api(MockClientClient client) => TongYuApi(
        server: 'https://chat.example.com',
        client: MockClient((request) async {
          final resolved = request.url.queryParameters['status'] == 'RESOLVED';
          client(request.url);
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'items': <Map<String, Object?>>[
                if (resolved)
                  {
                    'id': 'conversation-1',
                    'visitorId': 'visitor-1',
                    'visitorName': '访客',
                    'subject': '已结束的订单咨询',
                    'status': 'RESOLVED',
                    'lastMessagePreview': '客服已结束本次会话。',
                    'closedAt': closedAt.toIso8601String(),
                    'updatedAt': closedAt.toIso8601String(),
                  },
              ],
              'queued': 0,
            })),
            200,
          );
        }),
      );

  test('「已结束」分片把状态收窄到 RESOLVED，其余分片不带 status 参数', () async {
    final seen = <Uri>[];
    final client = api(seen.add);
    final workbench = WorkbenchController(api: client);
    addTearDown(workbench.dispose);
    addTearDown(client.close);
    // 控制器还会用 limit=100 单独拉一次大厅计数；这里只看工作台分片（limit=50）。
    Uri listRequest() => seen.lastWhere(
          (uri) =>
              uri.path.endsWith('/console/conversations') &&
              uri.queryParameters['limit'] == '50',
        );
    await pumpEventQueue();
    seen.clear();

    await workbench.setFilter(QueueFilter.resolved);
    expect(listRequest().queryParameters['filter'], 'all');
    expect(listRequest().queryParameters['status'], 'RESOLVED');
    expect(workbench.conversations.single.isResolved, isTrue);

    seen.clear();
    await workbench.setFilter(QueueFilter.all);
    expect(listRequest().queryParameters['filter'], 'all');
    expect(listRequest().queryParameters['status'], isNull);
  });

  testWidgets('列表用「已结束」页签取代「含已解决」开关', (tester) async {
    final client = api((_) {});
    final workbench = WorkbenchController(api: client);
    addTearDown(workbench.dispose);
    addTearDown(client.close);
    await workbench.setFilter(QueueFilter.resolved);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 340,
          child: ConversationListPanel(
            workbench: workbench,
            session: SessionController(),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('含已解决'), findsNothing);
    expect(find.text('客户消息'), findsNothing);
    expect(find.text('已结束'), findsWidgets);
    expect(find.byTooltip('含已解决'), findsNothing);
  });
}

typedef MockClientClient = void Function(Uri url);
