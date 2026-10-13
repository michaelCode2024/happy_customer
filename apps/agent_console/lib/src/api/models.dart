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

  /// Enterprise roles: SUPERVISOR or AGENT.
  final String role;

  /// ONLINE, AWAY, OFFLINE, or null before the first presence frame.
  final String? presence;

  bool get canManageKnowledge => role == 'SUPERVISOR';

  bool get canViewReports => role == 'SUPERVISOR';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'email': email,
        'displayName': displayName,
        'role': role,
        if (presence != null) 'presence': presence,
      };
}

class TenantInfo {
  const TenantInfo({required this.id, required this.name, this.slug = ''});

  factory TenantInfo.fromJson(Map<String, dynamic> json) => TenantInfo(
        id: asString(json['id']),
        name: asString(json['name']),
        slug: asString(json['slug']),
      );

  final String id;
  final String name;

  final String slug;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'id': id, 'name': name, 'slug': slug};
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

/// One aggregated reaction on a message. The server groups by emoji and lists
/// the actors, so the console can render a count and highlight the ones this
/// agent chose without a second request.
class MessageReaction {
  const MessageReaction({
    required this.emoji,
    required this.count,
    required this.actors,
    required this.mine,
  });

  factory MessageReaction.fromJson(Map<String, dynamic> json, String selfId) {
    final actors = (json['actors'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<String>()
        .toList(growable: false);
    return MessageReaction(
      emoji: asString(json['emoji']),
      count: json['count'] == null ? actors.length : asInt(json['count']),
      actors: actors,
      mine: selfId.isNotEmpty && actors.contains(selfId),
    );
  }

  final String emoji;
  final int count;
  final List<String> actors;
  final bool mine;
}

/// The emoji an agent may react with. The server refuses anything else, so the
/// picker and the allow-list cannot drift apart without this changing too.
const List<String> kReactionEmoji = <String>[
  '👍',
  '👎',
  '😀',
  '🎉',
  '❤️',
  '🙏',
  '😅',
  '😢',
  '🔥',
  '✅',
];

const Map<String, String> kReactionLabels = <String, String>{
  '👍': '赞',
  '👎': '踩',
  '😀': '开心',
  '🎉': '庆祝',
  '❤️': '喜欢',
  '🙏': '感谢',
  '😅': '尴尬',
  '😢': '难过',
  '🔥': '重要',
  '✅': '已确认',
};

/// The snapshot of a quoted message, taken when the reply was written. It is
/// deliberately a copy rather than a reference: the original may be edited or
/// recalled afterwards, and the reply must still show what it answered.
class QuotedMessage {
  const QuotedMessage({
    required this.id,
    required this.sequence,
    required this.senderType,
    required this.senderName,
    required this.messageType,
    required this.content,
    required this.deletedAt,
  });

  factory QuotedMessage.fromJson(Map<String, dynamic> json) => QuotedMessage(
        id: asString(json['id']),
        sequence: asInt(json['sequence']),
        senderType: asString(json['senderType']),
        senderName: asString(json['senderName']),
        messageType: asString(json['messageType']),
        content: asString(json['content']),
        deletedAt: asDate(json['deletedAt']),
      );

  final String id;
  final int sequence;
  final String senderType;
  final String senderName;
  final String messageType;
  final String content;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  /// What the quote block shows. A recalled original reads as a tombstone
  /// rather than as an empty quote.
  String get label {
    if (isDeleted) {
      return '该消息已被撤回';
    }
    if (messageType == 'TEXT') {
      return content;
    }
    return '[${messageTypeLabel(messageType)}]';
  }
}

/// A human label for a non-text message, used by the quote block and the
/// conversation preview. Kept in the client so a transcript renders correctly
/// even for a message type the console does not have a bubble for.
String messageTypeLabel(String messageType) => switch (messageType) {
      'IMAGE' => '图片',
      'FILE' => '文件',
      'AUDIO' => '语音',
      'VIDEO' => '视频',
      'CARD' => '卡片',
      'RATING' => '评价',
      'EVENT' => '事件',
      'SYSTEM' => '系统消息',
      _ => '消息',
    };

/// One search hit inside a transcript. The excerpt carries `<< >>` around the
/// matched terms, which the console renders as a highlight; the server builds
/// it because PostgreSQL's ts_headline cannot segment Chinese.
class SearchHit {
  const SearchHit({
    required this.messageId,
    required this.conversationId,
    required this.sequence,
    required this.excerpt,
    required this.createdAt,
    required this.messageType,
    required this.senderType,
    required this.senderName,
  });

  factory SearchHit.fromJson(Map<String, dynamic> json) => SearchHit(
        messageId: asString(json['messageId']),
        conversationId: asString(json['conversationId']),
        sequence: asInt(json['sequence']),
        excerpt: asString(json['excerpt']),
        createdAt: asDate(json['createdAt']) ?? DateTime.now(),
        messageType: asString(json['messageType']),
        senderType: asString(json['senderType']),
        senderName: asString(json['senderName']),
      );

  final String messageId;
  final String conversationId;
  final int sequence;
  final String excerpt;
  final DateTime createdAt;
  final String messageType;
  final String senderType;
  final String senderName;
}

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
    this.isPrivate = false,
    this.replyToId,
    this.replyTo,
    this.editedAt,
    this.deletedAt,
    this.pinnedAt,
    this.forwardedFromId,
    this.reactions = const <MessageReaction>[],
    this.delivery = DeliveryState.sent,
    this.error,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json,
      {String selfId = ''}) {
    final replyTo = asMap(json['replyTo']);
    return ChatMessage(
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
      // The server sends an explicit flag now. The metadata fallback stays
      // because a message written before the column existed is still in the
      // transcript, and a note rendered as a normal reply would be sent to the
      // visitor by mistake.
      isPrivate:
          asBool(json['private']) || asBool(asMap(json['metadata'])['private']),
      replyToId: asNullableString(json['replyToId']),
      replyTo: replyTo.isEmpty ? null : QuotedMessage.fromJson(replyTo),
      editedAt: asDate(json['editedAt']),
      deletedAt: asDate(json['deletedAt']),
      pinnedAt: asDate(json['pinnedAt']),
      forwardedFromId: asNullableString(json['forwardedFromId']),
      reactions: asMapList(json['reactions'])
          .map((item) => MessageReaction.fromJson(item, selfId))
          .toList(growable: false),
      delivery: DeliveryState.sent,
    );
  }

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
    QuotedMessage? replyTo,
    Map<String, dynamic> metadata = const {},
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
        metadata: metadata,
        createdAt: DateTime.now(),
        isPrivate: isPrivate,
        replyToId: replyTo?.id,
        replyTo: replyTo,
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

