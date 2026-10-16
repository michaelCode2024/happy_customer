import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/state/session_controller.dart';
import 'package:tongyu_agent_console/src/ui/workbench_page.dart';
import 'package:tongyu_agent_console/src/util/attachment_picker.dart';
import 'package:tongyu_agent_console/src/theme.dart';
class Picker implements AttachmentPicker {
 bool get supportsArbitraryFiles => true;
 Future<PickedAttachment?> pickImage() async => null;
 Future<PickedAttachment?> pickFile() async => null;
}
void main() {
 for (final width in [320.0,390.0]) {
 testWidgets('手机聊天系统返回恢复列表，AI 建议采纳仅进入草稿 $width', (tester) async {
  tester.view.physicalSize = Size(width, 844);tester.view.devicePixelRatio=1;
  addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
  int sent=0, assist=0;
  final conversation={'id':'c1','visitorId':'v1','visitorName':'手机验收客户','status':'OPEN','assigneeId':'a1','acceptedAt':'2026-10-15T00:00:00Z'};
  final api=TongYuApi(server:'http://localhost',client:MockClient((r) async {
   Object body={'items':[]};
   if(r.url.path.endsWith('/entitlements'))body={'plan':'ENTERPRISE','features':{'ai':true}};
   if(r.url.path.endsWith('/conversations'))body={'items':[conversation]};
   if(r.url.path.endsWith('/c1'))body={'conversation':conversation};
   if(r.url.path.endsWith('/messages')){
    if(r.method=='POST')sent++;
    body={'items':[{'id':'m1','conversationId':'c1','sequence':1,'senderType':'VISITOR','messageType':'TEXT','content':'如何接入网站客服？'}],'lastSequence':1};
   }
   if(r.url.path.endsWith('/assist')){assist++;body={'task':'SUGGEST','available':true,'text':'可先使用网站接入代码。'};}
   return http.Response.bytes(utf8.encode(jsonEncode(body)),200);
  }));
  final workbench=WorkbenchController(api:api,selfId:'a1');await workbench.refreshConversations();
  final session=SessionController();
  await tester.pumpWidget(MaterialApp(theme:RelayTheme.light(),home:Scaffold(body:MobileConversationFlow(
   workbench:workbench,session:session,picker:Picker(),list:TextButton(onPressed:()=>workbench.select('c1'),child:const Text('打开验收会话'))))));
  await tester.tap(find.text('打开验收会话'));await tester.pumpAndSettle();
  expect(find.text('手机验收客户'),findsOneWidget);
  expect(Navigator.of(tester.element(find.text('手机验收客户'))).canPop(),true);
  expect(find.text('内部备注'),findsNothing,reason:'低频工具默认收起');
  await tester.tap(find.byTooltip('展开工具'));await tester.pumpAndSettle();
  expect(find.text('图片'),findsOneWidget);expect(find.text('文件'),findsOneWidget);
  await tester.tap(find.text('内部备注'));await tester.pumpAndSettle();
  expect(find.text('内部备注 · 仅团队可见'),findsOneWidget);
  await tester.enterText(find.byType(TextField).first,'保留的备注草稿');
  await tester.tap(find.text('取消'));await tester.pumpAndSettle();
  expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text,'保留的备注草稿');
  await tester.longPress(find.text('如何接入网站客服？'));await tester.pumpAndSettle();
  await tester.tap(find.text('引用回复'));await tester.pumpAndSettle();
  expect(workbench.replyTo,isNotNull);
  await tester.tap(find.byTooltip('取消引用'));await tester.pumpAndSettle();
  expect(workbench.replyTo,isNull);
  await tester.tap(find.byKey(const ValueKey('mobile-ai-assist')));await tester.pumpAndSettle();
  expect(find.text('建议回复'),findsOneWidget);await tester.tap(find.text('建议回复'));await tester.pumpAndSettle();
  expect(assist,1);await tester.tap(find.text('采纳到输入框'));await tester.pumpAndSettle();
  expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text,'可先使用网站接入代码。');
  expect(sent,0,reason:'AI 不能自动发送客户消息');
  await tester.binding.handlePopRoute();await tester.pumpAndSettle();
  expect(workbench.selectedId,isNull);expect(find.text('打开验收会话').hitTestable(),findsOneWidget);
  await tester.tap(find.text('打开验收会话'));await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('返回会话列表'));await tester.pumpAndSettle();
  expect(workbench.selectedId,isNull);expect(tester.takeException(),isNull);
  await tester.pumpWidget(const SizedBox.shrink());workbench.dispose();session.dispose();api.close();
 });
 }
}
