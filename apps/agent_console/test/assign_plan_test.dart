import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relaydesk_agent_console/src/platform/platform_controller.dart';
import 'package:relaydesk_agent_console/src/platform/tenant_detail.dart';
import 'package:relaydesk_agent_console/src/state/credential_store.dart';
import 'package:relaydesk_agent_console/src/ui/platform_plans_page.dart';
import 'fake_platform_api.dart';

void main() {
  Future<PlatformController> setup(FakePlatformApi fake) async {
    final store = MemoryCredentialStore();
    await store.saveServer('https://relay.example.test');
    await store.savePlatformToken('issued-bearer');
    final controller =
        PlatformController(store: store, apiFactory: (_) => fake.buildClient());
    await controller.bootstrap();
    await controller.openTenant(FakePlatformApi.tenantId);
    return controller;
  }

  for (final width in [390.0, 1440.0]) {
    testWidgets('分配套餐失败保留输入并正确重试 $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final fake = FakePlatformApi();
      final controller = await setup(fake);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () => assignTenantPlan(
                          context, controller, controller.detail!,
                          initialPlan: 'ENTERPRISE'),
                      child: const Text('分配'))))));
      await tester.tap(find.text('分配'));
      await tester.pumpAndSettle();
      expect(find.text('企业标识：demo'), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextFormField, '调整说明'), '企业额度验收');
      expect(find.text('正常服务'), findsOneWidget);
      final seats = find.widgetWithText(TextFormField, '坐席上限');
      final messages = find.widgetWithText(TextFormField, '每月消息额度');
      expect(tester.widget<TextFormField>(seats).controller!.text, '100');
      expect(
          tester.widget<TextFormField>(messages).controller!.text, '1000000');
      await tester.enterText(seats, '-1');
      await tester.ensureVisible(find.text('确认分配'));
      await tester.tap(find.text('确认分配'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 1 至 1000000 的整数'), findsOneWidget);
      expect(fake.tenantUpdates, isEmpty);
      await tester.enterText(seats, '25');
      fake.failWith = jsonResponse(500, {'message': '本次分配失败'});
      await tester.ensureVisible(find.text('确认分配'));
      await tester.tap(find.text('确认分配'));
      await tester.pumpAndSettle();
      expect(find.text('分配企业额度'), findsOneWidget);
      expect(tester.widget<TextFormField>(seats).controller!.text, '25');
      fake.failWith = null;
      await tester.ensureVisible(find.text('确认分配'));
      await tester.tap(find.text('确认分配'));
      await tester.pumpAndSettle();
      expect(find.text('分配企业额度'), findsNothing);
      final update = fake.tenantUpdates.single;
      expect(update['plan'], 'ENTERPRISE');
      expect(update['status'], 'ACTIVE');
      expect(update['seatLimit'], 25);
      expect(update['monthlyMessageLimit'], 1000000);
      expect(update['monthlyAiLimit'], 100000);
      expect(update['reason'], '企业额度验收');
      expect(update['mode'], 'SET');
      expect(update['requestId'], isNotEmpty);
      expect(
          fake.calls
              .where((c) =>
                  c ==
                  'GET /api/v1/platform/tenants/${FakePlatformApi.tenantId}')
              .length,
          greaterThanOrEqualTo(2));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('套餐卡带入所选套餐并进入企业分配', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final fake = FakePlatformApi();
    final controller = await setup(fake);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PlatformPlansPage(controller: controller))));
    final buttons = find.text('分配给企业');
    await tester.ensureVisible(buttons.at(2));
    await tester.tap(buttons.at(2));
    await tester.pumpAndSettle();
    expect(controller.assignmentPlan, 'GROWTH');
    expect(controller.section, PlatformSection.tenants);
    expect(controller.detail, isNull);
    expect(fake.tenantUpdates, isEmpty);
  });
}
