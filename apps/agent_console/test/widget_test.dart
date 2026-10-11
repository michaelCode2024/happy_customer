import 'package:flutter/material.dart';
import 'fake_platform_api.dart';
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

    expect(find.text('通语'), findsWidgets);
    expect(find.text('登录工作台'), findsOneWidget);
    expect(find.text('进入工作台'), findsOneWidget);
    expect(find.text('高级设置'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '企业标识'), findsOneWidget);
  });

  testWidgets('submitting an empty form reports every field', (tester) async {
    await boot(tester, MemoryCredentialStore());

    await tester.tap(find.text('进入工作台'));
    await tester.pumpAndSettle();

    expect(find.text('请填写服务器地址'), findsOneWidget);
    expect(find.text('请填写企业标识'), findsOneWidget);
    expect(find.text('请填写用户名'), findsOneWidget);
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

    // 重构后登录卡更高，默认 800×600 需滚到底部再点切换入口。
    await tester.ensureVisible(find.text('平台管理员登录'));
    await tester.tap(find.text('平台管理员登录'));
    await tester.pumpAndSettle();

    // 运营登录：账号密码为主，服务器地址收在高级设置里。
    expect(find.text('登录运营后台'), findsOneWidget);
    expect(find.text('进入运营后台'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '密码'), findsWidgets);

    await tester.ensureVisible(find.text('切换到客服登录'));
    await tester.tap(find.text('切换到客服登录'));
    await tester.pumpAndSettle();

    expect(find.text('登录工作台'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '企业标识'), findsOneWidget);
  });

  testWidgets('an empty operator form reports both fields', (tester) async {
    await boot(tester, MemoryCredentialStore());
    await tester.ensureVisible(find.text('平台管理员登录'));
    await tester.tap(find.text('平台管理员登录'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('进入运营后台'));
    await tester.tap(find.text('进入运营后台'));
    await tester.pumpAndSettle();

    expect(find.text('请填写服务器地址'), findsOneWidget);
    expect(find.text('请填写登录密码'), findsOneWidget);
  });

  testWidgets('both login surfaces fit a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(360, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await boot(tester, MemoryCredentialStore());
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('平台管理员登录'));
    await tester.tap(find.text('平台管理员登录'));
    await tester.pumpAndSettle();
    expect(find.text('登录运营后台'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('记住平台门面且无令牌时落在平台登录页', (tester) async {
    final store = MemoryCredentialStore();
    await store.saveConsoleSurface('platform');
    await boot(tester, store);

    // 未登录：必须是登录表单，不能进运营内页。
    expect(find.text('进入运营后台'), findsOneWidget);
    expect(find.text('登录运营后台'), findsOneWidget);
    expect(find.text('运营概览'), findsNothing);
  });
  testWidgets('有效平台登录恢复后不被客服入口偏好困在登录页', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
    final store = MemoryCredentialStore();
    await store.saveServer('http://localhost');
    await store.savePlatformToken('test-token');
    await store.saveConsoleSurface('agent');
    final fake = FakePlatformApi();
    await tester.pumpWidget(RelayDeskConsoleApp(credentials: store, platformApiFactory: (_) => fake.buildClient()));
    await tester.pumpAndSettle();
    expect(find.text('进入运营后台'), findsNothing);
    expect(find.text('运营概览'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

}
