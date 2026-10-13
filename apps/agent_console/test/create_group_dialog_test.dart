import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/theme.dart';
import 'package:relaydesk_agent_console/src/ui/create_group_dialog.dart';

const inbox = InboxInfo(
    id: 'i1',
    name: '网站客服',
    publicKey: 'preview',
    autoAssign: true,
    aiEnabled: true);
void main() {
  for (final width in [320.0, 390.0, 900.0]) {
    testWidgets('创建群规则、字段验证与失败重试 $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      var calls = 0;
      Map<String, dynamic>? payload;
      await tester.pumpWidget(MaterialApp(
          theme: RelayTheme.light(),
          home: Scaffold(
              body: Builder(
                  builder: (ctx) => TextButton(
                      onPressed: () => showDialog<String>(
                          context: ctx,
                          builder: (_) => CreateGroupDialog(
                              inboxes: const [inbox],
                              onCreate: (data) async {
                                payload = data;
                                calls++;
                                if (calls == 1) throw Exception('测试失败');
                                return 'g1';
                              })),
                      child: const Text('建群'))))));
      await tester.tap(find.text('建群'));
      await tester.pumpAndSettle();
      expect(find.text('内部协作群'), findsOneWidget);
      expect(find.text('客户服务群'), findsOneWidget);
      await tester.tap(find.text('创建并进入群聊'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.text('请填写群名称'), findsOneWidget);
      await tester.tap(find.text('客户服务群'));
      await tester.pumpAndSettle();
      expect(find.text('3. 关联客服入口'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '  客户服务验收  ');
      await tester.ensureVisible(find.text('创建并进入群聊'));
      await tester.tap(find.text('创建并进入群聊'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(payload!['kind'], 'SERVICE');
      expect(payload!['inboxId'], 'i1');
      expect(payload!['name'], '客户服务验收');
      expect(find.textContaining('测试失败'), findsOneWidget);
      await tester.tap(find.text('创建并进入群聊'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('创建群聊'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('没有入口时解释原因并禁止提交客户群', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CreateGroupDialog(
                inboxes: const [],
                onCreate: (_) async {
                  calls++;
                  return 'g1';
                }))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客户服务群'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请联系主管'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.ancestor(
                of: find.text('创建并进入群聊'),
                matching: find.byWidgetPredicate((w) => w is FilledButton)))
            .onPressed,
        isNull);
    expect(calls, 0);
    await tester.tap(find.text('内部协作群'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.ancestor(
                of: find.text('创建并进入群聊'),
                matching: find.byWidgetPredicate((w) => w is FilledButton)))
            .onPressed,
        isNotNull);
  });
}