  /// TEXT, IMAGE, FILE, AUDIO, VIDEO, CARD, EVENT, SYSTEM, RATING.
  final String messageType;
  final String content;
  final List<Attachment> attachments;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;

  /// An internal note: visible to the whole team, never delivered to the
  /// visitor. The server owns this flag so a note can never leak through a
  /// client that forgot to check metadata.
  final bool isPrivate;

  final String? replyToId;
  final QuotedMessage? replyTo;

  /// Set when the text was rewritten. A recalled message keeps its row and its
  /// sequence and carries [deletedAt] instead, so the console replaces the
  /// bubble rather than shifting everything below it.
  final DateTime? editedAt;
  final DateTime? deletedAt;
  final DateTime? pinnedAt;
  final String? forwardedFromId;
  final List<MessageReaction> reactions;

  final DeliveryState delivery;
  final String? error;

  bool get isFromVisitor => senderType == 'VISITOR';

  bool get isFromAgent => senderType == 'AGENT';

  bool get isSystem => senderType == 'SYSTEM';

  bool get isDeleted => deletedAt != null;

  bool get isEdited => editedAt != null;

  bool get isPinned => pinnedAt != null;

  bool get isForwarded => forwardedFromId != null;

  /// Whether this agent wrote the message, which decides who may edit or recall
  /// it. The server enforces the same rule; this only hides controls that would
  /// come back as an error.
  bool isMine(String? selfId) =>
      isFromAgent && selfId != null && selfId.isNotEmpty && senderId == selfId;

  bool get isTransfer =>
      asBool(metadata['transfer']) || asBool(metadata['ai_handoff']);

  bool get isAi => asBool(metadata['ai']) || senderId == 'bot';

  /// The duration a sender's device measured for a voice note. The audio
  /// element cannot report a duration for a stream it has not buffered, so the
  /// value travels with the message instead.
  Duration? get voiceDuration {
    final value = metadata['durationMs'];
    if (value is num && value > 0) {
      return Duration(milliseconds: value.round());
    }
    return null;
  }

  /// The quote snapshot this message would produce. Snapshotting rather than
  /// referencing is deliberate: the original can be edited or recalled after the
  /// reply is written, and the reply must still show what it answered.
  QuotedMessage toQuote() => QuotedMessage(
        id: id,
        sequence: sequence,
        senderType: senderType,
        senderName: senderName,
        messageType: messageType,
        content: content,
        deletedAt: deletedAt,
      );

