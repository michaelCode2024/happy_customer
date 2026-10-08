/// Wire models for the agent console.
///
/// Every class is a plain immutable value with an explicit `fromJson`. No code
/// generation: the shapes are small, and hand-written parsers make the optional
/// fields (a conversation may or may not have an assignee, a visitor may or may
/// not have an email) impossible to get wrong silently.
library;

/// Coerces a JSON value to a String, treating null as empty.
String asString(Object? value) => value is String ? value : '';

/// Coerces a JSON value to a String, returning null when absent or blank.
String? asNullableString(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return value;
}

int asInt(Object? value) => switch (value) {
      int() => value,
      num() => value.toInt(),
      String() => int.tryParse(value) ?? 0,
      _ => 0,
    };

double asDouble(Object? value) => switch (value) {
      num() => value.toDouble(),
      String() => double.tryParse(value) ?? 0,
      _ => 0,
    };

bool asBool(Object? value) => switch (value) {
      bool() => value,
      String() => value == 'true',
      num() => value != 0,
      _ => false,
    };

Map<String, dynamic> asMap(Object? value) =>
    value is Map<String, dynamic> ? value : const <String, dynamic>{};

List<Map<String, dynamic>> asMapList(Object? value) {
  if (value is! List) {
    return const <Map<String, dynamic>>[];
  }
  return value.whereType<Map<String, dynamic>>().toList(growable: false);
}

/// Timestamps arrive as RFC 3339 in UTC; the UI always shows local time.
DateTime? asDate(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value)?.toLocal();
}

/// ------------------------------------------------------------------ identity

class AgentProfile {
  const AgentProfile({
    required this.id,
    required this.email,
    required this.displayName,
    required this.role,
    this.presence,
  });

  factory AgentProfile.fromJson(Map<String, dynamic> json) => AgentProfile(
        id: asString(json['id']),
        email: asString(json['email']),
        displayName: asString(json['displayName']),
        role: asString(json['role']),
        presence: asNullableString(json['presence']),
      );

  final String id;
  final String email;
  final String displayName;

  /// OWNER, ADMIN, SUPERVISOR or AGENT.
  final String role;

  /// ONLINE, AWAY, OFFLINE, or null before the first presence frame.
  final String? presence;

  bool get canManageKnowledge =>
      role == 'OWNER' || role == 'ADMIN' || role == 'SUPERVISOR';

  bool get canViewReports =>
      role == 'OWNER' || role == 'ADMIN' || role == 'SUPERVISOR';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'email': email,
        'displayName': displayName,
        'role': role,
        if (presence != null) 'presence': presence,
      };
}

class TenantInfo {
  const TenantInfo({required this.id, required this.name});

  factory TenantInfo.fromJson(Map<String, dynamic> json) => TenantInfo(
        id: asString(json['id']),
        name: asString(json['name']),
      );

  final String id;
  final String name;

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, 'name': name};
}

class InboxInfo {
  const InboxInfo({
    required this.id,
    required this.name,
    required this.publicKey,
    required this.autoAssign,
    required this.aiEnabled,
  });

  factory InboxInfo.fromJson(Map<String, dynamic> json) => InboxInfo(
        id: asString(json['id']),
        name: asString(json['name']),
        publicKey: asString(json['publicKey']),
        autoAssign: asBool(json['autoAssign']),
        aiEnabled: asBool(json['aiEnabled']),
      );

  final String id;
  final String name;
  final String publicKey;
  final bool autoAssign;
  final bool aiEnabled;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'publicKey': publicKey,
        'autoAssign': autoAssign,
        'aiEnabled': aiEnabled,
      };
}

/// What the login response and the persisted session have in common.
class StoredSession {
  const StoredSession({
    required this.server,
    required this.token,
    required this.agent,
    required this.tenant,
    required this.inboxes,
  });

  final String server;
  final String token;
  final AgentProfile agent;
  final TenantInfo tenant;
  final List<InboxInfo> inboxes;

