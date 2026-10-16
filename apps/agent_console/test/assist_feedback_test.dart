import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/ui/assist_feedback_actions.dart';

void main() {
  testWidgets('反馈保存失败不采纳，重试成功保留草稿标识，质量反馈可更新', (tester) async {
    var fail = true;
    final actions = <String>[];
    AssistResult? adopted;
    final api = TongYuApi(server: 'http://localhost', client: MockClient((r) async {
      expect(r.url.path, '/api/v1/console/assist/a1/feedback');
      actions.add(jsonDecode(r.body)['action'] as String);
      return http.Response('{}', fail ? 500 : 200);
    }));
    const result = AssistResult(task: 'SUGGEST', text: '准备网站域名', interactionId: 'a1', available: true);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AssistFeedbackActions(api: api,
      result: result, onAdopt: (r) => adopted = r))));
    await tester.tap(find.text('插入输入框'));
    await tester.pumpAndSettle();
    expect(adopted, isNull);
    expect(find.text('反馈未保存，请重试'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('插入输入框'));
    await tester.pumpAndSettle();
    expect(adopted?.interactionId, 'a1');
    await tester.tap(find.text('有用'));
    await tester.pumpAndSettle();
    expect(find.text('已反馈：有用'), findsOneWidget);
    await tester.tap(find.text('需改进'));
    await tester.pumpAndSettle();
    expect(find.text('已反馈：需改进'), findsOneWidget);
    expect(actions, ['ADOPT','ADOPT','HELPFUL','NEEDS_WORK']);
  });
}
