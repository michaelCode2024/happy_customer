import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/ui/integration_page.dart';

void main() {
  Future<void> settleRequests(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('entry selector loads the corresponding installation snippet',
      (tester) async {
    final api = TongYuApi(
      server: 'https://chat.example.com',
      client: MockClient((request) async {
        final path = request.url.path;
        final data = switch (path) {
          '/api/v1/admin/inboxes' => {
              'items': [
                {'id': 'one', 'name': '官网'},
                {'id': 'two', 'name': '商城'},
              ]
            },
          '/api/v1/admin/inboxes/one/snippet' => {
              'inboxKey': 'site-one',
              'script': '<script>one</script>',
              'iframe': 'https://chat.example.com/h5/site-one',
              'iframeHtml':
                  '<iframe src="https://chat.example.com/h5/site-one"></iframe>',
              'openApiBase': 'https://chat.example.com/api/v1/open',
            },
          '/api/v1/admin/inboxes/two/snippet' => {
              'inboxKey': 'site-two',
              'script': '<script>two</script>',
              'iframe': 'https://chat.example.com/h5/site-two',
              'iframeHtml':
                  '<iframe src="https://chat.example.com/h5/site-two"></iframe>',
              'openApiBase': 'https://chat.example.com/api/v1/open',
            },
          '/api/v1/admin/api-keys' => {'items': []},
          '/api/v1/admin/webhooks' => {'items': [], 'availableEvents': []},
          '/api/v1/console/entitlements' => {
              'plan': 'ENTERPRISE',
              'features': {
                'identity': true,
                'integrations': true,
                'groups': true,
              },
            },
          _ => throw StateError('unexpected $path'),
        };
        return http.Response.bytes(utf8.encode(jsonEncode(data)), 200);
      }),
    )..token = 'test-session';
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: IntegrationPage(api: api)));
    await settleRequests(tester);
    await tester.tap(find.text('接入渠道'));
    await settleRequests(tester);
    expect(find.text('site-one'), findsOneWidget);

    await tester.tap(find.text('官网'));
    await settleRequests(tester);
    await tester.tap(find.text('商城').last);
    await settleRequests(tester);
    expect(find.text('site-two'), findsOneWidget);
    expect(find.text('<script>two</script>'), findsOneWidget);
    expect(find.text('网站内嵌 iframe 片段（可选）'), findsOneWidget);
    await Scrollable.ensureVisible(tester.element(find.text('H5 链接')), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('H5 链接'));
    await settleRequests(tester);
    expect(find.text('H5 链接 · 访问链接'), findsOneWidget);
    expect(find.text('复制链接'), findsOneWidget);
    expect(find.text('https://chat.example.com/h5/site-two'), findsOneWidget);
    expect(find.text('<script>two</script>'), findsNothing);
    expect(find.text('网站内嵌 iframe 片段（可选）'), findsNothing);
    await Scrollable.ensureVisible(tester.element(find.text('App WebView')), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('App WebView'));
    await settleRequests(tester);
    expect(find.text('App WebView · 访问链接'), findsOneWidget);
    expect(find.text('https://chat.example.com/h5/site-two?source=APP'),
        findsOneWidget);
    expect(find.text('https://chat.example.com/h5/site-two'), findsNothing);
    expect(find.text('网站内嵌 iframe 片段（可选）'), findsNothing);
    await Scrollable.ensureVisible(tester.element(find.text('网站组件')),
        alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('网站组件'));
    await settleRequests(tester);
    expect(find.text('<script>two</script>'), findsOneWidget);
    expect(find.text('网站内嵌 iframe 片段（可选）'), findsOneWidget);
    expect(find.text('https://chat.example.com/api/v1/open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new server key is only shown in the creation dialog',
      (tester) async {
    var creations = 0;
    final api = TongYuApi(
      server: 'https://chat.example.com',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path == '/api/v1/console/entitlements') {
          return http.Response(
              '{"plan":"GROWTH","features":{"integrations":true,"identity":false,"groups":true}}',
              200);
        }
        if (path == '/api/v1/admin/inboxes') {
          return http.Response('{"items":[]}', 200);
        }
        if (path == '/api/v1/admin/webhooks') {
          return http.Response('{"items":[]}', 200);
        }
        if (path == '/api/v1/admin/api-keys') {
          if (request.method == 'POST') {
            creations++;
            expect(request.headers['authorization'], 'Bearer test-session');
            expect(jsonDecode(request.body)['scopes'], ['read']);
            return http.Response('{"key":"secret-once"}', 201);
          }
          return http.Response.bytes(
              utf8.encode(jsonEncode({
                'items': creations == 0
                    ? []
                    : [
                        {
                          'id': 'key-id',
                          'name': '订单服务',
                          'keyPrefix': 'rd_123',
                          'status': 'ACTIVE',
                          'requestCount': 0
                        }
                      ]
              })),
              200);
        }
        throw StateError('unexpected $path');
      }),
    )..token = 'test-session';
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: IntegrationPage(api: api)));
    await settleRequests(tester);
    await tester.tap(find.text('服务端密钥'));
    await settleRequests(tester);
    await tester.tap(find.text('创建密钥'));
    await settleRequests(tester);
    await tester.enterText(find.byType(TextField).last, '订单服务');
    await settleRequests(tester);
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(find.text('secret-once'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('订单服务'), findsOneWidget);
    expect(find.text('secret-once'), findsNothing);
  });

  testWidgets('developer tabs and actions fit a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(360, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final api = TongYuApi(
        server: 'https://chat.example.com',
        client: MockClient((request) async {
          final body = switch (request.url.path) {
            '/api/v1/console/entitlements' => {
                'plan': 'GROWTH',
                'features': {
                  'integrations': true,
                  'identity': false,
                  'groups': true,
                },
              },
            '/api/v1/admin/inboxes' => {'items': []},
            '/api/v1/admin/api-keys' => {
                'items': [
                  {
                    'id': 'key-id',
                    'name': '订单服务',
                    'keyPrefix': 'rd_123',
                    'status': 'ACTIVE',
                    'scopes': ['read'],
                    'requestCount': 0
                  }
                ]
              },
            '/api/v1/admin/webhooks' => {
                'items': [
                  {
                    'id': 'hook-id',
                    'url': 'https://example.com/webhook',
                    'status': 'ACTIVE',
                    'events': ['message.created'],
                    'failedDeliveries': 0
                  }
                ],
                'availableEvents': ['message.created']
              },
            _ => throw StateError('unexpected ${request.url.path}'),
          };
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
        }))
      ..token = 'test-session';
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: IntegrationPage(api: api)));
    await settleRequests(tester);
    for (final tab in ['服务端密钥', '事件回调']) {
      await tester.tap(find.text(tab).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    expect(find.text('https://example.com/webhook'), findsOneWidget);
  });
  testWidgets('回调校验和服务端错误留在表单，修正后可重试', (tester) async {
    var posts = 0;
    final api = TongYuApi(
        server: 'http://localhost',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/entitlements')) {
            return http.Response(
                '{"plan":"GROWTH","features":{"integrations":true,"identity":false,"groups":true}}',
                200);
          }
          if (request.url.path.endsWith('/webhooks') &&
              request.method == 'POST') {
            posts++;
            return posts == 1
                ? http.Response('{"message":"retry error"}', 500)
                : http.Response('{"secret":"test-secret"}', 201);
          }
          if (request.url.path.endsWith('/webhooks'))
            return http.Response(
                '{"items":[],"availableEvents":["conversation.read","conversation.delivered"]}',
                200);
          return http.Response('{"items":[]}', 200);
        }))
      ..token = 'test';
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: IntegrationPage(api: api)));
    await settleRequests(tester);
    await tester.tap(find.text('事件回调'));
    await settleRequests(tester);
    await tester.tap(find.text('新增回调'));
    await settleRequests(tester);
    await tester.tap(find.text('创建'));
    await settleRequests(tester);
    expect(find.text('请填写有效的 HTTP/HTTPS 地址并选择至少一个事件'), findsOneWidget);
    expect(posts, 0);
    await tester.enterText(
        find.byType(TextFormField), 'http://localhost:8099/receipt');
    await tester.tap(find.text('conversation.read'));
    await tester.pump();
    await tester.tap(find.text('创建'));
    await settleRequests(tester);
    expect(find.text('retry error'), findsOneWidget);
    expect(find.text('http://localhost:8099/receipt'), findsOneWidget);
    await tester.tap(find.text('创建'));
    await settleRequests(tester);
    expect(posts, 2);
    expect(find.text('回调签名密钥'), findsOneWidget);
  });

  testWidgets('旗舰版接入指南展示 member-token 进群，不伪装企业版身份票据', (tester) async {
    final api = TongYuApi(
      server: 'https://chat.example.com',
      client: MockClient((request) async {
        final data = switch (request.url.path) {
          '/api/v1/console/entitlements' => {
              'plan': 'GROWTH',
              'features': {
                'integrations': true,
                'identity': false,
                'groups': true,
              },
            },
          '/api/v1/admin/inboxes' => {'items': []},
          '/api/v1/admin/api-keys' => {'items': []},
          '/api/v1/admin/webhooks' => {'items': [], 'availableEvents': []},
          _ => throw StateError('unexpected ${request.url.path}'),
        };
        return http.Response.bytes(utf8.encode(jsonEncode(data)), 200);
      }),
    )..token = 'test-session';
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: IntegrationPage(api: api)));
    await settleRequests(tester);
    await tester.tap(find.text('接入指南'));
    await settleRequests(tester);
    expect(find.textContaining('member-token'), findsWidgets);
    expect(find.textContaining('tongyu-group-'), findsOneWidget);
    expect(find.textContaining('visitor-identity'), findsNothing);
  });
}
