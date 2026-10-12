import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/ui/automation_page.dart';

void main() {
  testWidgets('窄屏欢迎语保存携带配置版本', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic>? saved;
    final api = RelayDeskApi(
        server: 'http://localhost',
        client: MockClient((r) async {
          dynamic body;
          if (r.method == 'PUT') {
            saved = jsonDecode(r.body) as Map<String, dynamic>;
            body = {'revision': 8, 'config': saved!['config']};
          } else if (r.url.path.endsWith('/inboxes')) {
            body = {
              'items': [
                {'id': 'one', 'name': '官网'}
              ]
            };
          } else if (r.url.path.endsWith('/automation')) {
            body = {
              'revision': 7,
              'config': {
                'openReply': '原欢迎语',
                'enabled': true,
                'respectAgent': true,
                'cooldownSeconds': 10,
                'keywordRules': []
              }
            };
          } else if (r.url.path.endsWith('/snippet')) {
            body = {
              'iframe': 'http://localhost/h5/test',
              'script': 'embed',
              'appUrl': 'http://localhost/h5/test?source=APP'
            };
          } else {
            body = {'items': []};
          }
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
        }))
      ..token = 'test';
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: AutomationPage(api: api)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('新增关键词规则'));
    await tester.pumpAndSettle();
    final inputs = find.byType(TextField);
    await tester.enterText(inputs.at(0), '服务时间');
    await tester.enterText(inputs.at(1), '时间');
    await tester.enterText(inputs.at(2), '09:00–18:00');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('服务时间'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('打开客服回复'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新的欢迎语');
    await tester.pump();
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    expect(saved?['revision'], 7);
    expect(saved?['config']['keywordRules'], hasLength(1));
    expect(saved?['config']['openReply'], '新的欢迎语');
    expect(tester.takeException(), isNull);
  });
  testWidgets('渠道卡片拒绝不安全图片链接', (tester) async {
    final api = RelayDeskApi(
        server: 'http://localhost',
        client: MockClient((r) async {
          final body = r.url.path.endsWith('/inboxes')
              ? {
                  'items': [
                    {'id': 'one', 'name': '官网'}
                  ]
                }
              : r.url.path.endsWith('/automation')
                  ? {
                      'revision': 0,
                      'config': {'cards': []}
                    }
                  : r.url.path.endsWith('/snippet')
                      ? {'iframe': 'http://localhost/h5/test'}
                      : {'items': []};
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
        }))
      ..token = 'test';
    addTearDown(api.close);
    await tester.pumpWidget(
        MaterialApp(home: AutomationPage(api: api, channels: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('图文模板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新增图文模板'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '卡片');
    await tester.enterText(fields.at(2), 'javascript:bad');
    await tester.enterText(fields.at(3), '回复');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('请填写标题和内容，链接与图片必须使用 http/https 地址'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
