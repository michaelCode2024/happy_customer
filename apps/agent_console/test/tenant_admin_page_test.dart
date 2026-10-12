import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/ui/tenant_admin_page.dart';

void main() {
  testWidgets('企业后台不提供建号或邀请入口', (tester) async {
    Map<String, dynamic>? creation;
    final api = RelayDeskApi(
        server: 'https://chat.example.com',
        client: MockClient((request) async {
          if (request.method == 'POST') {
            expect(request.url.path, '/api/v1/admin/agents');
            creation = jsonDecode(request.body) as Map<String, dynamic>;
            expect(creation!.keys.toSet(),
                {'displayName', 'email', 'role', 'maxConcurrent', 'inboxIds'});
            return http.Response(
                '{"id":"member1","initialPassword":"once-only"}', 201);
          }
          final data = switch (request.url.path) {
            '/api/v1/admin/agents' => {'items': []},
            '/api/v1/admin/inboxes' => {
                'items': [
                  {'id': 'inbox1', 'name': '网站客服'}
                ]
              },
            '/api/v1/admin/subscription' => {
                'plan': 'STARTER',
                'status': 'ACTIVE'
              },
            '/api/v1/admin/audit' => {'items': []},
            '/api/v1/console/entitlements' => {
                'plan': 'STARTER',
                'features': {'ai': false, 'integrations': true}
              },
            _ => throw StateError('unexpected ${request.url.path}'),
          };
          return http.Response.bytes(utf8.encode(jsonEncode(data)), 200);
        }))
      ..token = 'test-session';
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: TenantAdminPage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('添加成员'), findsNothing);
    expect(find.text('邀请成员'), findsNothing);
    expect(find.textContaining('新账号由平台管理员建立'), findsOneWidget);
    expect(creation, isNull);
  });
  testWidgets('体验版入口保存失败保留弹窗，重试不提交 AI 配置', (tester) async {
    int saves = 0;
    final api = RelayDeskApi(
        server: 'https://chat.example.com',
        client: MockClient((request) async {
          if (request.method == 'PATCH') {
            expect(request.url.path, '/api/v1/admin/inboxes/inbox1');
            expect((jsonDecode(request.body) as Map)['routing']['acceptanceTimeoutSeconds'], 27);
            saves++;
            return http.Response(saves == 1 ? '{"error":"保存测试失败"}' : '{}',
                saves == 1 ? 400 : 200);
          }
          final data = switch (request.url.path) {
            '/api/v1/admin/agents' => {'items': []},
            '/api/v1/admin/inboxes' => {
                'items': [
                  {'id': 'inbox1', 'name': '网站客服', 'status': 'ACTIVE'}
                ]
              },
            '/api/v1/admin/inboxes/inbox1' => {
                'id': 'inbox1',
                'name': '网站客服',
                'routing': {'strategy': 'LOAD_BALANCED', 'fixedAgentId': ''}
              },
            '/api/v1/admin/subscription' => {
                'plan': 'TRIAL',
                'status': 'ACTIVE'
              },
            '/api/v1/admin/audit' => {'items': []},
            '/api/v1/console/entitlements' => {
                'plan': 'TRIAL',
                'features': {'ai': false}
              },
            _ => throw StateError('unexpected ${request.url.path}'),
          };
          return http.Response.bytes(utf8.encode(jsonEncode(data)), 200);
        }))
      ..token = 'test-session';
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: TenantAdminPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客服入口').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('配置'));
    await tester.pumpAndSettle();
    expect(find.text('知识库 AI 自动接待'), findsNothing);
    await tester.enterText(
        find.widgetWithText(TextFormField, '入口名称'), '保留的入口名称');
    await tester.enterText(find.widgetWithText(TextFormField, '接单超时（秒）'), '9');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(find.text('请输入10到600之间的整数'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, '接单超时（秒）'), '27');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('配置客服入口'), findsOneWidget);
    expect(find.text('保留的入口名称'), findsOneWidget);
    expect(find.textContaining('保存失败，请修改后重试'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saves, 2);
    expect(find.text('配置客服入口'), findsNothing);
  });
}
