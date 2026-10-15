import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/state/workbench_controller.dart';
import 'package:relaydesk_agent_console/src/theme.dart';
import 'package:relaydesk_agent_console/src/ui/chat_panel.dart';
import 'package:relaydesk_agent_console/src/util/attachment_picker.dart';

class _Picker implements AttachmentPicker {
  @override
  bool get supportsArbitraryFiles => true;
  @override
  Future<PickedAttachment?> pickImage() async => null;
  @override
  Future<PickedAttachment?> pickFile() async => null;
}

void main() {
  for (final width in [390.0, 1100.0]) {
    testWidgets('待分配会话确认后才开始接待 $width', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      var accepted = false;
      var claims = 0;
      var sends = 0;
      Map<String, dynamic> conversation() => {
            'id': 'c1',
            'visitorId': 'v1',
            'visitorName': '接单验收',
            'status': 'OPEN',
            'assigneeId': 'a1',
            'assigneeName': '客服甲',
            'assignmentExpiresAt':
                accepted ? null : '2099-10-12T06:01:00Z',
            'acceptedAt': accepted ? '2026-10-12T06:00:00Z' : null
          };
      final api = RelayDeskApi(
          server: 'http://localhost',
          client: MockClient((r) async {
            Object body = {};
            if (r.url.path.endsWith('/claim')) {
              claims++;
              accepted = true;
            } else if (r.url.path.endsWith('/conversations')) {
              body = {
                'items': [conversation()]
              };
            } else if (r.url.path.endsWith('/c1')) {
              body = {'conversation': conversation()};
            } else if (r.url.path.endsWith('/pins')) {
              body = {'items': []};
            } else if (r.url.path.endsWith('/messages')) {
              if (r.method == 'POST') sends++;
              body = {'items': []};
            }
            return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
          }));
      final controller = WorkbenchController(api: api, selfId: 'a1');
      addTearDown(controller.dispose);
      addTearDown(api.close);
      await controller.refreshConversations();
      await controller.select('c1');
      await tester.pumpWidget(MaterialApp(
          theme: RelayTheme.light(),
          home: Scaffold(
              body: ChatPanel(
                  workbench: controller,
                  picker: _Picker(),
                  showInlineAssist: false))));
      await tester.pumpAndSettle();
      expect(find.text('确认接单'), findsOneWidget);
      expect(find.text('等待确认接单'), findsOneWidget);
      expect(find.textContaining('确认接单'), findsWidgets);
      expect(find.text('完成会话'), findsNothing);
      expect(await controller.send(content: '未确认时发送'), isFalse);
      expect(sends, 0);
      await tester.tap(find.text('确认接单'));
      await tester.pumpAndSettle();
      expect(claims, 1);
      expect(controller.selected!.acceptedAt, isNotNull);
      expect(find.text('确认接单'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('待接待队列会话未领取时提示开始接待 $width', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      var claimed = false;
      var sends = 0;
      Map<String, dynamic> conversation() => {
            'id': 'c2',
            'visitorId': 'v2',
            'visitorName': '本机用户',
            'status': 'OPEN',
            'assigneeId': claimed ? 'a1' : null,
            'assigneeName': claimed ? '客服甲' : '',
            'acceptedAt': claimed ? '2026-10-14T12:00:00Z' : null,
            'assignmentExpiresAt': null,
          };
      final api = RelayDeskApi(
          server: 'http://localhost',
          client: MockClient((r) async {
            Object body = {};
            if (r.url.path.endsWith('/claim')) {
              claimed = true;
            } else if (r.url.path.endsWith('/conversations')) {
              body = {
                'items': [conversation()]
              };
            } else if (r.url.path.endsWith('/c2')) {
              body = {'conversation': conversation()};
            } else if (r.url.path.endsWith('/pins')) {
              body = {'items': []};
            } else if (r.url.path.endsWith('/messages')) {
              if (r.method == 'POST') sends++;
              body = {'items': []};
            }
            return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
          }));
      final controller = WorkbenchController(api: api, selfId: 'a1');
      addTearDown(controller.dispose);
      addTearDown(api.close);
      await controller.refreshConversations();
      await controller.select('c2');
      await tester.pumpWidget(MaterialApp(
          theme: RelayTheme.light(),
          home: Scaffold(
              body: ChatPanel(
                  workbench: controller,
                  picker: _Picker(),
                  showInlineAssist: false))));
      await tester.pumpAndSettle();
      expect(find.text('开始接待'), findsOneWidget);
      expect(find.textContaining('开始接待'), findsWidgets);
      expect(await controller.send(content: '测算出 二次测试'), isFalse);
      expect(sends, 0);
      expect(controller.threadError, contains('开始接待'));
      // 有历史消息时错误也要出现在横幅，不能只埋在空会话占位文案里。
      expect(find.textContaining('开始接待'), findsWidgets);
      await tester.enterText(find.byType(TextField).last, '草稿应保留');
      await tester.tap(width < 760 ? find.byTooltip('发送') : find.text('发送'));
      await tester.pumpAndSettle();
      expect(find.text('草稿应保留'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('他人接待中不显示确认接单并拦截回复 $width', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      var sends = 0;
      Map<String, dynamic> conversation() => {
            'id': 'c3',
            'visitorId': 'v3',
            'visitorName': '他人会话',
            'status': 'OPEN',
            'assigneeId': 'other',
            'assigneeName': '客服乙',
            'acceptedAt': '2026-10-14T12:00:00Z',
            'assignmentExpiresAt': null,
          };
      final api = RelayDeskApi(
          server: 'http://localhost',
          client: MockClient((r) async {
            Object body = {};
            if (r.url.path.endsWith('/conversations')) {
              body = {
                'items': [conversation()]
              };
            } else if (r.url.path.endsWith('/c3')) {
              body = {'conversation': conversation()};
            } else if (r.url.path.endsWith('/pins')) {
              body = {'items': []};
            } else if (r.url.path.endsWith('/messages')) {
              if (r.method == 'POST') sends++;
              // 有历史消息时仍要能看见错误横幅。
              body = {
                'items': [
                  {
                    'id': 'm1',
                    'conversationId': 'c3',
                    'senderType': 'VISITOR',
                    'content': '你好',
                    'messageType': 'TEXT',
                    'sequence': 1,
                    'createdAt': '2026-10-14T12:00:00Z',
                  }
                ]
              };
            }
            return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
          }));
      final controller = WorkbenchController(api: api, selfId: 'a1');
      addTearDown(controller.dispose);
      addTearDown(api.close);
      await controller.refreshConversations();
      await controller.select('c3');
      await tester.pumpWidget(MaterialApp(
          theme: RelayTheme.light(),
          home: Scaffold(
              body: ChatPanel(
                  workbench: controller,
                  picker: _Picker(),
                  showInlineAssist: false))));
      // 有访客消息会触发已送达回执定时器，多泵一会儿避免测试结束时仍挂着 Timer。
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('确认接单'), findsNothing);
      expect(find.text('开始接待'), findsNothing);
      expect(find.textContaining('客服乙'), findsWidgets);
      expect(await controller.send(content: '抢答'), isFalse);
      expect(sends, 0);
      expect(controller.threadError, contains('客服乙'));
      expect(find.textContaining('客服乙'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已解决会话提示发送会重新打开 $width', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      Map<String, dynamic> conversation() => {
            'id': 'c4',
            'visitorId': 'v4',
            'visitorName': '已解决客户',
            'status': 'RESOLVED',
            'assigneeId': 'a1',
            'assigneeName': '客服甲',
            'acceptedAt': '2026-10-14T12:00:00Z',
          };
      final api = RelayDeskApi(
          server: 'http://localhost',
          client: MockClient((r) async {
            Object body = {};
            if (r.url.path.endsWith('/conversations')) {
              body = {
                'items': [conversation()]
              };
            } else if (r.url.path.endsWith('/c4')) {
              body = {'conversation': conversation()};
            } else if (r.url.path.endsWith('/pins') ||
                r.url.path.endsWith('/messages')) {
              body = {'items': []};
            }
            return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
          }));
      final controller = WorkbenchController(api: api, selfId: 'a1');
      addTearDown(controller.dispose);
      addTearDown(api.close);
      await controller.refreshConversations();
      await controller.select('c4');
      await tester.pumpWidget(MaterialApp(
          theme: RelayTheme.light(),
          home: Scaffold(
              body: ChatPanel(
                  workbench: controller,
                  picker: _Picker(),
                  showInlineAssist: false))));
      await tester.pumpAndSettle();
      expect(find.text('已解决'), findsOneWidget);
      expect(find.textContaining('重新打开会话'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
