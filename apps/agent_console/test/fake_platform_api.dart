import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:relaydesk_agent_console/src/platform/platform_api.dart';

/// A [PlatformApi] fed by canned JSON.
///
/// The real client is used, only its transport is replaced, so these tests cover
/// the JSON decoding as well: a field renamed on the server shows up here as a
/// zero rather than as a compile error, which is exactly the bug worth catching.
class FakePlatformApi {
  FakePlatformApi({
    this.overviewBody = const <String, dynamic>{
      'tenants': 2,
      'activeTenants': 1,
      'agents': 4,
      'conversations': 30,
      'openConversations': 5,
      'messagesToday': 120,
      'planDistribution': <Object>[],
      'topTenants': <Object>[],
      'instance': 'test-instance',
      'realtimeConnections': 3,
      'aiProvider': 'none',
      'serverTime': '2026-01-01T00:00:00Z',
    },
    this.tenantsBody = const <String, dynamic>{
      'items': <Object>[
        <String, dynamic>{
          'id': '11111111-1111-1111-1111-111111111111',
          'name': '演示科技',
          'slug': 'demo',
          'status': 'ACTIVE',
          'createdAt': '2026-01-01T00:00:00Z',
          'plan': 'GROWTH',
          'planStatus': 'ACTIVE',
          'seatLimit': 10,
          'monthlyMessageLimit': 50000,
          'trialEndsAt': null,
          'agents': 3,
          'inboxes': 2,
          'conversations': 40,
          'openConversations': 4,
        },
      ],
    },
    this.tenantBody = const <String, dynamic>{
      'id': '11111111-1111-1111-1111-111111111111',
      'name': '演示科技',
      'slug': 'demo',
      'status': 'ACTIVE',
      'settings': <String, dynamic>{},
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': '2026-01-02T00:00:00Z',
      'subscription': <String, dynamic>{
        'plan': 'GROWTH',
        'status': 'ACTIVE',
        'seatLimit': 10,
        'monthlyMessageLimit': 50000,
        'trialEndsAt': null,
      },
      'agents': <Object>[
        <String, dynamic>{
          'id': 'aaaaaaaa-1111-1111-1111-111111111111',
          'email': 'owner@demo.test',
          'displayName': '管理员',
          'role': 'OWNER',
          'status': 'ACTIVE',
          'presence': 'ONLINE',
        },
      ],
      'inboxes': <Object>[
        <String, dynamic>{
          'id': 'bbbbbbbb-1111-1111-1111-111111111111',
          'name': '网站客服',
          'publicKey': 'demo-web',
          'status': 'ACTIVE',
        },
      ],
      'usage': <Object>[],
    },
    this.aiUsageBody = const <String, dynamic>{
      'days': 14,
      'providers': <Object>[],
      'reasons': <String, dynamic>{},
      'available': false,
    },
    this.metaBody = const <String, dynamic>{
      'product': 'RelayDesk 连语客服',
      'version': '0.1.0',
      'model': 'test-model',
      'aiProvider': 'none',
      'aiAvailable': false,
      'storage': 'local',
      'rateLimits': <String, int>{},
      'uploadMaxMB': 20,
      'webhookAttempts': 5,
      'platformFeatures': <String>['multi-tenant'],
    },
    this.createdBody = const <String, dynamic>{
      'tenantId': '22222222-2222-2222-2222-222222222222',
      'slug': 'acme',
      'plan': 'TRIAL',
      'ownerId': '33333333-3333-3333-3333-333333333333',
      'ownerEmail': 'owner@acme.test',
      'inboxId': '44444444-4444-4444-4444-444444444444',
      'publicKey': 'acme-web',
      'scriptUrl': 'https://relay.example.test/widget.js',
      'initialPassword': 'generated-secret',
    },
    this.staticToken = 'good-token',
  });

  static const String tenantId = '11111111-1111-1111-1111-111111111111';

  final Map<String, dynamic> overviewBody;
  final Map<String, dynamic> tenantsBody;
  final Map<String, dynamic> tenantBody;
  final Map<String, dynamic> aiUsageBody;
  final Map<String, dynamic> metaBody;
  final Map<String, dynamic> createdBody;

  /// The token `/token` accepts. Anything else is rejected the way the server
  /// rejects it.
  String staticToken;

  /// When set, every call answers with this instead. Used for the 401 and
  /// unreachable-server paths.
  http.Response? failWith;

  /// Requests seen, as `METHOD /path`, so a test can assert that a screen pulled
  /// the data it claims to.
  final List<String> calls = <String>[];

  /// Builds a real [PlatformApi] whose transport answers from this fake.
  PlatformApi buildClient() => PlatformApi(
        server: 'https://relay.example.test',
        client: MockClient(_handle),
      );

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    final method = request.method;
    calls.add('$method $path');
    final forced = failWith;
    if (forced != null) {
      return forced;
    }

    // Routed on method as well as path: `/tenants` is a list on GET and a
    // provisioning call on POST, and answering the wrong one would make a
    // broken create look like a successful list.
    if (path == '/api/v1/platform/token' && method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['token'] != staticToken) {
        return jsonResponse(401, <String, dynamic>{
          'code': 'PLATFORM_TOKEN_INVALID',
          'message': '平台管理令牌无效',
        });
      }
      return jsonResponse(200, <String, dynamic>{
        'token': 'issued-bearer',
        'expiresIn': 86400,
        'label': 'platform-console',
      });
    }
    if (path == '/api/v1/platform/overview') {
      return jsonResponse(200, overviewBody);
    }
    if (path == '/api/v1/platform/tenants' && method == 'GET') {
      return jsonResponse(200, tenantsBody);
    }
    if (path == '/api/v1/platform/tenants' && method == 'POST') {
      return jsonResponse(201, createdBody);
    }
    if (path == '/api/v1/platform/ai-usage') {
      return jsonResponse(200, aiUsageBody);
    }
    if (path == '/api/v1/platform/release-notes') {
      return jsonResponse(200, metaBody);
    }
    if (path == '/api/v1/platform/tenants/$tenantId' && method == 'GET') {
      return jsonResponse(200, tenantBody);
    }
    if (path == '/api/v1/platform/tenants/$tenantId' && method == 'PATCH') {
      return jsonResponse(200, <String, dynamic>{'status': 'OK'});
    }
    if (path == '/api/v1/platform/tenants/$tenantId/trial') {
      return jsonResponse(200, <String, dynamic>{'status': 'OK', 'days': 14});
    }
    if (path == '/api/v1/platform/tenants/$tenantId/owner') {
      return jsonResponse(200, <String, dynamic>{
        'status': 'OK',
        'password': 'reset-secret',
      });
    }
    return jsonResponse(404, <String, dynamic>{
      'code': 'NOT_FOUND',
      'message': '接口不存在：$path',
    });
  }
}

/// A JSON response built from bytes rather than a string.
///
/// `http.Response('…', 200)` encodes the body as latin-1, which throws on the
/// server's own Chinese error messages — the very case worth testing. UTF-8
/// bytes are what the real server sends and what the client decodes.
http.Response jsonResponse(int status, Map<String, dynamic> body) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );
