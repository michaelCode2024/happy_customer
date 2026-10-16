import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';

void main() {
  test('断线补拉仅提醒新增客户消息，历史、系统和自己回复不响，重复补拉不重响', () async {
    var sequence = 7;
    final alerts = <String>[];
    final requestedAfter = <String?>[];
    final api = TongYuApi(server: 'http://localhost', client: MockClient((r) async {
      Object body;
      if (r.url.path.endsWith('/conversations')) {
        body = {'items': [{'id':'c1','visitorName':'测试客户','lastSequence':sequence}]};
      } else {
        requestedAfter.add(r.url.queryParameters['after']);
        body = {'items': [
          {'id':'m8','conversationId':'c1','sequence':8,'senderType':'VISITOR','content':'客户新消息'},
          {'id':'m9','conversationId':'c1','sequence':9,'senderType':'SYSTEM','content':'已接待'},
          {'id':'m10','conversationId':'c1','sequence':10,'senderType':'AGENT','content':'自己回复'},
        ], 'lastSequence':10};
      }
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
    }));
    final controller = WorkbenchController(api:api, visitorAlert:(id,name)=>alerts.add(id));
    addTearDown(controller.dispose);
    addTearDown(api.close);
    await controller.refreshConversations();
    expect(alerts, isEmpty);
    sequence = 10;
    await controller.refreshConversations(silent:true);
    await Future<void>.delayed(Duration.zero);
    expect(alerts, ['m8']);
    expect(requestedAfter, ['7']);
    await controller.refreshConversations(silent:true);
    await Future<void>.delayed(Duration.zero);
    expect(alerts, ['m8']);
    expect(requestedAfter, ['7']);
  });
}
