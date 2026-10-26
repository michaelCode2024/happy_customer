import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/state/session_controller.dart';
import 'package:tongyu_agent_console/src/theme.dart';
import 'package:tongyu_agent_console/src/ui/mobile_workbench_nav.dart';
import 'package:tongyu_agent_console/src/ui/settings_page.dart';
import 'package:tongyu_agent_console/src/ui/workbench_page.dart';

class _Session extends SessionController {
  _Session(this.client);
  final TongYuApi client;
  @override
  TongYuApi get api => client;
  @override
  AgentProfile get agent => const AgentProfile(
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
  testWidgets('更多二级页系统返回回到枢纽，不直跳消息首页', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = TongYuApi(
        server: 'http://localhost',
        client: MockClient((r) async {
          final path = r.url.path;
          Object body = {'items': [], 'features': {}};
          if (path.endsWith('/conversations')) body = {'items': []};
          if (path.endsWith('/agents')) body = {'items': []};
          if (path.endsWith('/entitlements')) {
            body = {
              'features': {
                'groups': true,
                'integrations': true,
                'automation': true,
                'channels': true,
                'ai': true,
              }
            };
          }
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
        }));
    final session = _Session(api);
    addTearDown(session.dispose);
    addTearDown(api.close);

    await tester.pumpWidget(MaterialApp(
      theme: RelayTheme.light(),
      home: WorkbenchPage(session: session),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('更多').last);
    await tester.pumpAndSettle();
    expect(find.byType(MobileMoreHubPage), findsOneWidget);

    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.byType(MobileMoreHubPage), findsNothing);

    // 系统返回 / 手势路径：只退二级，回到「更多」枢纽。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MobileMoreHubPage), findsOneWidget);
    expect(find.byType(SettingsPage), findsNothing);
    // 底栏仍停在「更多」，没有被重置成消息首页。
    expect(find.text('日常接待'), findsWidgets);
  });
}
