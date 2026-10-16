import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/ui/conversation_context_panel.dart';

ChatMessage message(String id, String content) => ChatMessage.fromJson({
      'id': id,
      'conversationId': 'c1',
      'senderType': 'VISITOR',
      'messageType': 'TEXT',
      'content': content,
      'createdAt': '2026-10-15T02:00:00Z',
    });
http.Response response(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

void main() {
  testWidgets('推荐失败保留摘要，重试后查看真实来源并仅采纳草稿', (tester) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var attempts = 0;
    var adopted = '';
    final api = TongYuApi(
        server: 'http://localhost',
        client: MockClient((request) async {
          expect(request.url.path, '/api/v1/console/assist');
          final task = jsonDecode(request.body)['task'];
          if (task == 'SUGGEST' && ++attempts == 1) {
            return response({'error': '模型暂不可用'}, 502);
          }
          return response({
            'task': task,
            'available': true,
            'text': task == 'SUMMARIZE' ? '客户关注手机访问。' : '您好，支持手机网页访问。',
            'sourceDetails': task == 'SUGGEST'
                ? [
                    {
                      'id': 'k1',
                      'title': '接入说明',
                      'content': '网站版本支持 H5。',
                      'score': 0.8
                    },
                    {
                      'id': 'k2',
                      'title': '接入说明',
                      'content': '第二篇独立正文。',
                      'score': 0.6
                    },
                  ]
                : [],
          });
        }));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AiReceptionPanel(
      api: api,
      conversationId: 'c1',
      messages: [message('m1', '手机访问')],
      onAdopt: (result) => adopted = result.text,
    ))));
    await tester.tap(find.text('生成会话辅助'));
    await tester.pumpAndSettle();
    expect(find.text('客户关注手机访问。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('客户关注手机访问。'), findsOneWidget);
    await tester.tap(find.text('接入说明').last);
    await tester.pumpAndSettle();
    expect(find.text('第二篇独立正文。'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('插入输入框'));
    expect(adopted, '您好，支持手机网页访问。');
  });

  testWidgets('长回复折叠后仍可查看全文并采纳完整正文', (tester) async {
    tester.view.physicalSize = const Size(380, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fullText = List.filled(18, '网站支持手机访问，接入前请准备网站域名与常见问题资料。').join('\n');
    var adopted = '';
    final api = TongYuApi(
        server: 'http://localhost',
        client: MockClient((request) async {
          final task = jsonDecode(request.body)['task'];
          return response({
            'task': task,
            'available': true,
            'text': task == 'SUMMARIZE' ? '客户咨询接入。' : fullText,
            'sourceDetails': task == 'SUGGEST'
                ? [
                    {
                      'id': 'k1',
                      'title': '真实来源',
                      'content': '来源正文',
                      'score': 0.8
                    }
                  ]
                : [],
          });
        }));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AiReceptionPanel(
      api: api,
      conversationId: 'c1',
      messages: [message('m1', '网站接入')],
      onAdopt: (result) => adopted = result.text,
    ))));
    await tester.tap(find.text('生成会话辅助'));
    await tester.pumpAndSettle();
    expect(find.text('真实来源').hitTestable(), findsOneWidget);
    await tester.tap(find.text('查看全文'));
    await tester.pumpAndSettle();
    expect(find.text('完整推荐回复'), findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (widget) => widget is SelectableText && widget.data == fullText),
        findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('插入输入框'));
    expect(adopted, fullText);
  });

  testWidgets('生成期间出现新消息，旧结果不能直接采纳；切换会话丢弃迟到结果', (tester) async {
    final pending = <Completer<http.Response>>[];
    final api = TongYuApi(
        server: 'http://localhost',
        client: MockClient((request) {
          final completion = Completer<http.Response>();
          pending.add(completion);
          return completion.future;
        }));
    Future<void> show(String id, List<ChatMessage> messages) =>
        tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: AiReceptionPanel(
                    key: ValueKey(id),
                    api: api,
                    conversationId: id,
                    messages: messages,
                    onAdopt: (_) => fail('过期内容不能采纳')))));
    await show('c1', [message('m1', '问题一')]);
    await tester.tap(find.text('生成会话辅助'));
    await tester.pump();
    expect(pending, hasLength(2));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('正在整理会话并起草回复…'), findsOneWidget);
    pending.first.complete(
        response({'task': 'SUMMARIZE', 'available': true, 'text': '先完成的摘要'}));
    await tester.pump();
    await tester.pump();
    expect(find.text('先完成的摘要'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('正在结合知识库起草回复…'), findsOneWidget);
    await show('c1', [message('m1', '问题一'), message('m2', '补充问题')]);
    for (final completion in pending.where((item) => !item.isCompleted)) {
      completion.complete(
          response({'task': 'SUGGEST', 'available': true, 'text': '旧会话结果'}));
    }
    await tester.pumpAndSettle();
    expect(find.text('会话已有新内容，请更新后使用。'), findsWidgets);
    await tester.scrollUntilVisible(find.text('插入输入框'), 150,
        scrollable: find.byType(Scrollable).first);
    final adopt = tester.widget<OutlinedButton>(find
        .ancestor(
          of: find.text('插入输入框'),
          matching:
              find.byWidgetPredicate((widget) => widget is OutlinedButton),
        )
        .first);
    expect(adopt.onPressed, isNull);
    pending.clear();
    await tester.tap(find.text('更新会话辅助'));
    await tester.pump();
    await show('c2', [message('m3', '另一位客户')]);
    for (final completion in pending) {
      completion.complete(
          response({'task': 'SUGGEST', 'available': true, 'text': '迟到的旧结果'}));
    }
    await tester.pumpAndSettle();
    expect(find.text('迟到的旧结果'), findsNothing);
    expect(find.text('生成会话辅助'), findsOneWidget);
  });
}