  StoredSession copyWith({
    String? server,
    String? token,
    AgentProfile? agent,
    TenantInfo? tenant,
    List<InboxInfo>? inboxes,
  }) =>
      StoredSession(
        server: server ?? this.server,
        token: token ?? this.token,
        agent: agent ?? this.agent,
        tenant: tenant ?? this.tenant,
        inboxes: inboxes ?? this.inboxes,
      );
}

/// ----------------------------------------------------------------- messages

class Attachment {
  const Attachment({
    required this.id,
    required this.fileName,
    required this.contentType,
    required this.sizeBytes,
    required this.url,
  });

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
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

  bool get isImage => contentType.startsWith('image/');

  bool get isVideo => contentType.startsWith('video/');

  bool get isAudio => contentType.startsWith('audio/');

  /// A human-readable size for the file bubble.
  String get readableSize {
    if (sizeBytes < 1024) {
      return '$sizeBytes B';
    }
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderType,
    required this.senderId,
    required this.senderName,
    required this.clientMessageId,
    required this.sequence,
    required this.messageType,
    required this.content,
    required this.attachments,
    required this.metadata,
    required this.createdAt,
    this.delivery = DeliveryState.sent,
    this.error,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: asString(json['id']),
        conversationId: asString(json['conversationId']),
        senderType: asString(json['senderType']),
        senderId: asNullableString(json['senderId']),
        senderName: asString(json['senderName']),
        clientMessageId: asNullableString(json['clientMessageId']),
        sequence: asInt(json['sequence']),
        messageType: asString(json['messageType']),
        content: asString(json['content']),
        attachments: asMapList(json['attachments'])
            .map(Attachment.fromJson)
            .toList(growable: false),
        metadata: asMap(json['metadata']),
        createdAt: asDate(json['createdAt']) ?? DateTime.now(),
        delivery: DeliveryState.sent,
      );

  /// A locally created message that has not been acknowledged yet. [localId] is
  /// the idempotency key sent to the server, so a retry cannot duplicate it.
  factory ChatMessage.optimistic({
    required String localId,
    required String conversationId,
    required String content,
    required String messageType,
    required List<Attachment> attachments,
    String senderType = 'AGENT',
    String senderName = '',
    String? senderId,
    bool isPrivate = false,
  }) =>
      ChatMessage(
        id: localId,
        conversationId: conversationId,
        senderType: senderType,
        senderId: senderId,
        senderName: senderName,
        clientMessageId: localId,
        sequence: 0,
        messageType: isPrivate ? 'EVENT' : messageType,
        content: content,
        attachments: attachments,
        metadata: isPrivate ? const <String, dynamic>{'private': true} : const <String, dynamic>{},
        createdAt: DateTime.now(),
        delivery: DeliveryState.sending,
      );

  final String id;
  final String conversationId;

  /// VISITOR, AGENT or SYSTEM.
  final String senderType;
  final String? senderId;
  final String senderName;
  final String? clientMessageId;
  final int sequence;

  /// TEXT, IMAGE, FILE, EVENT, SYSTEM, RICH, RATING.
  final String messageType;
  final String content;
  final List<Attachment> attachments;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;
  final DeliveryState delivery;
  final String? error;

  bool get isFromVisitor => senderType == 'VISITOR';

  bool get isFromAgent => senderType == 'AGENT';

  bool get isSystem => senderType == 'SYSTEM';

  /// Internal notes are stored as EVENT messages flagged in metadata so they are
  /// never delivered to the visitor, but are visible to the whole team.
  bool get isPrivate => asBool(metadata['private']);

  bool get isTransfer =>
      asBool(metadata['transfer']) || asBool(metadata['ai_handoff']);

  bool get isAi => asBool(metadata['ai']) || senderId == 'bot';

  ChatMessage copyWith({
    int? sequence,
    DeliveryState? delivery,
    String? error,
    List<Attachment>? attachments,
  }) =>
      ChatMessage(
        id: id,
        conversationId: conversationId,
        senderType: senderType,
        senderId: senderId,
        senderName: senderName,
        clientMessageId: clientMessageId,
        sequence: sequence ?? this.sequence,
        messageType: messageType,
        content: content,
        attachments: attachments ?? this.attachments,
        metadata: metadata,
        createdAt: createdAt,
        delivery: delivery ?? this.delivery,
        error: error ?? this.error,
      );
}

