import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:relaydesk_agent_console/src/api/api_exception.dart';
import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/platform/platform_models.dart';

/// The HTTP client for the RelayDesk operations API.
///
/// This is a second client rather than more methods on [RelayDeskApi] because
/// the two speak as different principals against disjoint route trees: the agent
/// client is always tenant-scoped and the operator client is never. Keeping them
/// apart means neither can accidentally call the other's endpoints, which is the
/// failure that matters here — an operations screen posting to a tenant route
/// would be a cross-tenant bug, not a typo.
class PlatformApi {
  PlatformApi({required String server, http.Client? client})
      : _server = RelayDeskApi.normalizeServer(server),
        _client = client ?? http.Client();

  final String _server;
  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 20);

  String get server => _server;

  String token = '';

  bool get hasToken => token.isNotEmpty;


  void close() => _client.close();

  /// ------------------------------------------------------------------ session

  Future<void> login(String email, String password) async {
    final body = await _send('POST', '/api/v1/platform/login',
        body: <String, dynamic>{'email': email.trim(), 'password': password},
        authorized: false);
    token = asString(body['token']);
    if (token.isEmpty) {
      throw const ApiException(
          statusCode: 500, code: 'TOKEN_MISSING', message: '服务器未返回登录凭证');
    }
  }

  Future<Map<String, dynamic>> quotas({String query = '', int offset = 0}) =>
      _send('GET', '/api/v1/platform/quotas',
          query: {'q': query, 'offset': '$offset', 'limit': '100'});
  Future<Map<String, dynamic>> quota(String id) =>
      _send('GET', '/api/v1/platform/tenants/$id/quota');
  Future<Map<String, dynamic>> allocateQuota(
          String id, Map<String, dynamic> body) =>
      _send('POST', '/api/v1/platform/tenants/$id/quota', body: body);
  Future<Map<String, dynamic>> quotaHistory({int offset = 0}) =>
      _send('GET', '/api/v1/platform/quota-adjustments',
          query: {'offset': '$offset'});

  Future<void> logout() async {
    await _send('POST', '/api/v1/platform/logout');
  }

  Future<Map<String, dynamic>> profile() => _send('GET', '/api/v1/platform/me');
  Future<void> changePassword(String current, String next) async {
    await _send('POST', '/api/v1/platform/me/password',
        body: {'currentPassword': current, 'newPassword': next});
  }

  /// Verifies a stored token by making the cheapest authenticated call.
  ///
  /// overview proves the token is accepted and unexpired, which is all the
  /// console needs before it shows anything.
  Future<PlatformOverview> restore(String storedToken) async {
    token = storedToken;
    return overview();
  }

  /// ------------------------------------------------------------------ reading

  Future<PlatformOverview> overview() async {
    final body = await _send('GET', '/api/v1/platform/overview');
    return PlatformOverview.fromJson(body);
  }

  Future<List<TenantSummary>> tenants(
      {String query = '', int limit = 100, int offset = 0}) async {
    final body = await _send(
      'GET',
      '/api/v1/platform/tenants',
      query: <String, String>{
        if (query.trim().isNotEmpty) 'q': query.trim(),
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    return asMapList(body['items']).map(TenantSummary.fromJson).toList();
  }

  Future<TenantDetail> tenant(String id) async {
    final body = await _send('GET', '/api/v1/platform/tenants/$id');
    return TenantDetail.fromJson(body);
  }

  Future<PlatformAiUsage> aiUsage({int days = 14}) async {
    final body = await _send(
      'GET',
      '/api/v1/platform/ai-usage',
      query: <String, String>{'days': '$days'},
    );
    return PlatformAiUsage.fromJson(body);
  }

  Future<PlatformMeta> meta() async {
    final body = await _send('GET', '/api/v1/platform/release-notes');
    return PlatformMeta.fromJson(body);
  }

  Future<Map<String, dynamic>> createAgent(
          String tenantId, Map<String, dynamic> data) =>
      _send('POST', '/api/v1/platform/tenants/$tenantId/agents', body: data);

  /// ------------------------------------------------------------------ writing

  Future<CreatedTenant> createTenant({
    required String name,
    String slug = '',
    required String ownerEmail,
    String ownerName = '',
    String ownerPassword = '',
    String inboxName = '',
    String publicKey = '',
    String plan = 'TRIAL',
    int trialDays = 0,
  }) async {
    final body = await _send(
      'POST',
      '/api/v1/platform/tenants',
      body: <String, dynamic>{
        'name': name,
        if (slug.isNotEmpty) 'slug': slug,
        'ownerEmail': ownerEmail,
        if (ownerName.isNotEmpty) 'ownerName': ownerName,
        if (ownerPassword.isNotEmpty) 'ownerPassword': ownerPassword,
        if (inboxName.isNotEmpty) 'inboxName': inboxName,
        if (publicKey.isNotEmpty) 'publicKey': publicKey,
        'plan': plan,
        if (trialDays > 0) 'trialDays': trialDays,
      },
    );
    return CreatedTenant.fromJson(body);
  }

  Future<void> updateTenant(
    String id, {
    String name = '',
    String status = '',
    String plan = '',
    String planStatus = '',
    int? seatLimit,
    int? monthlyMessageLimit,
    int? trialDays,
  }) async {
    await _send(
      'PATCH',
      '/api/v1/platform/tenants/$id',
      body: <String, dynamic>{
        if (name.isNotEmpty) 'name': name,
        if (status.isNotEmpty) 'status': status,
        if (plan.isNotEmpty) 'plan': plan,
        if (planStatus.isNotEmpty) 'planStatus': planStatus,
        if (seatLimit != null && seatLimit > 0) 'seatLimit': seatLimit,
        if (monthlyMessageLimit != null && monthlyMessageLimit > 0)
          'monthlyMessageLimit': monthlyMessageLimit,
        if (trialDays != null && trialDays > 0) 'trialDays': trialDays,
      },
    );
  }

  Future<void> extendTrial(String id, int days) async {
    await _send(
      'POST',
      '/api/v1/platform/tenants/$id/trial',
      body: <String, dynamic>{'days': days},
    );
  }

  /// Replaces a tenant's owner. Returns the password that is now in force, which
  /// the operator has to hand over: only the hash is stored.
  Future<String> resetOwner(
    String id, {
    required String email,
    String password = '',
  }) async {
    final body = await _send(
      'POST',
      '/api/v1/platform/tenants/$id/owner',
      body: <String, dynamic>{
        'email': email,
        if (password.isNotEmpty) 'password': password,
      },
    );
    return asString(body['password']);
  }

  /// ---------------------------------------------------------------- transport

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    bool authorized = true,
  }) async {
    if (_server.isEmpty) {
      throw const ApiException(
        statusCode: 0,
        code: 'SERVER_REQUIRED',
        message: '请填写服务器地址',
      );
    }
    var uri = Uri.parse('$_server$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: <String, String>{
        ...uri.queryParameters,
        ...query,
      });
    }
    final request = http.Request(method, uri);
    request.headers['Accept'] = 'application/json';
    if (authorized && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.bodyBytes = utf8.encode(jsonEncode(body));
    }
    try {
      final streamed = await _client.send(request).timeout(_timeout);
      return await _decode(streamed);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(
        statusCode: 0,
        code: 'TIMEOUT',
        message: '请求超时，请检查网络或服务器地址',
      );
    } catch (error) {
      throw ApiException(
        statusCode: 0,
        code: 'NETWORK_ERROR',
        message: '无法连接服务器：$error',
      );
    }
  }

  Future<Map<String, dynamic>> _decode(http.StreamedResponse response) async {
    final raw = await response.stream.bytesToString();
    Map<String, dynamic> decoded = const <String, dynamic>{};
    if (raw.isNotEmpty) {
      try {
        final parsed = jsonDecode(raw);
        if (parsed is Map<String, dynamic>) {
          decoded = parsed;
        }
      } on FormatException {
        // Handled by the status check below.
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }
    throw ApiException(
      statusCode: response.statusCode,
      code: asString(decoded['code']).isEmpty
          ? 'HTTP_${response.statusCode}'
          : asString(decoded['code']),
      message: asString(decoded['message']).isEmpty
          ? '请求失败（HTTP ${response.statusCode}）'
          : asString(decoded['message']),
    );
  }
}

