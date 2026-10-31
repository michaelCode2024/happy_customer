import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/state/session_controller.dart';
import 'package:tongyu_agent_console/src/theme.dart';
import 'package:tongyu_agent_console/src/ui/must_change_password_page.dart';

class _Session extends SessionController {
  _Session(this.client);
  final TongYuApi client;
  @override
  TongYuApi get api => client;
  @override
  AgentProfile get agent => const AgentProfile(
        id: 'a1',
        email: 'kefu@example.com',
        displayName: '客服小林',
        role: 'AGENT',
        mustChangePassword: true,
      );
}

void main() {
  test('登录资料识别必须改密', () {
    final agent = AgentProfile.fromJson(const {
      'id': 'a1',
      'email': 'kefu@example.com',
      'displayName': '客服小林',
      'role': 'AGENT',
      'mustChangePassword': true,
    });
    expect(agent.mustChangePassword, isTrue);
    expect(
      AgentProfile.fromJson(const {
        'id': 'a2',
        'email': 'old@example.com',
        'displayName': '老坐席',
        'role': 'AGENT',
      }).mustChangePassword,
      isFalse,
    );
  });

  for (final width in [390.0, 1400.0]) {
    testWidgets('初始密码登录后必须先改密 $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final api = TongYuApi(
        server: 'http://localhost',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      final session = _Session(api);
      addTearDown(session.dispose);
      addTearDown(api.close);
      await tester.pumpWidget(MaterialApp(
        theme: RelayTheme.light(),
        home: MustChangePasswordPage(session: session),
      ));
      await tester.pumpAndSettle();
      expect(find.text('请尽快修改登录密码'), findsWidgets);
      expect(find.text('当前密码'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);
      expect(find.text('个人设置'), findsNothing);
      final submit = find.widgetWithText(FilledButton, '确认修改并重新登录');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text('请填写当前密码与新密码'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