/// The lifecycle of an outgoing message on the agent's screen.
enum DeliveryState { sending, sent, failed }

/// ----------------------------------------------------------------- conversations

class Conversation {
  const Conversation({
    required this.id,
    required this.inboxId,
    required this.visitorId,
    required this.subject,
    required this.status,
    required this.assigneeId,
    required this.assigneeName,
    required this.priority,
    required this.source,
    required this.lastSequence,
    required this.lastMessagePreview,
    required this.lastMessageAt,
    required this.agentUnread,
    required this.visitorUnread,
    required this.visitorName,
    required this.tags,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: asString(json['id']),
        inboxId: asString(json['inboxId']),
        visitorId: asString(json['visitorId']),
        subject: asString(json['subject']),
        status: asString(json['status']),
        assigneeId: asNullableString(json['assigneeId']),
        assigneeName: asString(json['assigneeName']),
        priority: asInt(json['priority']),
        source: asString(json['source']),
        lastSequence: asInt(json['lastSequence']),
        lastMessagePreview: asString(json['lastMessagePreview']),
        lastMessageAt: asDate(json['lastMessageAt']),
        agentUnread: asInt(json['agentUnread']),
        visitorUnread: asInt(json['visitorUnread']),
        visitorName: asString(json['visitorName']),
        tags: (json['tags'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<String>()
            .toList(growable: false),
        createdAt: asDate(json['createdAt']) ?? DateTime.now(),
        updatedAt: asDate(json['updatedAt']) ?? DateTime.now(),
      );

  final String id;
  final String inboxId;
  final String visitorId;
  final String subject;

  /// OPEN, PENDING or RESOLVED.
  final String status;
  final String? assigneeId;
  final String assigneeName;
  final int priority;
  final String source;
  final int lastSequence;
  final String lastMessagePreview;
  final DateTime? lastMessageAt;
  final int agentUnread;
  final int visitorUnread;
  final String visitorName;
  final List<String> tags;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isResolved => status == 'RESOLVED';

  bool get isUnassigned => assigneeId == null || assigneeId!.isEmpty;

  /// What the list row shows as the title: the subject if the visitor gave one,
  /// otherwise the visitor's own name, otherwise the newest message.
  String get title {
    if (subject.trim().isNotEmpty) {
      return subject.trim();
    }
    if (visitorName.trim().isNotEmpty) {
      return visitorName.trim();
    }
    if (lastMessagePreview.trim().isNotEmpty) {
      return lastMessagePreview.trim();
    }
    return '访客会话';
  }

  Conversation copyWith({
    String? status,
    String? assigneeId,
    String? assigneeName,
    int? priority,
    int? agentUnread,
    int? lastSequence,
    String? lastMessagePreview,
    DateTime? lastMessageAt,
    List<String>? tags,
    bool clearAssignee = false,
  }) =>
      Conversation(
        id: id,
        inboxId: inboxId,
        visitorId: visitorId,
        subject: subject,
        status: status ?? this.status,
        assigneeId: clearAssignee ? null : (assigneeId ?? this.assigneeId),
        assigneeName: assigneeName ?? this.assigneeName,
        priority: priority ?? this.priority,
        source: source,
        lastSequence: lastSequence ?? this.lastSequence,
        lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
        agentUnread: agentUnread ?? this.agentUnread,
        visitorUnread: visitorUnread,
        visitorName: visitorName,
        tags: tags ?? this.tags,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

class VisitorProfile {
  const VisitorProfile({
    required this.id,
    required this.displayName,
    required this.externalId,
    required this.email,
    required this.phone,
    required this.attributes,
    required this.lastSeenAt,
    required this.createdAt,
    required this.conversationCount,
    required this.ratingAverage,
  });

  factory VisitorProfile.fromJson(Map<String, dynamic> json) => VisitorProfile(
        id: asString(json['id']),
        displayName: asString(json['displayName']),
        externalId: asString(json['externalId']),
        email: asString(json['email']),
        phone: asString(json['phone']),
        attributes: asMap(json['attributes']),
        lastSeenAt: asDate(json['lastSeenAt']),
        createdAt: asDate(json['createdAt']),
        conversationCount: asInt(json['conversationCount']),
        ratingAverage: json['ratingAverage'] == null
            ? null
            : asDouble(json['ratingAverage']),
      );

  final String id;
  final String displayName;
  final String externalId;
  final String email;
  final String phone;
  final Map<String, dynamic> attributes;
  final DateTime? lastSeenAt;
  final DateTime? createdAt;
  final int conversationCount;
  final double? ratingAverage;

  String get label =>
      displayName.trim().isNotEmpty ? displayName.trim() : '匿名访客';
}

class VisitorNote {
  const VisitorNote({
    required this.id,
    required this.content,
    required this.authorName,
    required this.createdAt,
  });

  factory VisitorNote.fromJson(Map<String, dynamic> json) => VisitorNote(
        id: asString(json['id']),
        content: asString(json['content']),
        authorName: asString(json['authorName']),
        createdAt: asDate(json['createdAt']) ?? DateTime.now(),
      );

  final String id;
  final String content;
  final String authorName;
  final DateTime createdAt;
}

class ConversationRating {
  const ConversationRating({
    required this.score,
    required this.comment,
    required this.createdAt,
  });

  factory ConversationRating.fromJson(Map<String, dynamic> json) =>
      ConversationRating(
        score: asInt(json['score']),
        comment: asNullableString(json['comment']),
        createdAt: asDate(json['createdAt']),
      );

  final int score;
  final String? comment;
  final DateTime? createdAt;
}

/// The detail endpoint bundles the conversation with its customer and rating.
class ConversationDetail {
  const ConversationDetail({
    required this.conversation,
    required this.visitor,
    required this.rating,
  });

  factory ConversationDetail.fromJson(Map<String, dynamic> json) =>
      ConversationDetail(
        conversation: Conversation.fromJson(asMap(json['conversation'])),
        visitor: json['visitor'] == null
            ? null
            : VisitorProfile.fromJson(asMap(json['visitor'])),
        rating: json['rating'] == null
            ? null
            : ConversationRating.fromJson(asMap(json['rating'])),
      );

  final Conversation conversation;
  final VisitorProfile? visitor;
  final ConversationRating? rating;
}

/// ----------------------------------------------------------------- productivity

class AgentSummary {
  const AgentSummary({
    required this.id,
    required this.displayName,
    required this.email,
    required this.role,
    required this.presence,
    required this.lastSeenAt,
    required this.openConversations,
  });

  factory AgentSummary.fromJson(Map<String, dynamic> json) => AgentSummary(
        id: asString(json['id']),
        displayName: asString(json['displayName']),
        email: asString(json['email']),
        role: asString(json['role']),
        presence: asString(json['presence']),
        lastSeenAt: asDate(json['lastSeenAt']),
        openConversations: asInt(json['openConversations']),
      );

  final String id;
  final String displayName;
  final String email;
  final String role;
  final String presence;
  final DateTime? lastSeenAt;
  final int openConversations;

  bool get isOnline => presence == 'ONLINE';
}

class CannedResponse {
  const CannedResponse({
    required this.id,
    required this.title,
    required this.content,
    this.inboxId,
  });

  factory CannedResponse.fromJson(Map<String, dynamic> json) => CannedResponse(
        id: asString(json['id']),
        title: asString(json['title']),
        content: asString(json['content']),
        inboxId: asNullableString(json['inboxId']),
      );

  final String id;
  final String title;
  final String content;
  final String? inboxId;

  /// A canned response with no inbox applies everywhere.
  bool appliesTo(String inboxIdValue) => inboxId == null || inboxId == inboxIdValue;
}

class TagInfo {
  const TagInfo({
    required this.id,
    required this.name,
    required this.color,
    required this.conversations,
  });

  factory TagInfo.fromJson(Map<String, dynamic> json) => TagInfo(
        id: asString(json['id']),
        name: asString(json['name']),
        color: asString(json['color']),
        conversations: asInt(json['conversations']),
      );

  final String id;
  final String name;
  final String color;
  final int conversations;
}

/// ----------------------------------------------------------------- knowledge

class KnowledgeEntry {
  const KnowledgeEntry({
    required this.id,
    required this.title,
    required this.content,
    required this.questionExamples,
    required this.status,
    required this.hitCount,
    required this.updatedAt,
  });

  factory KnowledgeEntry.fromJson(Map<String, dynamic> json) => KnowledgeEntry(
        id: asString(json['id']),
        title: asString(json['title']),
        content: asString(json['content']),
        // The server keeps the example phrasings as one text block, one per
        // line; the console edits them as a list.
        questionExamples: splitExamples(asString(json['questionExamples'])),
        status: asString(json['status']),
        hitCount: asInt(json['hitCount']),
        updatedAt: asDate(json['updatedAt']),
      );

  final String id;
  final String title;
  final String content;
  final List<String> questionExamples;
  final String status;
  final int hitCount;
  final DateTime? updatedAt;
}

/// Splits the stored example block into individual phrasings, dropping blanks so
/// a trailing newline does not become an empty chip.
List<String> splitExamples(String raw) => raw
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .toList(growable: false);

/// The inverse of [splitExamples], as the server stores them.
String joinExamples(List<String> examples) => examples
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .join('\n');

/// A retrieval hit: which entry matched and how strongly.
class KnowledgeHit {
  const KnowledgeHit({
    required this.id,
    required this.title,
    required this.content,
    required this.score,
  });

  factory KnowledgeHit.fromJson(Map<String, dynamic> json) => KnowledgeHit(
        id: asString(json['id']),
        title: asString(json['title']),
        content: asString(json['content']),
        score: asDouble(json['score']),
      );

  final String id;
  final String title;
  final String content;
  final double score;
}

class KnowledgeAnswer {
  const KnowledgeAnswer({
    required this.answer,
    required this.score,
    required this.provider,
    required this.handoff,
    required this.reason,
    required this.sources,
  });

  factory KnowledgeAnswer.fromJson(Map<String, dynamic> json) => KnowledgeAnswer(
        answer: asString(json['answer']),
        score: asDouble(json['score']),
        provider: asString(json['provider']),
        handoff: asBool(json['handoff']),
        reason: asString(json['reason']),
        sources: asMapList(json['sources'])
            .map(KnowledgeHit.fromJson)
            .toList(growable: false),
      );

  final String answer;
  final double score;
  final String provider;
  final bool handoff;
  final String reason;
  final List<KnowledgeHit> sources;
}

/// ----------------------------------------------------------------- statistics

class StatPoint {
  const StatPoint({
    required this.date,
    required this.conversationsStarted,
    required this.conversationsClosed,
    required this.messagesIn,
    required this.messagesOut,
    required this.aiAnswered,
    required this.aiHandoff,
    required this.avgFirstResponseSeconds,
  });

  factory StatPoint.fromJson(Map<String, dynamic> json) => StatPoint(
        date: asString(json['date']),
        conversationsStarted: asInt(json['conversationsStarted']),
        conversationsClosed: asInt(json['conversationsClosed']),
        messagesIn: asInt(json['messagesIn']),
        messagesOut: asInt(json['messagesOut']),
        aiAnswered: asInt(json['aiAnswered']),
        aiHandoff: asInt(json['aiHandoff']),
        avgFirstResponseSeconds: asDouble(json['avgFirstResponseSeconds']),
      );

  final String date;
  final int conversationsStarted;
  final int conversationsClosed;
  final int messagesIn;
  final int messagesOut;
  final int aiAnswered;
  final int aiHandoff;
  final double avgFirstResponseSeconds;
}

class LeaderboardRow {
  const LeaderboardRow({
    required this.agentId,
    required this.displayName,
    required this.resolved,
    required this.open,
    required this.avgFirstResponseSeconds,
    required this.avgRating,
  });

  factory LeaderboardRow.fromJson(Map<String, dynamic> json) => LeaderboardRow(
        agentId: asString(json['agentId']),
        displayName: asString(json['displayName']),
        resolved: asInt(json['resolved']),
        open: asInt(json['open']),
        avgFirstResponseSeconds: asInt(json['avgFirstResponseSeconds']),
        avgRating: asDouble(json['avgRating']),
      );

  final String agentId;
  final String displayName;
  final int resolved;
  final int open;
  final int avgFirstResponseSeconds;
  final double avgRating;
}

/// The statistics endpoint answers with one of two shapes depending on the
/// caller's role: an ordinary agent only sees their own queue, while reports
/// roles get the tenant-wide dashboard. Both are modelled here, and [scope]
/// says which one arrived.
class StatsOverview {
  const StatsOverview({
    required this.scope,
    required this.openConversations,
    required this.queued,
    required this.onlineAgents,
    required this.conversationsStarted,
    required this.conversationsClosed,
    required this.messagesIn,
    required this.messagesOut,
    required this.aiAnswered,
    required this.aiHandoff,
    required this.aiDeflectionRate,
    required this.avgFirstResponseSeconds,
    required this.avgRating,
    required this.days,
    required this.series,
    required this.leaderboard,
  });

  factory StatsOverview.fromJson(Map<String, dynamic> json) => StatsOverview(
        scope: asString(json['scope']),
        openConversations: asInt(json['openConversations']),
        queued: asInt(json['queued']),
        onlineAgents: asInt(json['onlineAgents']),
        conversationsStarted: asInt(json['conversationsStarted']),
        conversationsClosed: asInt(json['conversationsClosed']),
        messagesIn: asInt(json['messagesIn']),
        messagesOut: asInt(json['messagesOut']),
        aiAnswered: asInt(json['aiAnswered']),
        aiHandoff: asInt(json['aiHandoff']),
        aiDeflectionRate: asDouble(json['aiDeflectionRate']),
        avgFirstResponseSeconds: asDouble(json['avgFirstResponseSeconds']),
        avgRating: asDouble(json['avgRating']),
        days: asInt(json['days']),
        series: asMapList(json['series'])
            .map(StatPoint.fromJson)
            .toList(growable: false),
        leaderboard: asMapList(json['leaderboard'])
            .map(LeaderboardRow.fromJson)
            .toList(growable: false),
      );

  final String scope;
  final int openConversations;
  final int queued;
  final int onlineAgents;
  final int conversationsStarted;
  final int conversationsClosed;
  final int messagesIn;
  final int messagesOut;
  final int aiAnswered;
  final int aiHandoff;
  final double aiDeflectionRate;
  final double avgFirstResponseSeconds;
  final double avgRating;
  final int days;
  final List<StatPoint> series;
  final List<LeaderboardRow> leaderboard;

  /// True when the tenant-wide dashboard was returned rather than a single
  /// agent's workload.
  bool get isTenantWide => scope == 'tenant';
}

/// ----------------------------------------------------------------- realtime

/// A frame pushed over `/ws/console`.
class RealtimeEvent {
  const RealtimeEvent({
    required this.type,
    required this.tenantId,
    required this.conversationId,
    required this.data,
  });

  factory RealtimeEvent.fromJson(Map<String, dynamic> json) => RealtimeEvent(
        type: asString(json['type']),
        tenantId: asString(json['tenantId']),
        conversationId: asString(json['conversationId']),
        data: asMap(json['data']),
      );

  final String type;
  final String tenantId;
  final String conversationId;
  final Map<String, dynamic> data;

  /// The greeting frame the socket sends before anything else.
  bool get isHello => type == 'ready';

  bool get isHeartbeat => type == 'pong';
}
