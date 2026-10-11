import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:relaydesk_agent_console/src/api/api_exception.dart';
import 'package:relaydesk_agent_console/src/api/models.dart';

/// Result of uploading an attachment.
class UploadedFile {
  const UploadedFile({
    required this.id,
    required this.fileName,
    required this.contentType,
    required this.sizeBytes,
    required this.url,
  });

  factory UploadedFile.fromJson(Map<String, dynamic> json) => UploadedFile(
        id: asString(json['id']),
        fileName: asString(json['fileName']),
        contentType: asString(json['contentType']),
        sizeBytes: asInt(json['sizeBytes']),
        url: asString(json['url']),
      );

  final String id;
  final String fileName;
  final String contentType;
  final int sizeBytes;
  final String url;
}

/// One page of messages plus the conversation's current sequence, which is the
/// cursor the console stores so a reconnect only asks for what it missed.
class MessagePage {
  const MessagePage({
    required this.items,
    required this.lastSequence,
    required this.agentUnread,
    this.hasMore = false,
    this.hasOlder = false,
    this.firstSequence = 0,
    this.lastReadSequence = 0,
    this.visitorUnread = 0,
  });

  final List<ChatMessage> items;
  final int lastSequence;
  final int agentUnread;

  /// There is a newer slice than this one, which the console reaches with
  /// `after:`.
  final bool hasMore;

  /// There is an older slice, which the console reaches with `before:` when the
  /// agent scrolls back.
  final bool hasOlder;

  /// Sequence bounds of this page. `firstSequence` is what a "load older" call
  /// passes back as its cursor.
  final int firstSequence;

  /// This agent's read cursor, which is where the "以下为新消息" divider belongs.
  final int lastReadSequence;

  /// How many messages the visitor has not read, shown on the thread header.
  final int visitorUnread;
}

class ConversationPage {
  const ConversationPage({required this.items, required this.queued});

  final List<Conversation> items;

  /// Conversations waiting for any agent, which the queue badge shows even when
  /// the list is filtered to "mine".
  final int queued;
}

/// The HTTP client for the agent console.
///
/// One instance per session. It owns the server origin and the bearer token, so
/// no call site has to thread either through. Requests that mutate state return
/// the parsed body; requests whose body the UI ignores still return it, so a
/// future screen can use it without touching this layer.
class RelayDeskApi {
  RelayDeskApi({required String server, http.Client? client})
      : _server = normalizeServer(server),
        _client = client ?? http.Client();

  final String _server;
  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 20);
  static const Duration _uploadTimeout = Duration(minutes: 5);

  /// The origin every path is relative to, without a trailing slash.
  String get server => _server;

  /// The bearer token, set once at sign-in and cleared on sign-out.
  String token = '';

  bool get hasToken => token.isNotEmpty;

  /// Accepts what a human types: `chat.example.com`, `http://localhost:8080/`,
  /// or a full URL with a path. A bare host gets `https://`, except localhost,
  /// which is certainly a development server.
  static String normalizeServer(String input) {
    var value = input.trim();
    if (value.isEmpty) {
      return '';
    }
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      final isLocal = value.startsWith('localhost') ||
          value.startsWith('127.0.0.1') ||
          value.startsWith('10.0.2.2');
      value = '${isLocal ? 'http' : 'https'}://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  void close() => _client.close();

  /// Absolute URL of a stored file, carrying the token so an <img> can load it
  /// without an Authorization header.
  String fileUrl(String url) {
    if (url.isEmpty) {
      return '';
    }
    final absolute = url.startsWith('http') ? url : '$_server$url';
    final separator = absolute.contains('?') ? '&' : '?';
    return '$absolute${separator}token=${Uri.encodeQueryComponent(token)}';
  }

  /// The WebSocket endpoint. Flutter has no Origin header to spoof, so the
  /// token alone authorizes the upgrade.
  Uri socketUri() {
    final base = _server.replaceFirst(RegExp('^http'), 'ws');
    return Uri.parse(
        '$base/ws/console?token=${Uri.encodeQueryComponent(token)}');
  }

  /// Tenant developer console. These endpoints require OWNER or ADMIN.
  Future<List<Map<String, dynamic>>> integrationInboxes() async =>
      asMapList((await _send('GET', '/api/v1/admin/inboxes'))['items']);

  Future<Map<String, dynamic>> inboxSnippet(String id) =>
      _send('GET', '/api/v1/admin/inboxes/${Uri.encodeComponent(id)}/snippet');

  Future<List<Map<String, dynamic>>> integrationKeys() async =>
      asMapList((await _send('GET', '/api/v1/admin/api-keys'))['items']);

  Future<Map<String, dynamic>> createIntegrationKey(
          String name, List<String> scopes) =>
      _send('POST', '/api/v1/admin/api-keys', body: <String, dynamic>{
        'name': name,
        'scopes': scopes,
      });

  Future<void> revokeIntegrationKey(String id) async {
    await _send('DELETE', '/api/v1/admin/api-keys/${Uri.encodeComponent(id)}');
  }

  Future<Map<String, dynamic>> integrationWebhooks() =>
      _send('GET', '/api/v1/admin/webhooks');

  Future<Map<String, dynamic>> createIntegrationWebhook(
          String url, List<String> events) =>
      _send('POST', '/api/v1/admin/webhooks', body: <String, dynamic>{
        'url': url,
        'events': events,
      });

  Future<void> deleteIntegrationWebhook(String id) async {
    await _send('DELETE', '/api/v1/admin/webhooks/${Uri.encodeComponent(id)}');
  }

  Future<void> testIntegrationWebhook(String id) async {
    await _send(
        'POST', '/api/v1/admin/webhooks/${Uri.encodeComponent(id)}/test');
  }

  Future<List<Map<String, dynamic>>> webhookDeliveries(String id) async =>
      asMapList((await _send('GET',
              '/api/v1/admin/webhooks/${Uri.encodeComponent(id)}/deliveries'))[
          'items']);

  /// ------------------------------------------------------------------ session

  Future<StoredSession> login({
    required String server,
    required String email,
    required String password,
    required String tenantSlug,
  }) async {
    final origin = normalizeServer(server);
    final body = await _send(
      'POST',
      '/api/v1/console/login',
      origin: origin,
      body: <String, dynamic>{
        'email': email,
        'password': password,
        'tenantSlug': tenantSlug,
      },
      authorized: false,
    );
    token = asString(body['token']);
    return StoredSession(
      server: origin,
      token: token,
      agent: AgentProfile.fromJson(asMap(body['agent'])),
      tenant: TenantInfo.fromJson(asMap(body['tenant'])),
      inboxes: asMapList(body['inboxes']).map(InboxInfo.fromJson).toList(),
    );
  }

  Future<void> logout() async {
    await _send('POST', '/api/v1/console/logout',
        body: const <String, dynamic>{});
  }

  Future<AgentProfile> me() async {
    final body = await _send('GET', '/api/v1/console/me');
    return AgentProfile.fromJson(body);
  }

  /// The presence call returns 200 and the console treats it as fire and forget:
  /// a dropped status update must never block the UI.
  Future<void> setPresence(String status) async {
    await _send(
      'POST',
      '/api/v1/console/me/presence',
      body: <String, dynamic>{'status': status},
    );
  }

  Future<void> updateProfile(String displayName) async {
    await _send(
      'PATCH',
      '/api/v1/console/me',
      body: <String, dynamic>{'displayName': displayName},
    );
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _send(
      'POST',
      '/api/v1/console/me/password',
      body: <String, dynamic>{
        'currentPassword': currentPassword,
        'newPassword': newPassword,
      },
    );
  }

  Future<List<InboxInfo>> inboxes() async {
    final body = await _send('GET', '/api/v1/console/inboxes');
    return asMapList(body['items']).map(InboxInfo.fromJson).toList();
  }

  /// ------------------------------------------------------------- conversations

  Future<ConversationPage> conversations({
    String filter = 'mine',
    String? inboxId,
    String? status,
    String? query,
    int limit = 30,
  }) async {
    final body = await _send(
      'GET',
      '/api/v1/console/conversations',
      query: <String, String>{
        'filter': filter,
        if (inboxId != null && inboxId.isNotEmpty) 'inboxId': inboxId,
        if (status != null && status.isNotEmpty) 'status': status,
        if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
        'limit': '$limit',
      },
    );
    return ConversationPage(
      items: asMapList(body['items']).map(Conversation.fromJson).toList(),
      queued: asInt(body['queued']),
    );
  }

  Future<ConversationDetail> conversation(String id) async {
    final body = await _send('GET', '/api/v1/console/conversations/$id');
    return ConversationDetail.fromJson(body);
  }

  /// Messages after [after] in ascending order, or the slice preceding [before]
  /// when the agent scrolls back through history. `after: 0` returns the oldest
  /// window, which is how the console fills a freshly opened thread.
  Future<MessagePage> messages(
    String id, {
    int after = 0,
    int before = 0,
    int limit = 50,
    String selfId = '',
  }) async {
    final body = await _send(
      'GET',
      '/api/v1/console/conversations/$id/messages',
      query: <String, String>{
        'after': '$after',
        if (before > 0) 'before': '$before',
        'limit': '$limit',
      },
    );
    return MessagePage(
      items: asMapList(body['items'])
          .map((item) => ChatMessage.fromJson(item, selfId: selfId))
          .toList(),
      lastSequence: asInt(body['lastSequence']),
      agentUnread: asInt(body['agentUnread']),
      hasMore: asBool(body['hasMore']),
      hasOlder: asBool(body['hasOlder']),
      firstSequence: asInt(body['firstSequence']),
      lastReadSequence: asInt(body['lastReadSequence']),
      visitorUnread: asInt(body['visitorUnread']),
    );
  }

  /// Searches the open thread. The server returns excerpts with the matched
  /// terms already wrapped in `<< >>`, having run the same tokenizer that
  /// indexed the message, so the highlight is exactly what was matched rather
  /// than a client-side guess at Chinese word boundaries.
  Future<List<SearchHit>> searchConversation(
    String id, {
    required String query,
    int limit = 30,
  }) async {
    final body = await _send(
      'GET',
      '/api/v1/console/conversations/$id/search',
      query: <String, String>{'q': query, 'limit': '$limit'},
    );
    return asMapList(body['items']).map(SearchHit.fromJson).toList();
  }

  /// The pinned messages of a conversation, used to draw the pin bar before any
  /// messages have loaded.
  Future<List<ChatMessage>> pins(String id, {String selfId = ''}) async {
    final body = await _send(
      'GET',
      '/api/v1/console/conversations/$id/pins',
    );
    return asMapList(body['items'])
        .map((item) => ChatMessage.fromJson(item, selfId: selfId))
        .toList();
  }

  /// Pins or unpins a message. Returns the resulting pin bar so the caller
  /// re-renders from authoritative state rather than from the request it made.
  Future<List<ChatMessage>> setPinned(
    String conversationId,
    String messageId, {
    required bool pinned,
    String selfId = '',
  }) async {
    final body = await _send(
      'POST',
      '/api/v1/console/conversations/$conversationId/messages/$messageId/pin',
      body: <String, dynamic>{'pinned': pinned},
    );
    return asMapList(body['items'])
        .map((item) => ChatMessage.fromJson(item, selfId: selfId))
        .toList();
  }

  /// Toggles one emoji on a message. The endpoint removes the reaction when it
  /// is already there, so the same call adds and removes, and the response
  /// carries the full aggregate for the message.
  Future<List<MessageReaction>> toggleReaction(
    String conversationId,
    String messageId, {
    required String emoji,
    String selfId = '',
  }) async {
    final body = await _send(
      'POST',
      '/api/v1/console/conversations/$conversationId/messages/$messageId/reactions',
      body: <String, dynamic>{'emoji': emoji},
    );
    return asMapList(body['reactions'])
        .map((item) => MessageReaction.fromJson(item, selfId))
        .toList();
  }

  /// Rewrites the text of a message the caller wrote. The server refuses an edit
  /// by anyone but the author, and a tenant manager correcting a record.
  Future<ChatMessage> editMessage(
    String conversationId,
    String messageId, {
    required String content,
    String selfId = '',
  }) async {
    final body = await _send(
      'PATCH',
      '/api/v1/console/conversations/$conversationId/messages/$messageId',
      body: <String, dynamic>{'content': content},
    );
    return ChatMessage.fromJson(body, selfId: selfId);
  }

  /// Recalls a message. It keeps its row and its sequence so a client that
  /// already rendered it replaces the bubble instead of shifting the transcript.
  Future<ChatMessage> deleteMessage(
    String conversationId,
    String messageId, {
    String selfId = '',
  }) async {
    final body = await _send(
      'DELETE',
      '/api/v1/console/conversations/$conversationId/messages/$messageId',
    );
    return ChatMessage.fromJson(body, selfId: selfId);
  }

  /// The draft this agent left in a conversation, so switching threads does not
  /// lose a half-written answer.
  Future<String> draft(String conversationId) async {
    final body = await _send(
      'GET',
      '/api/v1/console/conversations/$conversationId/draft',
    );
    return asString(body['content']);
  }

  /// Saves the draft, or clears it when [content] is blank — which is what the
  /// server does with an empty body, rather than keeping a row every console
  /// would have to filter out.
  Future<void> saveDraft(String conversationId, String content) async {
    await _send(
      'PUT',
      '/api/v1/console/conversations/$conversationId/draft',
      body: <String, dynamic>{'content': content},
    );
  }

  /// Reports the highest sequence this console holds, which lets the agent's
  /// screen distinguish "delivered" from "read" for the visitor. Delivery is
  /// separate from reading: a thread opened in a background tab has received
  /// the message without anyone having looked at it.
  Future<void> markDelivered(String conversationId, {int sequence = 0}) async {
    await _send(
      'POST',
      '/api/v1/console/conversations/$conversationId/delivered',
      body: <String, dynamic>{'sequence': sequence},
    );
  }

  /// Copies a message into another conversation, recording where it came from.
  Future<ChatMessage> forwardMessage(
    String conversationId,
    String messageId, {
    required String targetConversationId,
    String note = '',
    String selfId = '',
  }) async {
    final body = await _send(
      'POST',
      '/api/v1/console/conversations/$conversationId/messages/$messageId/forward',
      body: <String, dynamic>{
        'conversationId': targetConversationId,
        'note': note,
      },
    );
    return ChatMessage.fromJson(body, selfId: selfId);
  }

  /// Sends a reply. [clientMessageId] makes the send idempotent, so a retry
  /// after a timeout cannot post the same answer twice. [replyToId] turns the
  /// send into a quote.
  Future<ChatMessage> send({
    required String conversationId,
    required String content,
    required String clientMessageId,
    String messageType = 'TEXT',
    List<String> attachmentIds = const <String>[],
    bool private = false,
    String? replyToId,
    Map<String, dynamic>? metadata,
    String selfId = '',
  }) async {
    final body = await _send(
      'POST',
      '/api/v1/console/conversations/$conversationId/messages',
      body: <String, dynamic>{
        'content': content,
        'clientMessageId': clientMessageId,
        'messageType': messageType,
        'attachmentIds': attachmentIds,
        'private': private,
        if (replyToId != null && replyToId.isNotEmpty) 'replyToId': replyToId,
        if (metadata != null) 'metadata': metadata,
      },
    );
    return ChatMessage.fromJson(body, selfId: selfId);
  }

  /// Claims the conversation for the caller. The endpoint answers with a bare
  /// acknowledgement, so the caller re-reads the conversation for the new
  /// assignee rather than guessing it from the reply.
  ///
  /// Throws a 409 [ApiException] when somebody else got there first, which is
  /// information an agent needs rather than an error to swallow.
  Future<void> claim(String conversationId) async {
    await _send(
      'POST',
      '/api/v1/console/conversations/$conversationId/claim',
      body: const <String, dynamic>{},
    );
  }

  Future<void> transfer({
    required String conversationId,
    required String agentId,
    String note = '',
  }) async {
    await _send(
      'POST',
      '/api/v1/console/conversations/$conversationId/transfer',
      body: <String, dynamic>{'agentId': agentId, 'note': note},
    );
  }

  Future<void> setStatus(String conversationId, String status) async {
    await _send(
      'POST',
      '/api/v1/console/conversations/$conversationId/status',
      body: <String, dynamic>{'status': status},
    );
  }

  Future<void> markRead(String conversationId, {int sequence = 0}) async {
    await _send(
      'POST',
      '/api/v1/console/conversations/$conversationId/read',
      body: <String, dynamic>{'sequence': sequence},
    );
  }

  Future<void> typing(String conversationId) async {
    await _send(
      'POST',
      '/api/v1/console/conversations/$conversationId/typing',
      body: const <String, dynamic>{},
    );
  }

  Future<List<String>> setTags(String conversationId, List<String> tags) async {
    final body = await _send(
      'POST',
      '/api/v1/console/conversations/$conversationId/tags',
      body: <String, dynamic>{'tags': tags},
    );
    return (body['tags'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<String>()
        .toList(growable: false);
  }

  Future<void> setPriority(String conversationId, int priority) async {
    await _send(
      'POST',
      '/api/v1/console/conversations/$conversationId/priority',
      body: <String, dynamic>{'priority': priority},
    );
  }

  /// -------------------------------------------------------------- attachments

  Future<UploadedFile> upload({
    required String conversationId,
    required String fileName,
    required Uint8List bytes,
    required String contentType,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$_server/api/v1/uploads?conversationId=$conversationId'),
    );
    if (token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: fileName,
        contentType: _parseMediaType(contentType),
      ),
    );
    final streamed = await _client.send(request).timeout(_uploadTimeout);
    final body = await _decode(streamed);
    return UploadedFile.fromJson(body);
  }

  /// --------------------------------------------------------- customer records

  Future<VisitorProfile> visitor(String id) async {
    final body = await _send('GET', '/api/v1/console/visitors/$id');
    return VisitorProfile.fromJson(body);
  }

  Future<void> updateVisitor({
    required String id,
    String displayName = '',
    Map<String, dynamic>? attributes,
  }) async {
    await _send(
      'PATCH',
      '/api/v1/console/visitors/$id',
      body: <String, dynamic>{
        'displayName': displayName,
        if (attributes != null) 'attributes': attributes,
      },
    );
  }

  Future<List<Conversation>> visitorConversations(String id) async {
    final body =
        await _send('GET', '/api/v1/console/visitors/$id/conversations');
    return asMapList(body['items']).map(Conversation.fromJson).toList();
  }

  Future<VisitorNote> addNote(String visitorId, String content) async {
    final body = await _send(
      'POST',
      '/api/v1/console/visitors/$visitorId/notes',
      body: <String, dynamic>{'content': content},
    );
    return VisitorNote.fromJson(body);
  }

  Future<List<VisitorNote>> notes(String visitorId) async {
    final body =
        await _send('GET', '/api/v1/console/visitors/$visitorId/notes');
    return asMapList(body['items']).map(VisitorNote.fromJson).toList();
  }

  /// ------------------------------------------------------------- productivity

  Future<List<CannedResponse>> cannedResponses() async {
    final body = await _send('GET', '/api/v1/console/canned-responses');
    return asMapList(body['items']).map(CannedResponse.fromJson).toList();
  }

  Future<CannedResponse> createCannedResponse({
    required String title,
    required String content,
    String? inboxId,
  }) async {
    final body = await _send(
      'POST',
      '/api/v1/console/canned-responses',
      body: <String, dynamic>{
        'title': title,
        'content': content,
        if (inboxId != null && inboxId.isNotEmpty) 'inboxId': inboxId,
      },
    );
    return CannedResponse.fromJson(body);
  }

  Future<void> updateCannedResponse({
    required String id,
    String title = '',
    String content = '',
  }) async {
    await _send(
      'PATCH',
      '/api/v1/console/canned-responses/$id',
      body: <String, dynamic>{'title': title, 'content': content},
    );
  }

  Future<void> deleteCannedResponse(String id) async {
    await _send('DELETE', '/api/v1/console/canned-responses/$id');
  }

  Future<List<TagInfo>> tags() async {
    final body = await _send('GET', '/api/v1/console/tags');
    return asMapList(body['items']).map(TagInfo.fromJson).toList();
  }

  Future<List<AgentSummary>> agents() async {
    final body = await _send('GET', '/api/v1/console/agents');
    return asMapList(body['items']).map(AgentSummary.fromJson).toList();
  }

  Future<StatsOverview> stats({int days = 14}) async {
    final body = await _send(
      'GET',
      '/api/v1/console/stats/overview',
      query: <String, String>{'days': '$days'},
    );
    return StatsOverview.fromJson(body);
  }

  /// ----------------------------------------------------------------- knowledge

  Future<List<KnowledgeEntry>> knowledge({String query = ''}) async {
    final body = await _send(
      'GET',
      '/api/v1/console/knowledge',
      query: <String, String>{if (query.trim().isNotEmpty) 'q': query.trim()},
    );
    return asMapList(body['items']).map(KnowledgeEntry.fromJson).toList();
  }

  /// Creates an entry and returns its id. The server stores the example
  /// phrasings as one newline-separated block of text, so the list is joined
  /// here; the console is the only place that thinks of them as separate lines.
  Future<String> createKnowledge({
    required String title,
    required String content,
    List<String> questionExamples = const <String>[],
  }) async {
    final body = await _send(
      'POST',
      '/api/v1/console/knowledge',
      body: <String, dynamic>{
        'title': title,
        'content': content,
        'questionExamples': joinExamples(questionExamples),
      },
    );
    return asString(body['id']);
  }

  Future<void> updateKnowledge({
    required String id,
    String title = '',
    String content = '',
    List<String>? questionExamples,
  }) async {
    await _send(
      'PATCH',
      '/api/v1/console/knowledge/$id',
      body: <String, dynamic>{
        'title': title,
        'content': content,
        if (questionExamples != null)
          'questionExamples': joinExamples(questionExamples),
      },
    );
  }

  Future<void> deleteKnowledge(String id) async {
    await _send('DELETE', '/api/v1/console/knowledge/$id');
  }

  /// Asks the AI to answer a question, spending a model call. Used to verify the
  /// knowledge base before going live.
  Future<KnowledgeAnswer> previewAnswer(String question) async {
    final body = await _send(
      'POST',
      '/api/v1/console/knowledge/search',
      body: <String, dynamic>{'question': question},
    );
    return KnowledgeAnswer.fromJson(body);
  }

  /// Runs retrieval without a model call, answering "would the knowledge base
  /// have anything for this?" for free.
  Future<List<KnowledgeHit>> previewRetrieval(String question) async {
    final body = await _send(
      'POST',
      '/api/v1/console/knowledge/preview',
      body: <String, dynamic>{'question': question},
    );
    return asMapList(body['items']).map(KnowledgeHit.fromJson).toList();
  }

  /// ---------------------------------------------------------------- transport

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    String? origin,
    bool authorized = true,
  }) async {
    final base = origin ?? _server;
    if (base.isEmpty) {
      throw const ApiException(
        statusCode: 0,
        code: 'SERVER_REQUIRED',
        message: '请填写服务器地址',
      );
    }
    var uri = Uri.parse('$base$path');
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

  /// Turns a response into a map, or into an [ApiException] carrying the
  /// server's machine-readable code.
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
        // A non-JSON body only matters when the status is bad; below, the code
        // falls back to the HTTP status.
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

/// Builds a content type for multipart uploads without pulling in the `http_parser`
/// dependency for one line of parsing.
http.MediaType? _parseMediaType(String value) {
  final parts = value.split('/');
  if (parts.length != 2) {
    return null;
  }
  return http.MediaType(parts[0], parts[1]);
}
