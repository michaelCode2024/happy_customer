import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relaydesk_agent_console/src/platform/platform_api.dart';

void main() {
  test('平台建号使用目标企业路径和平台会话，不发送邀请', () async {
    final api = PlatformApi(
        server: 'https://support.example.test',
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/v1/platform/tenants/tenant1/agents');
          expect(request.headers['authorization'], 'Bearer platform-session');
          final data = jsonDecode(request.body) as Map<String, dynamic>;
          expect(data['email'], 'agent@example.test');
          expect(data['password'], 'PreviewOnly123');
          expect(data.containsKey('invite'), isFalse);
          return http.Response('{"id":"agent1"}', 201,
              headers: {'content-type': 'application/json'});
        }))
      ..token = 'platform-session';
    addTearDown(api.close);
    final result = await api.createAgent('tenant1', {
      'email': 'agent@example.test',
      'displayName': '测试坐席',
      'password': 'PreviewOnly123',
      'role': 'AGENT'
    });
    expect(result['id'], 'agent1');
  });
}