  ChatMessage copyWith({
    int? sequence,
    DeliveryState? delivery,
    String? error,
    List<Attachment>? attachments,
    List<MessageReaction>? reactions,
    DateTime? editedAt,
    DateTime? deletedAt,
    DateTime? pinnedAt,
    bool clearPinned = false,
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
        isPrivate: isPrivate,
        replyToId: replyToId,
        replyTo: replyTo,
        editedAt: editedAt ?? this.editedAt,
        deletedAt: deletedAt ?? this.deletedAt,
        // Unpinning needs its own flag: `pinnedAt: null` is indistinguishable
        // from "leave it alone" in a nullable parameter.
        pinnedAt: clearPinned ? null : (pinnedAt ?? this.pinnedAt),
        forwardedFromId: forwardedFromId,
        reactions: reactions ?? this.reactions,
        delivery: delivery ?? this.delivery,
        error: error ?? this.error,
      );
}

/// 本地发送生命周期：发出前 / 服务端已确认 / 失败可重试。
enum DeliveryState { sending, sent, failed }

/// 坐席气泡下展示的投递回执：发送中 → 未读 → 已送达 → 已读；失败单独一态。
enum MessageReceipt { none, sending, failed, unread, delivered, read }

extension MessageReceiptLabel on MessageReceipt {
  String get label => switch (this) {
        MessageReceipt.none => '',
        MessageReceipt.sending => '发送中',
        MessageReceipt.failed => '发送失败',
        MessageReceipt.unread => '未读',
        MessageReceipt.delivered => '已送达',
        MessageReceipt.read => '已读',
      };
}

/// 坐席 AI 助手的单次返回。text 始终存在（成功时），其余为任务相关字段。
class AssistResult {
  const AssistResult({
    required this.task,
    required this.text,
    this.label = '',
    this.score = 0.0,
    this.sources = const <String>[],
    this.provider = '',
    this.available = false,
  });

  factory AssistResult.fromJson(Map<String, dynamic> json) => AssistResult(
        task: asString(json['task']),
        text: asString(json['text']),
        label: asString(json['label']),
        score: asDouble(json['score']),
        sources: (json['sources'] as List?)
                ?.whereType<String>()
                .toList(growable: false) ??
            const <String>[],
        provider: asString(json['provider']),
        available: asBool(json['available']),
      );

  final String task;
  final String text;
  final String label;
  final double score;
  final List<String> sources;
  final String provider;
  final bool available;
}

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
    this.acceptedAt,
    this.assignmentExpiresAt,
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
        acceptedAt: asDate(json['acceptedAt']),
        assignmentExpiresAt: asDate(json['assignmentExpiresAt']),
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
  final DateTime? acceptedAt;
  final DateTime? assignmentExpiresAt;
  bool get needsAcceptance =>
      !isUnassigned && acceptedAt == null && assignmentExpiresAt != null;
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

  /// 聊天标题保持客户或会话身份稳定，最新消息只显示在预览中。
  String get title {
    if (visitorName.trim().isNotEmpty) {
      return visitorName.trim();
    }
    if (subject.trim().isNotEmpty) {
      return subject.trim();
    }
    return visitorId.isEmpty
        ? '访客会话'
        : '访客 ${visitorId.substring(0, visitorId.length < 6 ? visitorId.length : 6)}';
  }

  Conversation copyWith({
    String? status,
    String? assigneeId,
    String? assigneeName,
    int? priority,
    int? agentUnread,
    int? visitorUnread,
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
        acceptedAt: clearAssignee ? null : acceptedAt,
        assignmentExpiresAt: clearAssignee ? null : assignmentExpiresAt,
        priority: priority ?? this.priority,
        source: source,
        lastSequence: lastSequence ?? this.lastSequence,
        lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
        agentUnread: agentUnread ?? this.agentUnread,
        visitorUnread: visitorUnread ?? this.visitorUnread,
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
  bool appliesTo(String inboxIdValue) =>
      inboxId == null || inboxId == inboxIdValue;
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
    this.categoryId = '',
    required this.title,
    required this.content,
    required this.questionExamples,
    required this.status,
    required this.hitCount,
    required this.updatedAt,
  });

  factory KnowledgeEntry.fromJson(Map<String, dynamic> json) => KnowledgeEntry(
        id: asString(json['id']), categoryId: asString(json['categoryId']),
        title: asString(json['title']),
        content: asString(json['content']),
        // The server keeps the example phrasings as one text block, one per
        // line; the console edits them as a list.
        questionExamples: splitExamples(asString(json['questionExamples'])),
        status: asString(json['status']),
        hitCount: asInt(json['hitCount']),
        updatedAt: asDate(json['updatedAt']),
      );

  final String id, categoryId;
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

  factory KnowledgeAnswer.fromJson(Map<String, dynamic> json) =>
      KnowledgeAnswer(
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
