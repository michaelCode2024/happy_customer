import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relaydesk_agent_console/main.dart';
import 'package:relaydesk_agent_console/src/state/credential_store.dart';

/// The console's start-up behaviour, driven through the real [SessionController]
/// against a store that never touches the platform channel.
///
/// These assertions are deliberately about what an agent sees on a cold start —
/// the login form, the validation messages, the remembered appearance — rather
/// than about the widget tree's shape, so they survive UI rearrangements.
void main() {
  Future<void> boot(WidgetTester tester, CredentialStore store) async {
    await tester.pumpWidget(RelayDeskConsoleApp(credentials: store));
    await tester.pumpAndSettle();
  }

  testWidgets('an empty store lands on the login form', (tester) async {
    await boot(tester, MemoryCredentialStore());

    expect(find.text('RelayDesk 客服工作台'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '服务器地址'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '企业标识'), findsOneWidget);
  });

  testWidgets('submitting an empty form reports every field', (tester) async {
    await boot(tester, MemoryCredentialStore());

    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(find.text('请填写服务器地址'), findsOneWidget);
    expect(find.text('请填写企业标识'), findsOneWidget);
    expect(find.text('请填写邮箱'), findsOneWidget);
    expect(find.text('请填写密码'), findsOneWidget);
  });

  testWidgets('the remembered appearance is applied before signing in',
      (tester) async {
    final store = MemoryCredentialStore();
    await store.saveThemeMode('dark');

    await boot(tester, store);

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
  });

  testWidgets('the operations console is reachable and comes back',
      (tester) async {
    await boot(tester, MemoryCredentialStore());

    await tester.tap(find.text('平台管理员登录'));
    await tester.pumpAndSettle();

    // The operator's surface, which asks for the deployment secret rather than
    // an agent's email and password.
    expect(find.text('RelayDesk 运营后台'), findsOneWidget);
    expect(find.text('进入运营后台'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '平台管理令牌'), findsOneWidget);

    await tester.tap(find.text('返回客服工作台登录'));
    await tester.pumpAndSettle();

    expect(find.text('RelayDesk 客服工作台'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '企业标识'), findsOneWidget);
  });

  testWidgets('an empty operator form reports both fields', (tester) async {
    await boot(tester, MemoryCredentialStore());
    await tester.tap(find.text('平台管理员登录'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('进入运营后台'));
    await tester.pumpAndSettle();

    expect(find.text('请填写服务器地址'), findsOneWidget);
    expect(find.text('请填写平台管理令牌'), findsOneWidget);
  });
}
