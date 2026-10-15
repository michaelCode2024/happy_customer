import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/ui/ai_assist_panel.dart';

void main() {
  testWidgets('润色使用客服草稿，编辑后丢弃迟到结果，空草稿不调用模型', (tester) async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final api = RelayDeskApi(
        server: 'http://localhost',
        client: MockClient((r) {
          calls++;
          expect(jsonDecode(r.body)['question'], '我帮您核实一下');
          return pending.future;
        }));
    Future<void> show(String draft) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AiAssistPanel(
                api: api,
                conversationId: 'c1',
                messages: [
                  ChatMessage.fromJson({
                    'id': 'm1',
                    'senderType': 'VISITOR',
                    'messageType': 'TEXT',
                    'content': '退款多久',
                    'createdAt': '2026-10-15T00:00:00Z'
                  })
                ],
                draftText: draft,
                writingOnly: true,
                onAdopt: (_) => fail('不得自动采纳')))));
    await show('');
    await tester.tap(find.text('AI 写作助手'));
    await tester.pumpAndSettle();
    expect(find.text('摘要'), findsNothing);
    await tester.tap(find.text('润色我的草稿'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('先在输入框写下回复，再进行润色。'), findsOneWidget);
    await show('我帮您核实一下');
    await tester.tap(find.text('润色我的草稿'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await show('草稿已修改');
    pending.complete(http.Response.bytes(
        utf8.encode(jsonEncode(
            {'task': 'POLISH', 'available': true, 'text': '过时的润色结果'})),
        200));
    await tester.pumpAndSettle();
    expect(find.text('过时的润色结果'), findsNothing);
    expect(calls, 1);
  });
}
