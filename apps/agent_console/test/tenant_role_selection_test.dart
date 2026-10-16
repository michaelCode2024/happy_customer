import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyu_agent_console/src/platform/create_agent_dialog.dart';
import 'package:tongyu_agent_console/src/platform/platform_controller.dart';
import 'package:tongyu_agent_console/src/state/credential_store.dart';

void main() {
  for (final width in [390.0, 1100.0]) {
    testWidgets('企业建号仅显示主管和坐席，宽度 $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = PlatformController(store: MemoryCredentialStore());
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: CreateAgentDialog(
                  controller: controller, tenantId: 'test'))));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      expect(find.text('客服主管'), findsOneWidget);
      expect(find.text('客服坐席'), findsWidgets);
      expect(find.text('企业管理员'), findsNothing);
      expect(find.text('企业所有者'), findsNothing);
      await tester.tap(find.text('客服主管'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
