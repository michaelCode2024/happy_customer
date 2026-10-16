import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/ui/chat_panel.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/util/attachment_picker.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/api/api_exception.dart';
import 'package:tongyu_agent_console/src/state/offline_store.dart';

class TestPicker implements AttachmentPicker {
  bool get supportsArbitraryFiles => false;
  Future<PickedAttachment?> pickImage() async => null;
  Future<PickedAttachment?> pickFile() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('隔离升级移除当前账号旧快照，不删除其他账号', () async {
    final prefs=await SharedPreferences.getInstance();
    const current='tongyu.offline.v1.https%3A%2F%2Fone.example.t.a.';
    const other='tongyu.offline.v1.https%3A%2F%2Fone.example.t.b.';
    await prefs.setString(current+'old','old customer message');
    await prefs.setString(other+'old','other account');
    final store=OfflineStore('https://one.example','t','a');await store.flush();
    expect(prefs.getString(current+'old'),isNull);
    expect(prefs.getString(other+'old'),'other account');
  });
  test('会话权限撤销后关闭已选会话并清空消息和缓存', () async {
    bool denied=false;
    final api=TongYuApi(server:'https://one.example',client:MockClient((r) async {
      if(denied) return http.Response('{"code":"CONVERSATION_NOT_FOUND","message":"not allowed"}',404);
      if(r.url.path.endsWith('/c1'))return http.Response('{"conversation":{"id":"c1","status":"OPEN","assigneeId":"a"}}',200);
      if(r.url.path.endsWith('/messages'))return http.Response('{"items":[{"id":"m1","sequence":1,"content":"old private content","senderType":"VISITOR"}],"lastSequence":1}',200);
      return http.Response('{"items":[]}',200);
    }))..token='local';
    api.configureOffline(tenant:'t',agent:'a');
    final wb=WorkbenchController(api:api,selfId:'a');await wb.select('c1');
    expect(wb.messages,isNotEmpty);denied=true;await wb.reloadSelected();
    expect(wb.selectedId,isNull);expect(wb.messages,isEmpty);
    expect(await api.offlineStore!.read('/api/v1/console/conversations/c1'),isNull);
    wb.dispose();api.close();
  });

  testWidgets('已保存的离线草稿进入会话时显示在真实输入框', (tester) async {
    final api = TongYuApi(
        server: 'https://offline.example',
        client: MockClient((r) async {
          if (r.url.path.endsWith('/c1'))
            return http.Response(
                jsonEncode({
                  'conversation': {
                    'id': 'c1',
                    'status': 'OPEN',
                    'assigneeId': 'a',
                    'acceptedAt': '2026-10-15T00:00:00Z'
                  }
                }),
                200);
          if (r.url.path.endsWith('/messages') || r.url.path.endsWith('/pins'))
            return http.Response('{"items":[],"lastSequence":0}', 200);
          throw http.ClientException('offline');
        }))
      ..token = 'local-test';
    api.configureOffline(tenant: 't', agent: 'a');
    await api.saveDraft('c1', '需要恢复的离线草稿');
    final controller = WorkbenchController(api: api, selfId: 'a');
    await controller.select('c1');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ChatPanel(
                workbench: controller,
                picker: TestPicker(),
                showInlineAssist: false))));
    await tester.pumpAndSettle();
    expect(
        find.byWidgetPredicate(
            (w) => w is TextField && w.controller?.text == '需要恢复的离线草稿'),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    api.close();
  });
  test('服务、企业、账号隔离，退出清除且旧请求不能写回', () async {
    final a = OfflineStore('https://one.example', 'tenant', 'alice');
    await a.write('draft/c1', {'content': '仅 Alice 可见'});
    expect(
        await OfflineStore('https://one.example', 'tenant', 'bob')
            .read('draft/c1'),
        isNull);
    expect(
        await OfflineStore('https://one.example', 'other', 'alice')
            .read('draft/c1'),
        isNull);
    expect(
        await OfflineStore('https://two.example', 'tenant', 'alice')
            .read('draft/c1'),
        isNull);
    final pending = a.write('another', {'value': 1});
    await a.clear();
    await pending;
    await a.write('draft/c1', {'content': '旧请求'});
    expect(
        await OfflineStore('https://one.example', 'tenant', 'alice')
            .read('draft/c1'),
        isNull);
  });
  test('过期快照不再返回', () async {
    final a = OfflineStore('https://one.example', 't', 'a');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        '${a.prefix}data',
        jsonEncode({
          'time': DateTime.now()
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch,
          'data': {'items': []}
        }));
    expect(await a.read('data'), isNull);
  });
  test('断网回退会话快照，恢复网络读取最新数据，403 不回退旧权限', () async {
    var state = 'online';
    final api = TongYuApi(
        server: 'https://one.example',
        client: MockClient((r) async {
          if (state == 'offline') throw http.ClientException('offline');
          if (state == 'forbidden') return http.Response('{}', 403);
          return http.Response(
              jsonEncode({
                'items': [
                  {'id': state}
                ],
                'unread': 0
              }),
              200);
        }))
      ..token = 'test-token';
    api.configureOffline(tenant: 't', agent: 'a');
    expect((await api.conversations()).items.single.id, 'online');
    state = 'offline';
    expect((await api.conversations()).items.single.id, 'online');
    expect(api.isOffline, isTrue);
    state = 'new';
    expect((await api.conversations()).items.single.id, 'new');
    expect(api.isOffline, isFalse);
    state = 'forbidden';
    await expectLater(api.conversations(), throwsA(isA<ApiException>()));
    expect(
        await api.offlineStore!.read('/api/v1/console/conversations'), isNull);
    state = 'permitted';
    expect((await api.conversations()).items.single.id, 'permitted');
    state = 'offline';
    expect((await api.conversations()).items.single.id, 'permitted');
    api.close();
  });
  test('离线草稿重启恢复，不补发客户消息，管理接口不读缓存', () async {
    var requests = 0;
    final client = MockClient((r) async {
      requests++;
      throw http.ClientException('offline');
    });
    final api = TongYuApi(server: 'https://one.example', client: client)
      ..token = 'test';
    api.configureOffline(tenant: 't', agent: 'a');
    await api.saveDraft('c1', '尚未发送的备注', localPrivate: true);
    final restored = TongYuApi(server: 'https://one.example', client: client)
      ..token = 'test';
    restored.configureOffline(tenant: 't', agent: 'a');
    final before = requests;
    final draft = await restored.draftData('c1');
    expect(draft['content'], '尚未发送的备注');
    expect(draft['localPrivate'], isTrue);
    expect(requests, before);
    await expectLater(restored.integrationKeys(), throwsA(isA<ApiException>()));
    await restored.clearOfflineData();
    expect(await OfflineStore('https://one.example', 't', 'a').read('draft/c1'),
        isNull);
  });
}
