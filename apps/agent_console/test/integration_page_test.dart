import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/ui/integration_page.dart';

void main() {
  Future<void> settleRequests(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('entry selector loads the corresponding installation snippet',
      (tester) async {
    final api = RelayDeskApi(
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
          _ => throw StateError('unexpected $path'),
        };
        return http.Response.bytes(utf8.encode(jsonEncode(data)), 200);
      }),
    )..token = 'test-session';
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: IntegrationPage(api: api)));
    await settleRequests(tester);
    expect(find.text('site-one'), findsOneWidget);

    await tester.tap(find.text('官网'));
    await settleRequests(tester);
    await tester.tap(find.text('商城').last);
    await settleRequests(tester);
    expect(find.text('site-two'), findsOneWidget);
  });

  testWidgets('new server key is only shown in the creation dialog',
      (tester) async {
    var creations = 0;
    final api = RelayDeskApi(
      server: 'https://chat.example.com',
      client: MockClient((request) async {
        final path = request.url.path;
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
    final api = RelayDeskApi(
        server: 'https://chat.example.com',
        client: MockClient((request) async {
          final body = switch (request.url.path) {
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
}
