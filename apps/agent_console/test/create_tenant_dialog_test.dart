import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyu_agent_console/src/api/api_exception.dart';
import 'package:tongyu_agent_console/src/platform/platform_models.dart';
import 'package:tongyu_agent_console/src/platform/tenant_table.dart';
import 'package:tongyu_agent_console/src/theme.dart';

void main() {
  for (final width in [390.0, 1100.0]) {
    testWidgets('企业创建失败保留输入并允许重试，宽度 $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var requests = 0;
      final pending = Completer<CreatedTenant>();
      final drafts = <CreateTenantRequest>[];
      await tester.pumpWidget(MaterialApp(
          theme: RelayTheme.light(),
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => showDialog<CreatedTenant>(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) =>
                              CreateTenantDialog(onSubmit: (draft) async {
                                drafts.add(draft);
                                requests++;
                                if (requests == 1) {
                                  throw const ApiException(
                                      statusCode: 409,
                                      code: 'DUPLICATE',
                                      message: '企业标识已被使用');
                                }
                                return pending.future;
                              })),
                      child: const Text('打开'))))));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), '我的测试企业');
      await tester.enterText(fields.at(1), 'taken-slug');
      await tester.enterText(fields.at(3), 'owner01');
      await tester.tap(find.widgetWithText(FilledButton, '开通企业'));
      await tester.pumpAndSettle();
      expect(find.text('企业标识已被使用'), findsOneWidget);
      expect(find.byType(CreateTenantDialog), findsOneWidget);
      expect(find.text('我的测试企业'), findsOneWidget);
      expect(find.text('owner01'), findsOneWidget);
      await tester.enterText(fields.at(1), 'available-slug');
      await tester.tap(find.widgetWithText(FilledButton, '开通企业'));
      await tester.pump();
      expect(requests, 2);
      expect(drafts.last.name, '我的测试企业');
      expect(drafts.last.slug, 'available-slug');
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      expect(
          tester
              .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '取消'))
              .onPressed,
          isNull);
      pending.complete(const CreatedTenant(
          tenantId: 't',
          slug: 'available-slug',
          plan: 'TRIAL',
          ownerEmail: 'owner01',
          inboxId: 'i',
          publicKey: 'p',
          scriptUrl: '',
          initialPassword: ''));
      await tester.pumpAndSettle();
      expect(find.byType(CreateTenantDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
