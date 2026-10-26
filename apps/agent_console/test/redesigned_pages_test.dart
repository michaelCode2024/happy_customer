import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/state/session_controller.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/theme.dart';
import 'package:tongyu_agent_console/src/ui/knowledge_page.dart';
import 'package:tongyu_agent_console/src/ui/settings_page.dart';

class _Session extends SessionController {
  _Session(this.client);
  final TongYuApi client;
  @override
  TongYuApi get api => client;
  @override
  AgentProfile get agent => AgentProfile(
      id: 'a1',
      email: 'service@example.com',
      displayName: '客服小林',
      role: 'SUPERVISOR',
      presence: 'ONLINE');
  @override
  TenantInfo get tenant =>
      const TenantInfo(id: 'tenant1', name: '演示企业', slug: 'demo');
}

void main() {
  for (final width in [320.0, 390.0, 1400.0]) {
    testWidgets('知识筛选、完整内容与真实回答测试 $width', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      var status = 'ACTIVE';
      var writes = 0;
      var answers = 0;
      final api = TongYuApi(
          server: 'http://localhost',
          client: MockClient((r) async {
            Object body = {};
            final route = r.url.path;
            if (r.method == 'PATCH') {
              status = jsonDecode(r.body)['status'];
              writes++;
            } else if (route.endsWith('/knowledge-categories'))
              body = {
                'items': [
                  {'id': 'cat1', 'name': '产品说明'}
                ]
              };
            else if(route.endsWith('/knowledge-gaps')) {
              body={'items':[{'question':'业务退款需要多久','reason':'LOW_CONFIDENCE','count':3}]};
            }
            else if (route.endsWith('/knowledge/search')) {
              answers++;
              body = {
                'answer': '这是根据资料生成的回答',
                'score': 0.92,
                'provider': 'test-provider',
                'sources': [
                  {
                    'id': 'k1',
                    'title': 'App 接入指南',
                    'content': '完整引用内容',
                    'score': 0.9
                  }
                ]
              };
            } else if (route.endsWith('/knowledge'))
              body = {
                'items': [
                  {
                    'id': 'k1',
                    'title': 'App 接入指南',
                    'content': '第一段完整内容\n第二段完整内容\n结尾重要说明',
                    'categoryId': 'cat1',
                    'questionExamples': 'App如何接入\n支持H5吗',
                    'status': status,
                    'hitCount': 8
                  },
                  {
                    'id': 'k2',
                    'title': '退换政策',
                    'content': '另一条资料',
                    'status': 'DISABLED'
                  }
                ]
              };
            return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
          }));
      final session = _Session(api);
      final workbench = WorkbenchController(api: api);
      addTearDown(session.dispose);
      addTearDown(workbench.dispose);
      addTearDown(api.close);
      await tester.pumpWidget(MaterialApp(
          theme: RelayTheme.light(),
          home: KnowledgePage(session: session, workbench: workbench)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('产品说明').first);
      await tester.pumpAndSettle();
      expect(find.text('退换政策'), findsNothing);
      await tester.tap(find.text('App 接入指南').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('结尾重要说明'), findsWidgets);
      await Scrollable.ensureVisible(tester.element(find.text('停用')), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(find.text('停用'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(status, 'DISABLED');
      await Scrollable.ensureVisible(tester.element(find.text('测试此知识')), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试此知识'));
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(find.text('生成回答')), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成回答'));
      await tester.pumpAndSettle();
      expect(answers, 1);
      expect(find.text('这是根据资料生成的回答'), findsOneWidget);
      expect(find.text('完整引用内容'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '模拟客户提问'), '另一个问题');
      await tester.pumpAndSettle();
      expect(find.text('这是根据资料生成的回答'), findsNothing);
      await tester.ensureVisible(find.text('未解决问题').first);
      await tester.tap(find.text('未解决问题').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('补充知识'));
      await tester.pumpAndSettle();
      expect(find.text('新增知识条目'),findsOneWidget);
      final title=tester.widget<TextField>(find.widgetWithText(TextField,'标题'));
      expect(title.controller!.text,'业务退款需要多久');
      expect(tester.takeException(), isNull);
    });
    testWidgets('个人设置分区与密码验证 $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final api = TongYuApi(
          server: 'http://localhost',
          client: MockClient((_) async => http.Response('{}', 200)));
      final session = _Session(api);
      addTearDown(session.dispose);
      addTearDown(api.close);
      await tester.pumpWidget(MaterialApp(
          theme: RelayTheme.light(),
          home: SettingsPage(session: session, onThemeModeChanged: (_) {})));
      await tester.pumpAndSettle();
      expect(find.text('企业 ID'), findsNothing);
      expect(find.text('修改密码'), findsNothing);
      await tester.tap(find.text('账号安全').first);
      await tester.pumpAndSettle();
      expect(find.text('当前密码'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '修改密码'));
      await tester.pumpAndSettle();
      expect(find.text('请填写当前密码与新密码'), findsOneWidget);
      final appearanceTab = find.text('外观与通知');
      await tester.ensureVisible(appearanceTab.first);
      await tester.tap(appearanceTab.first);
      await tester.pumpAndSettle();
      expect(find.text('当前为浅色模式'), findsOneWidget);
      expect(find.text('当前密码'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
