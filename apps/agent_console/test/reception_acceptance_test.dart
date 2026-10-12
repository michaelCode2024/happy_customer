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
 @override bool get supportsArbitraryFiles=>true;
 @override Future<PickedAttachment?> pickImage() async=>null;
 @override Future<PickedAttachment?> pickFile() async=>null;
}

void main(){
 for(final width in [390.0,1100.0]){
 testWidgets('待分配会话确认后才开始接待 $width',(tester)async{
  tester.view.physicalSize=Size(width,800);tester.view.devicePixelRatio=1;
  addTearDown((){tester.view.resetPhysicalSize();tester.view.resetDevicePixelRatio();});
  var accepted=false;var claims=0;var sends=0;
  Map<String,dynamic> conversation()=>{'id':'c1','visitorId':'v1','visitorName':'接单验收','status':'OPEN','assigneeId':'a1','assigneeName':'客服甲','assignmentExpiresAt':accepted?null:'2099-10-12T06:01:00Z','acceptedAt':accepted?'2026-10-12T06:00:00Z':null};
  final api=RelayDeskApi(server:'http://localhost',client:MockClient((r)async{
   Object body={};
   if(r.url.path.endsWith('/claim')){claims++;accepted=true;}
   else if(r.url.path.endsWith('/conversations')){body={'items':[conversation()]};}
   else if(r.url.path.endsWith('/c1')){body={'conversation':conversation()};}
   else if(r.url.path.endsWith('/pins')){body={'items':[]};}
   else if(r.url.path.endsWith('/messages')){if(r.method=='POST')sends++;body={'items':[]};}
   return http.Response.bytes(utf8.encode(jsonEncode(body)),200);
  }));
  final controller=WorkbenchController(api:api);
  addTearDown(controller.dispose);addTearDown(api.close);
  await controller.refreshConversations();await controller.select('c1');
  await tester.pumpWidget(MaterialApp(theme:RelayTheme.light(),home:Scaffold(body:ChatPanel(workbench:controller,picker:_Picker(),showInlineAssist:false))));
  await tester.pumpAndSettle();
  expect(find.text('确认接单'),findsOneWidget);
  expect(find.text('等待确认接单'),findsOneWidget);
  expect(find.text('完成会话'),findsNothing);
  expect(await controller.send(content:'未确认时发送'),isFalse);expect(sends,0);
  await tester.tap(find.text('确认接单'));await tester.pumpAndSettle();
  expect(claims,1);expect(controller.selected!.acceptedAt,isNotNull);
  expect(find.text('确认接单'),findsNothing);
  expect(tester.takeException(),isNull);
 });
 }
}
