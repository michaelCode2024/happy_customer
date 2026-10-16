import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyu_agent_console/src/platform/platform_controller.dart';
import 'package:tongyu_agent_console/src/state/credential_store.dart';
import 'package:tongyu_agent_console/src/ui/manual_quota_page.dart';
import 'fake_platform_api.dart';

void main() {
  Future<PlatformController> setup(FakePlatformApi fake) async {
    final store = MemoryCredentialStore();
    await store.saveServer('https://relay.example.test');
    await store.savePlatformToken('issued-bearer');
    final c =
        PlatformController(store: store, apiFactory: (_) => fake.buildClient());
    await c.bootstrap();
    return c;
  }

  for (final width in [390.0, 1440.0]) {
    testWidgets('一次性追加额度只提交本月增量 $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final fake = FakePlatformApi();
      final c = await setup(fake);
      addTearDown(c.dispose);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () =>
                          openQuotaEditor(context, c, FakePlatformApi.tenantId),
                      child: const Text('分配'))))));
      await tester.tap(find.text('分配'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('一次性追加额度'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, '本月追加消息额度'), '5000');
      await tester.enterText(
          find.widgetWithText(TextFormField, '本月追加 AI 额度'), '200');
      await tester.enterText(
          find.widgetWithText(TextFormField, '调整说明'), '本月活动追加');
      await tester.tap(find.text('确认分配'));
      await tester.pumpAndSettle();
      final body = fake.tenantUpdates.single;
      expect(body['mode'], 'ADD');
      expect(body['extraMessages'], 5000);
      expect(body['extraAi'], 200);
      expect(body.containsKey('plan'), false);
      expect(body.containsKey('seatLimit'), false);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('普通平台管理员仅可查看企业额度', (tester) async {
    final fake = FakePlatformApi(platformRole: 'ADMIN');
    final c = await setup(fake);
    addTearDown(c.dispose);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ManualQuotaPage(controller: c))));
    await tester.pumpAndSettle();
    expect(c.isSuperAdmin, false);
    expect(find.text('分配额度'), findsNothing);
    expect(find.textContaining('演示科技'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
