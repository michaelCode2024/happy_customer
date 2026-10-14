import 'package:relaydesk_agent_console/src/util/message_alert_stub.dart'
    if (dart.library.html) 'package:relaydesk_agent_console/src/util/message_alert_web.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:relaydesk_agent_console/src/api/api_exception.dart';
import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/realtime/console_socket.dart';

/// Which slice of the queue the list is showing.
///
/// `mine` is the default because it is the answer to "what should I do next?"
/// for a working agent; `unassigned` is the team's shared intake, and `all` is
/// for supervisors watching the floor.
enum QueueFilter { mine, unassigned, all }

extension QueueFilterLabel on QueueFilter {
  String get label => switch (this) {
        QueueFilter.mine => '我的',
        QueueFilter.unassigned => '待分配',
        QueueFilter.all => '全部',
      };

  String get wire => switch (this) {
        QueueFilter.mine => 'mine',
        QueueFilter.unassigned => 'unassigned',
        QueueFilter.all => 'all',
      };
}

/// The workbench: the conversation queue, the open thread, and the realtime
/// channel that keeps both fresh.
///
/// The socket is treated as a hint, never as a source of truth. Every event that
/// arrives only tells the controller *that* something changed; the state itself
/// is always re-read over REST, where the sequence numbers are authoritative.
/// That is what makes a dropped connection a non-event rather than a data-loss
/// bug.
class WorkbenchController extends ChangeNotifier {
  WorkbenchController({required this.api, this.selfId = '', this.visitorAlert});

  final void Function(String messageId, String senderName)? visitorAlert;
  final DateTime _alertsSince = DateTime.now();
  final Map<String, int> _notificationSequences = {};
  final Set<String> _checkingNotifications = {};
  int _syncTick = 0;

  final RelayDeskApi api;

  /// The signed-in agent's id. The server never says "this is yours", so the
  /// console compares `senderId` against this to decide who may edit or recall
  /// a message, and which reactions are already chosen.
  final String selfId;

  // ------------------------------------------------------------------- state

  // 默认完整收件箱，避免新咨询落在待分配或其他坐席名下时被误认为丢消息。
  QueueFilter _filter = QueueFilter.all;
  String? _inboxFilter;
  String _search = '';
  bool _includeResolved = false;

  List<Conversation> _conversations = const <Conversation>[];
  int _queued = 0;

  /// 服务端汇总的坐席未读条数；侧栏「客户消息」角标只用这个，不用待接待数顶替。
  int _unread = 0;
  bool _loadingList = false;
  String? _listError;

  String? _selectedId;
  ConversationDetail? _detail;
  List<ChatMessage> _messages = const <ChatMessage>[];
  int _lastSequence = 0;
  bool _loadingThread = false;
  bool _loadingMore = false;
  bool _hasMoreHistory = false;
  String? _threadError;

  /// The message the composer is answering. Null means a plain reply.
  ChatMessage? _replyTo;

  /// The pin bar. Held apart from [_messages] because a pinned message may have
  /// scrolled out of the retained window and must still stay visible.
  List<ChatMessage> _pins = const <ChatMessage>[];

  /// In-thread search. The hits are excerpts with the matched terms marked, so
  /// they are only useful while the query that produced them is on screen.
  List<SearchHit> _searchHits = const <SearchHit>[];
  String _searchQuery = '';
  bool _searching = false;
  String? _searchError;

  /// Where "以下为新消息" belongs. This is the read cursor as the server knows
  /// it, captured when the thread was opened, so the divider does not move as
  /// the agent reads.
  int _readBoundary = 0;

  /// 当前会话里访客已读 / 已送达的最大序号，驱动坐席气泡回执。
  int _visitorLastReadSequence = 0;
  int _visitorLastDeliveredSequence = 0;

  /// The highest sequence this console has rendered, reported back as a
  /// delivery receipt. Delivery and reading are separate: a thread that is open
  /// but not being looked at has delivered its messages without anyone reading
  /// them.
  int _deliveredSequence = 0;
  Timer? _deliveredDebounce;

  List<AgentSummary> _agents = const <AgentSummary>[];
  List<CannedResponse> _canned = const <CannedResponse>[];
  List<TagInfo> _tags = const <TagInfo>[];

  /// The conversation in which the visitor is currently typing, so the composer
  /// can show a "对方正在输入" hint that decays on its own.
  String? _typingConversationId;
  Timer? _typingDecay;

  SocketState _socketState = SocketState.closed;
  bool _closed = false;

  ConsoleSocket? _socket;
  StreamSubscription<RealtimeEvent>? _eventSubscription;
  StreamSubscription<SocketState>? _stateSubscription;
  StreamSubscription<void>? _reconnectSubscription;
  Timer? _listDebounce;
  Timer? _syncTimer;

  /// Guards against two overlapping full reloads: the socket can deliver a burst
  /// of events (a handoff creates a message and an assignment at once), and each
  /// one must not start its own round trip.
  int _listGeneration = 0;
  int _threadGeneration = 0;

  // -------------------------------------------------------------- accessors

  QueueFilter get filter => _filter;

  String? get inboxFilter => _inboxFilter;

  String get search => _search;

  bool get includeResolved => _includeResolved;

  List<Conversation> get conversations => _conversations;

  /// How many conversations are waiting for any agent, shown on the queue badge
  /// regardless of the current filter.
  int get queued => _queued;

  /// 未读消息条数（跨当前筛选），给侧栏角标用。
  int get unread => _unread;

  bool get loadingList => _loadingList;

  String? get listError => _listError;

  String? get selectedId => _selectedId;

  Conversation? get selected {
    final id = _selectedId;
    if (id == null) {
      return null;
    }
    for (final conversation in _conversations) {
      if (conversation.id == id) {
        return conversation;
      }
    }
    return _detail?.conversation;
  }

  ConversationDetail? get detail => _detail;

  List<ChatMessage> get messages => _messages;

  int get lastSequence => _lastSequence;

  bool get loadingThread => _loadingThread;

  bool get loadingMore => _loadingMore;

  bool get hasMoreHistory => _hasMoreHistory;

  String? get threadError => _threadError;

  /// 关闭会话内错误横幅；不自动消失，避免客服错过接单失败等原因。
  void clearThreadError() {
    if (_threadError == null) {
      return;
    }
    _threadError = null;
    _notify();
  }

  /// The quoted message the composer is answering, if any.
  ChatMessage? get replyTo => _replyTo;

  List<ChatMessage> get pins => _pins;

  List<SearchHit> get searchHits => _searchHits;

  String get searchQuery => _searchQuery;

  bool get searching => _searching;

  String? get searchError => _searchError;

  /// The sequence the "以下为新消息" divider sits after, or 0 when there is
  /// nothing new in this thread.
  int get readBoundary => _readBoundary;

  /// True when the divider belongs in the transcript at all: the unread slice
  /// must actually be inside the window that is loaded.
  bool get showUnreadDivider =>
      _readBoundary > 0 &&
      _messages.any((message) => message.sequence > _readBoundary) &&
      _messages.any((message) => message.sequence <= _readBoundary);

  int get visitorLastReadSequence => _visitorLastReadSequence;

  int get visitorLastDeliveredSequence => _visitorLastDeliveredSequence;

  /// 坐席发出去的公开消息回执；访客消息 / 系统消息返回 [MessageReceipt.none]。
  MessageReceipt receiptFor(ChatMessage message) {
    if (!message.isFromAgent || message.isPrivate || message.isDeleted) {
      if (message.delivery == DeliveryState.sending) {
        return MessageReceipt.sending;
      }
      if (message.delivery == DeliveryState.failed) {
        return MessageReceipt.failed;
      }
      return MessageReceipt.none;
    }
    if (message.delivery == DeliveryState.sending) {
      return MessageReceipt.sending;
    }
    if (message.delivery == DeliveryState.failed) {
      return MessageReceipt.failed;
    }
    final sequence = message.sequence;
    if (sequence <= 0) {
      return MessageReceipt.unread;
    }
    if (sequence <= _visitorLastReadSequence) {
      return MessageReceipt.read;
    }
    if (sequence <= _visitorLastDeliveredSequence) {
      return MessageReceipt.delivered;
    }
    return MessageReceipt.unread;
  }

  List<AgentSummary> get agents => _agents;

  List<CannedResponse> get canned => _canned;

  List<TagInfo> get tags => _tags;

  SocketState get socketState => _socketState;

  /// True while the visitor on the open thread is typing.
  bool get visitorTyping =>
      _typingConversationId != null &&
      _selectedId != null &&
      _typingConversationId == _selectedId;

  /// Canned responses that apply to the open conversation's inbox.
  List<CannedResponse> get cannedForSelection {
    final inboxId = selected?.inboxId ?? '';
    return _canned
        .where((entry) => entry.appliesTo(inboxId))
        .toList(growable: false);
  }

  // ------------------------------------------------------------------ socket

  /// Opens the realtime channel. Safe to call once the session is live.
  void connectRealtime() {
    final socket = ConsoleSocket(uriProvider: api.socketUri);
    _socket = socket;
    _eventSubscription = socket.events.listen(_onEvent);
    _stateSubscription = socket.states.listen((state) {
      _socketState = state;
      _notify();
    });
    _reconnectSubscription = socket.reconnects.listen((_) => _resync());
    socket.connect();
    _syncTimer ??= Timer.periodic(const Duration(seconds: 3), (_) {
      // 正常推送时仍15秒兜底；断线时3秒补拉，减少等重连期间的漏看。
      if (_socketState == SocketState.open && ++_syncTick % 5 != 0) return;
      if (!_closed && !_loadingList && !_loadingThread) _resync();
    });
  }

  void _resync() {
    // The socket does not replay what was missed, so a reconnect triggers a
    // full resync: the queue and, if one is open, the thread.
    unawaited(refreshConversations(silent: true));
    final id = _selectedId;
    if (id != null) {
      unawaited(_pullMissed(id));
    }
  }

  void Function(String groupId)? onGroupUpdated;
  void _onEvent(RealtimeEvent event) {
    if (event.type == 'support.assets.updated') {
      unawaited(loadCanned());
      unawaited(loadTags());
    }
    if (event.type == 'group.updated') {
      final id = event.data['groupId'] as String?;
      if (id != null) onGroupUpdated?.call(id);
    }
    switch (event.type) {
      case 'message.created':
      case 'message.updated':
      case 'conversation.created':
      case 'conversation.assigned':
      case 'conversation.transferred':
      case 'conversation.status':
      case 'conversation.closed':
      case 'conversation.handoff':
      case 'conversation.rated':
        _scheduleListRefresh();
      default:
        break;
    }
    if (event.type == 'message.created') {
      if (event.data['senderType'] == 'VISITOR' &&
          event.data['private'] != true) {
        var senderName = asString(event.data['senderName']);
        if (senderName.trim().isEmpty) {
          final matches =
              _conversations.where((c) => c.id == event.conversationId);
          if (matches.isNotEmpty) senderName = matches.first.visitorName;
        }
        _alertVisitor(event.data['id'].toString(), senderName);
      }
      _applyIncomingMessage(event);
    }
    if (event.type == 'message.updated') {
      _applyUpdatedMessage(event);
    }
    if (event.type == 'message.reaction') {
      _applyReactions(event);
    }
    if (event.type == 'message.pinned') {
      _applyPins(event);
    }
    if (event.type == 'typing' && event.conversationId == _selectedId) {
      _typingConversationId = event.conversationId;
      _typingDecay?.cancel();
      _typingDecay = Timer(const Duration(seconds: 4), () {
        _typingConversationId = null;
        _notify();
      });
      _notify();
    }
    if (event.type == 'conversation.assigned' ||
        event.type == 'conversation.transferred' ||
        event.type == 'conversation.status') {
      _patchFromEvent(event);
    }
    if (event.type == 'conversation.read') {
      _scheduleListRefresh();
      _applyVisitorReceipt(event, read: true);
    }
    if (event.type == 'conversation.delivered') {
      _applyVisitorReceipt(event, read: false);
    }
  }

  /// 访客端上报送达 / 已读后，推进气泡回执；只处理当前打开的会话。
  void _applyVisitorReceipt(RealtimeEvent event, {required bool read}) {
    if (event.conversationId != _selectedId) {
      return;
    }
    if (asString(event.data['readerType']) != 'VISITOR') {
      return;
    }
    final sequence = asInt(event.data['sequence']);
    if (sequence <= 0) {
      return;
    }
    var changed = false;
    if (sequence > _visitorLastDeliveredSequence) {
      _visitorLastDeliveredSequence = sequence;
      changed = true;
    }
    if (read && sequence > _visitorLastReadSequence) {
      _visitorLastReadSequence = sequence;
      changed = true;
      // 仅移除已读边界以内的消息，后来的公开回复保持未读。
      _patchLocal(
        event.conversationId,
        (conversation) => conversation.copyWith(
            visitorUnread: _messages
                .where((m) =>
                    m.sequence > sequence && !m.isFromVisitor && !m.isPrivate)
                .length),
      );
    }
    if (changed) {
      _notify();
    }
  }

  /// Merges a pushed message into the open thread without a round trip, which is
  /// what makes an incoming visitor message feel instant. The event payload is
  /// the same [messageView] the REST endpoints return, so the merge is exact.
  void _applyIncomingMessage(RealtimeEvent event) {
    if (event.conversationId != _selectedId) {
      return;
    }
    final incoming = ChatMessage.fromJson(event.data, selfId: selfId);
    if (incoming.id.isEmpty) {
      return;
    }
    final index = _messages.indexWhere(
      (message) =>
          message.id == incoming.id ||
          (incoming.clientMessageId != null &&
              message.clientMessageId == incoming.clientMessageId &&
              message.delivery != DeliveryState.sent),
    );
    final merged = List<ChatMessage>.of(_messages);
    if (index >= 0) {
      merged[index] = incoming;
    } else {
      merged.add(incoming);
    }
    merged.sort(_bySequence);
    _messages = _trimHistory(merged);
    _lastSequence = math.max(_lastSequence, incoming.sequence);
    // Anything that arrives while the agent is looking at the thread has been
    // delivered even if it is never read, so the visitor's tick advances.
    _scheduleDelivered();
    _notify();
  }

  /// Replaces one message wholesale after an edit or a recall. The row keeps its
  /// sequence, so a client that already rendered it substitutes the bubble
  /// rather than shifting everything below it.
  void _applyUpdatedMessage(RealtimeEvent event) {
    if (event.conversationId != _selectedId) {
      return;
    }
    final updated = ChatMessage.fromJson(event.data, selfId: selfId);
    if (updated.id.isEmpty) {
      return;
    }
    final index = _messages.indexWhere((message) => message.id == updated.id);
    if (index < 0) {
      // A message outside the retained window was recalled; the pin bar may
      // still be showing it, so it is dropped from there too.
      if (updated.isDeleted && _pins.any((pin) => pin.id == updated.id)) {
        _pins =
            _pins.where((pin) => pin.id != updated.id).toList(growable: false);
        _notify();
      }
      return;
    }
    _messages = List<ChatMessage>.of(_messages)..[index] = updated;
    if (updated.isDeleted) {
      _pins =
          _pins.where((pin) => pin.id != updated.id).toList(growable: false);
    } else if (_pins.any((pin) => pin.id == updated.id) ||
        _pins.any((pin) => pin.pinnedAt == null)) {
      _pins = _pins
          .map((pin) => pin.id == updated.id ? updated : pin)
          .toList(growable: false);
    }
    _notify();
  }

  /// Applies a reaction event. Reactions travel on their own channel because
  /// they change nothing about the message itself, and re-reading the whole
  /// thread to draw one emoji would be absurd.
  void _applyReactions(RealtimeEvent event) {
    if (event.conversationId != _selectedId) {
      return;
    }
    final data = event.data;
    final messageId = data['messageId'];
    if (messageId is! String) {
      return;
    }
    final reactions = asMapList(data['reactions'])
        .map((item) => MessageReaction.fromJson(item, selfId))
        .toList(growable: false);
    var changed = false;
    _messages = _messages.map((message) {
      if (message.id != messageId) {
        return message;
      }
      changed = true;
      return message.copyWith(reactions: reactions);
    }).toList(growable: false);
    _pins = _pins.map((pin) {
      if (pin.id != messageId) {
        return pin;
      }
      return pin.copyWith(reactions: reactions);
    }).toList(growable: false);
    if (changed) {
      _notify();
    }
  }

  /// Applies a pin event. The event carries the whole pin bar, so the console
  /// adopts that rather than guessing which entries moved.
  void _applyPins(RealtimeEvent event) {
    if (event.conversationId != _selectedId) {
      return;
    }
    final data = event.data;
    final pinned = data['pinned'];
    final messageId = data['messageId'];
    if (data['pinnedMessages'] != null) {
      _pins = asMapList(data['pinnedMessages'])
          .map((item) => ChatMessage.fromJson(item, selfId: selfId))
          .toList(growable: false);
    } else if (messageId is String) {
      // Fallback for a payload without the list: patch the one message.
      _pins = _pins.where((pin) => pin.id != messageId).toList(growable: false);
      if (pinned == true) {
        final match = _messages.where((message) => message.id == messageId);
        if (match.isNotEmpty) {
          _pins = <ChatMessage>[..._pins, match.first];
        }
      }
    }
    // The pin state also lives on the message itself, so the bubble's marker
    // stays in step with the bar.
    _messages = _messages.map((message) {
      if (message.id != messageId) {
        return message;
      }
      return message.copyWith(
        pinnedAt: pinned == true ? (message.pinnedAt ?? DateTime.now()) : null,
        clearPinned: pinned != true,
      );
    }).toList(growable: false);
    _notify();
  }

  /// Applies the parts of a state event that are safe to trust without a
  /// re-read: the assignee and the status. Anything else waits for the refresh.
  void _patchFromEvent(RealtimeEvent event) {
    final id = event.conversationId;
    if (id.isEmpty) {
      return;
    }
    final assigneeId = event.data['assigneeId'];
    final assigneeName = event.data['assigneeName'];
    final status = event.data['status'];
    _conversations = _conversations.map((conversation) {
      if (conversation.id != id) {
        return conversation;
      }
      return conversation.copyWith(
        status: status is String && status.isNotEmpty ? status : null,
        assigneeId: assigneeId is String ? assigneeId : null,
        assigneeName: assigneeName is String ? assigneeName : null,
      );
    }).toList(growable: false);
    _notify();
  }

  void _scheduleListRefresh() {
    _listDebounce?.cancel();
    _listDebounce = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(refreshConversations(silent: true)),
    );
  }

  // ------------------------------------------------------------ conversation

  /// Loads the queue. [silent] keeps the previous list on screen while the new
  /// one is fetched, which is what stops the list from flickering on every
  /// realtime event.
  Future<void> refreshConversations({bool silent = false}) async {
    final generation = ++_listGeneration;
    if (!silent) {
      _loadingList = true;
      _listError = null;
      _notify();
    }
    try {
      final page = await api.conversations(
        filter: _filter.wire,
        inboxId: _inboxFilter,
        query: _search,
        limit: 50,
        status: _includeResolved ? 'ALL' : null,
      );
      if (generation != _listGeneration) {
        return;
      }
      for (final row in page.items) {
        final previous = _notificationSequences[row.id];
        // 首次打开只建基线；新会话只提醒本次工作台打开后到达的消息。
        if (silent &&
            row.lastSequence > (previous ?? 0) &&
            (previous != null ||
                (row.lastMessageAt?.isAfter(_alertsSince) ?? false))) {
          unawaited(_checkMissedAlerts(row, previous ?? 0));
        } else {
          _notificationSequences[row.id] = row.lastSequence;
        }
      }
      _conversations = page.items;
      // 列表是最新状态来源：新消息自动重开会话时同步标题和操作菜单。
      final currentDetail = _detail;
      if (currentDetail != null) {
        for (final row in page.items) {
          if (row.id == _selectedId) {
            _detail = ConversationDetail(
              conversation: row,
              visitor: currentDetail.visitor,
              rating: currentDetail.rating,
            );
            break;
          }
        }
      }
      _queued = page.queued;
      _unread = page.unread;
      _listError = null;
      // A conversation that vanished from the filter (because someone else
      // claimed it) should not stay open in the reading pane.
      final selected = _selectedId;
      if (selected != null &&
          !_conversations.any((item) => item.id == selected)) {
        if (_filter != QueueFilter.all) {
          await _loadDetail(selected);
        }
      }
    } on ApiException catch (failure) {
      if (generation != _listGeneration) {
        return;
      }
      _listError = failure.message;
    } finally {
      if (generation == _listGeneration) {
        _loadingList = false;
        _notify();
      }
    }
  }

  void _alertVisitor(String id, String senderName) {
    if (id.isEmpty || !_alertedMessages.add(id)) return;
    if (visitorAlert != null) {
      visitorAlert!(id, senderName);
    } else {
      messageAlert(id, '', senderName: senderName);
    }
    if (_alertedMessages.length > 500) {
      _alertedMessages.remove(_alertedMessages.first);
    }
  }

  Future<void> _checkMissedAlerts(Conversation row, int after) async {
    if (!_checkingNotifications.add(row.id)) return;
    try {
      final page =
          await api.messages(row.id, after: after, limit: 200, selfId: selfId);
      if (_closed) return;
      for (final message in page.items) {
        if (message.isFromVisitor && !message.isPrivate && !message.isDeleted) {
          _alertVisitor(
              message.id,
              message.senderName.isEmpty
                  ? row.visitorName
                  : message.senderName);
        }
      }
      // 未返回的页不能跳过，接口失败也不推进游标，下一次继续补拉。
      _notificationSequences[row.id] = math.max(after, page.lastSequence);
    } on ApiException {
      // 保留原游标等待下一次补拉。
    } finally {
      _checkingNotifications.remove(row.id);
    }
  }

  Future<void> setFilter(QueueFilter value) async {
    if (_filter == value) {
      return;
    }
    _filter = value;
    _notify();
    await refreshConversations();
  }

  Future<void> setInboxFilter(String? inboxId) async {
    _inboxFilter = inboxId;
    _notify();
    await refreshConversations();
  }

  Future<void> setIncludeResolved(bool value) async {
    _includeResolved = value;
    _notify();
    await refreshConversations();
  }

  /// Server-side search over the visitor name and the last message preview.
  /// Debounced by the caller so typing does not issue a request per keystroke.
  Future<void> setSearch(String value) async {
    _search = value;
    await refreshConversations(silent: true);
  }

  // ------------------------------------------------------------------ thread

  Future<void> select(String conversationId) async {
    if (_selectedId == conversationId) {
      return;
    }
    _selectedId = conversationId;
    _messages = const <ChatMessage>[];
    _lastSequence = 0;
    _hasMoreHistory = false;
    _threadError = null;
    _typingConversationId = null;
    _replyTo = null;
    _pins = const <ChatMessage>[];
    _readBoundary = 0;
    _visitorLastReadSequence = 0;
    _visitorLastDeliveredSequence = 0;
    _deliveredSequence = 0;
    clearSearch();
    _notify();
    await _loadDetail(conversationId);
    // The pin bar is loaded before the transcript so it is on screen even if the
    // pinned message itself has aged out of the window.
    unawaited(_loadPins(conversationId));
    await _loadLatest(conversationId);
    unawaited(markRead(conversationId));
  }

  void clearSelection() {
    _selectedId = null;
    _detail = null;
    _messages = const <ChatMessage>[];
    _lastSequence = 0;
    _replyTo = null;
    _pins = const <ChatMessage>[];
    _readBoundary = 0;
    _visitorLastReadSequence = 0;
    _visitorLastDeliveredSequence = 0;
    clearSearch();
    _notify();
  }

  Future<void> reloadSelected() async {
    final id = _selectedId;
    if (id == null) {
      return;
    }
    await _loadDetail(id);
    await _loadLatest(id);
  }

  Future<void> _loadDetail(String conversationId) async {
    try {
      final detail = await api.conversation(conversationId);
      if (_selectedId != conversationId) {
        return;
      }
      _detail = detail;
      _notify();
    } on ApiException catch (failure) {
      if (_selectedId != conversationId) {
        return;
      }
      _threadError = failure.message;
      _notify();
    }
  }

  /// Fills the reading pane: walks forward from sequence 0 in pages until the
  /// conversation is caught up, then keeps the newest [maxKept] messages.
  ///
  /// The API pages forward (`after=<sequence>`), and a thread is opened at its
  /// newest message, so the walk is bounded by [maxPages] rather than trusting
  /// a conversation's length.
  Future<void> _loadLatest(String conversationId) async {
    final generation = ++_threadGeneration;
    _loadingThread = true;
    _notify();
    const pageSize = 200;
    const maxPages = 8;
    final collected = <ChatMessage>[];
    var cursor = 0;
    var serverLast = 0;
    var pages = 0;
    var readBoundary = 0;
    var delivered = 0;
    try {
      while (pages < maxPages) {
        final page = await api.messages(
          conversationId,
          after: cursor,
          limit: pageSize,
          selfId: selfId,
        );
        if (_selectedId != conversationId || generation != _threadGeneration) {
          return;
        }
        serverLast = math.max(serverLast, page.lastSequence);
        // The boundary is whatever the server said on the first page: it does
        // not change while the walk continues, and only the opening page can
        // describe where the agent left off.
        if (pages == 0) {
          readBoundary = page.lastReadSequence;
          delivered = page.hasMore ? 0 : serverLast;
          // 首屏带回访客游标；后续翻页不会改这两个值。
          _visitorLastReadSequence = page.visitorLastReadSequence;
          _visitorLastDeliveredSequence = page.visitorLastDeliveredSequence;
        }
        collected.addAll(page.items);
        pages += 1;
        if (page.items.isEmpty) {
          break;
        }
        cursor = page.items.last.sequence;
        if (cursor >= page.lastSequence) {
          break;
        }
      }
    } on ApiException catch (failure) {
      if (_selectedId == conversationId && generation == _threadGeneration) {
        _threadError = failure.message;
        _loadingThread = false;
        _notify();
      }
      return;
    }
    if (_selectedId != conversationId || generation != _threadGeneration) {
      return;
    }
    collected.sort(_bySequence);
    // The oldest page was dropped when the walk hit its page cap, so history
    // exists and can be fetched on demand.
    _hasMoreHistory = pages >= maxPages;
    _messages = _trimHistory(collected);
    _lastSequence =
        math.max(serverLast, collected.isEmpty ? 0 : collected.last.sequence);
    _readBoundary = readBoundary;
    _loadingThread = false;
    _notify();
    _refreshSelectedRow();
    _scheduleDelivered(sequence: math.max(delivered, _lastSequence));
  }

  /// Loads the pin bar. The pins are a small, bounded list, so they are fetched
  /// whole rather than derived from whatever is in the transcript window.
  Future<void> _loadPins(String conversationId) async {
    try {
      final pins = await api.pins(conversationId, selfId: selfId);
      if (_selectedId != conversationId) {
        return;
      }
      _pins = pins;
      _notify();
    } on ApiException {
      // The pin bar is an affordance, not the transcript: a failure here must
      // not blank the thread.
    }
  }

  /// Pulls only what arrived while the socket was down.
  Future<void> _pullMissed(String conversationId) async {
    try {
      final page = await api.messages(
        conversationId,
        after: _lastSequence,
        limit: 200,
        selfId: selfId,
      );
      if (_selectedId != conversationId || page.items.isEmpty) {
        return;
      }
      final merged = List<ChatMessage>.of(_messages)..addAll(page.items);
      merged.sort(_bySequence);
      _messages = _trimHistory(merged);
      _lastSequence = math.max(_lastSequence, page.lastSequence);
      _scheduleDelivered();
      _notify();
    } on ApiException {
      // The next reconnect or manual refresh will pick it up.
    }
  }

  /// Fetches one page of older messages and prepends it to the thread.
  ///
  /// This asks for what precedes the oldest loaded sequence (`before=`), so a
  /// long thread costs one request per screenful instead of re-walking from the
  /// top of the conversation every time the agent scrolls up.
  Future<void> loadOlder() async {
    final id = _selectedId;
    if (id == null || _loadingMore || !_hasMoreHistory || _messages.isEmpty) {
      return;
    }
    _loadingMore = true;
    _notify();
    final oldestLoaded = _messages.first.sequence;
    try {
      final page = await api.messages(
        id,
        before: oldestLoaded,
        limit: pageSize,
        selfId: selfId,
      );
      if (_selectedId != id) {
        return;
      }
      final older = page.items
          .where((message) => message.sequence < oldestLoaded)
          .toList(growable: false);
      if (older.isNotEmpty) {
        final merged = <ChatMessage>[...older, ..._messages]..sort(_bySequence);
        _messages = merged;
      }
      _hasMoreHistory = page.hasOlder;
    } on ApiException catch (failure) {
      _threadError = failure.message;
    } finally {
      if (_selectedId == id) {
        _loadingMore = false;
        _notify();
      }
    }
  }

  /// The number of messages fetched per page. Matches what the walk uses, so a
  /// screenful of scroll-back and the opening load agree on their granularity.
  static const int pageSize = 200;

  /// Re-reads the open row in the queue so its preview and unread badge match
  /// the thread that is on screen.
  void _refreshSelectedRow() {
    final id = _selectedId;
    final detail = _detail;
    if (id == null || detail == null) {
      return;
    }
    _conversations = _conversations
        .map((conversation) =>
            conversation.id == id ? detail.conversation : conversation)
        .toList(growable: false);
    _notify();
  }

  // ------------------------------------------------------------------- writes

  /// Sends a reply (or an internal note) with an optimistic bubble.
  ///
  /// The bubble is keyed by [clientMessageId], so the server's `message.created`
  /// event — or the POST response, whichever lands first — replaces it instead
  /// of adding a duplicate. A failure marks the bubble retryable rather than
  /// making it disappear.
  Future<bool> send({
    required String content,
    List<Attachment> attachments = const <Attachment>[],
    bool private = false,
    String? clientMessageId,
    Map<String, dynamic>? metadata,
    QuotedMessage? quote,
  }) async {
    // 未接待、他人会话等禁止公开回复；内部备注仍可写。原因写进 threadError 供横幅展示。
    final pending = selected;
    if (!private && pending != null) {
      final block = pending.publicReplyBlockReason(selfId);
      if (block != null) {
        _threadError = block;
        _notify();
        return false;
      }
    }
    final id = _selectedId;
    if (id == null) {
      return false;
    }
    // A quote is taken from the argument or, when the caller passes nothing,
    // from whatever the composer had selected. Passing it explicitly is what
    // makes a retry re-send the same quote rather than the one that replaced it.
    final quoted = quote ?? _replyTo?.toQuote();
    final localId =
        clientMessageId ?? 'local-${DateTime.now().microsecondsSinceEpoch}';
    final messageType = attachments.isEmpty
        ? 'TEXT'
        : attachments.every((item) => item.isAudio)
            ? 'AUDIO'
            : (attachments.every((item) => item.isImage) ? 'IMAGE' : 'FILE');
    final optimistic = ChatMessage.optimistic(
      localId: localId,
      conversationId: id,
      content: content,
      messageType: messageType,
      attachments: attachments,
      senderId: selfId.isEmpty ? _detail?.conversation.assigneeId : selfId,
      senderName: _detail?.conversation.assigneeName ?? '',
      isPrivate: private,
      replyTo: quoted,
      metadata: metadata ?? const {},
    );
    _messages = _trimHistory(<ChatMessage>[..._messages, optimistic]);
    _replyTo = null;
    _notify();
    try {
      final saved = await api.send(
        conversationId: id,
        content: content,
        clientMessageId: localId,
        messageType: messageType,
        attachmentIds:
            attachments.map((item) => item.id).toList(growable: false),
        private: private,
        replyToId: quoted?.id,
        selfId: selfId,
        metadata: metadata,
      );
      _replaceLocal(localId, saved.copyWith(delivery: DeliveryState.sent));
      _lastSequence = math.max(_lastSequence, saved.sequence);
      // 公开回复刚发出时访客侧尚未读，列表立刻标访客未读，等 read 事件再清。
      if (!private) {
        _patchLocal(
          id,
          (conversation) => conversation.copyWith(
            visitorUnread: saved.sequence > _visitorLastReadSequence
                ? conversation.visitorUnread + 1
                : conversation.visitorUnread,
            lastMessagePreview: content.trim().isEmpty
                ? conversation.lastMessagePreview
                : content.trim(),
            lastMessageAt: saved.createdAt,
          ),
        );
      }
      _notify();
      // Sending a reply is what clears the stored draft; the server does the
      // same on its side, so the two cannot disagree about what is pending.
      unawaited(_clearDraft(id));
      _scheduleListRefresh();
      return true;
    } on ApiException catch (failure) {
      _replaceLocal(
          localId,
          optimistic.copyWith(
            delivery: DeliveryState.failed,
            error: failure.message,
          ));
      _notify();
      return false;
    }
  }

  /// Sets the message the next reply will quote. Passing null cancels the quote.
  void quote(ChatMessage? message) {
    _replyTo = message;
    _notify();
  }

  /// Retries a failed bubble, reusing its client message id so a message that
  /// actually arrived before the timeout cannot be duplicated server-side.
  /// The quoting is replayed from the bubble itself, because the composer's
  /// selection was cleared when the first attempt was made.
  Future<bool> retry(ChatMessage message) async {
    final localId = message.clientMessageId;
    if (localId == null) {
      return false;
    }
    return send(
      content: message.content,
      attachments: message.attachments,
      metadata: message.metadata,
      private: message.isPrivate,
      clientMessageId: localId,
      quote: message.replyTo,
    );
  }

  /// Rewrites the text of a message this agent wrote.
  Future<void> editMessage(ChatMessage message, String content) async {
    final id = _selectedId;
    if (id == null) {
      return;
    }
    try {
      final updated = await api.editMessage(
        id,
        message.id,
        content: content,
        selfId: selfId,
      );
      _substitute(updated);
    } on ApiException catch (failure) {
      _threadError = failure.message;
      _notify();
    }
  }

  /// Recalls a message, leaving a tombstone in place so the transcript does not
  /// shift under the reader.
  Future<void> deleteMessage(ChatMessage message) async {
    final id = _selectedId;
    if (id == null) {
      return;
    }
    try {
      final updated = await api.deleteMessage(id, message.id, selfId: selfId);
      _substitute(updated);
      _pins =
          _pins.where((pin) => pin.id != updated.id).toList(growable: false);
      _scheduleListRefresh();
      _notify();
    } on ApiException catch (failure) {
      _threadError = failure.message;
      _notify();
    }
  }

  /// Toggles an emoji on a message. The response carries the full aggregate, so
  /// the console adopts that instead of applying its own delta.
  Future<void> react(ChatMessage message, String emoji) async {
    final id = _selectedId;
    if (id == null) {
      return;
    }
    try {
      final reactions = await api.toggleReaction(
        id,
        message.id,
        emoji: emoji,
        selfId: selfId,
      );
      _messages = _messages
          .map((item) => item.id == message.id
              ? item.copyWith(reactions: reactions)
              : item)
          .toList(growable: false);
      _pins = _pins
          .map((pin) =>
              pin.id == message.id ? pin.copyWith(reactions: reactions) : pin)
          .toList(growable: false);
      _notify();
    } on ApiException catch (failure) {
      _threadError = failure.message;
      _notify();
    }
  }

  /// Pins or unpins a message. The server returns the resulting bar, which is
  /// adopted whole so the console never guesses which entries moved.
  Future<void> togglePin(ChatMessage message) async {
    final id = _selectedId;
    if (id == null) {
      return;
    }
    final pinned = !message.isPinned;
    // Optimistic, because a pin is a local reading aid and a round trip is
    // visible on a tap.
    _messages = _messages
        .map((item) => item.id == message.id
            ? item.copyWith(
                pinnedAt: pinned ? DateTime.now() : null,
                clearPinned: !pinned,
              )
            : item)
        .toList(growable: false);
    _notify();
    try {
      final pins =
          await api.setPinned(id, message.id, pinned: pinned, selfId: selfId);
      if (_selectedId != id) {
        return;
      }
      _pins = pins;
      _notify();
    } on ApiException catch (failure) {
      _threadError = failure.message;
      // The optimistic flip is undone by reloading the authoritative bar and
      // the message row rather than by inverting the guess, which could be
      // wrong if the same message was pinned elsewhere in the meantime.
      await _loadPins(id);
      final match = _messages.where((item) => item.id == message.id);
      if (match.isNotEmpty) {
        _substitute(match.first.copyWith(
          pinnedAt: pinned ? null : (message.pinnedAt ?? DateTime.now()),
          clearPinned: pinned,
        ));
      }
      _notify();
    }
  }

  /// Copies a message into another conversation.
  ///
  /// This is a copy rather than a move: the original stays where it was, and the
  /// new one records `forwardedFromId`. The target is not opened, because an
  /// agent forwarding a screenshot to a colleague usually wants to stay put.
  Future<bool> forward(ChatMessage message, String targetConversationId) async {
    final id = _selectedId;
    if (id == null) {
      return false;
    }
    try {
      await api.forwardMessage(
        id,
        message.id,
        targetConversationId: targetConversationId,
        selfId: selfId,
      );
      _scheduleListRefresh();
      return true;
    } on ApiException catch (failure) {
      _threadError = failure.message;
      _notify();
      return false;
    }
  }

  // ------------------------------------------------------------------ drafts

  /// The draft this agent left in the open conversation, loaded when the thread
  /// is opened so switching away and back does not lose a half-written answer.
  Future<String> loadDraft(String conversationId) async {
    try {
      return await api.draft(conversationId);
    } on ApiException {
      return '';
    }
  }

  /// Saves the draft text. Blank content clears it.
  Future<void> saveDraft(String content) async {
    final id = _selectedId;
    if (id == null) {
      return;
    }
    try {
      await api.saveDraft(id, content);
    } on ApiException {
      // A draft is a convenience: losing one must never interrupt a reply.
    }
  }

  Future<void> _clearDraft(String conversationId) async {
    try {
      await api.saveDraft(conversationId, '');
    } on ApiException {
      // Ignored, as above.
    }
  }

  // ------------------------------------------------------------------ search

  /// Searches the open thread. The hits are excerpts rather than messages, so
  /// they are held separately from the transcript and cleared when the query
  /// changes — a stale hit list pointing at the previous keyword would be worse
  /// than none.
  Future<void> searchThread(String query) async {
    final id = _selectedId;
    final trimmed = query.trim();
    _searchQuery = trimmed;
    if (id == null || trimmed.isEmpty) {
      _searchHits = const <SearchHit>[];
      _searching = false;
      _searchError = null;
      _notify();
      return;
    }
    _searching = true;
    _searchError = null;
    _notify();
    try {
      final hits = await api.searchConversation(id, query: trimmed);
      // The query may have changed, or the thread, while the request was in
      // flight; only the newest search may write its results.
      if (_selectedId != id || _searchQuery != trimmed) {
        return;
      }
      _searchHits = hits;
    } on ApiException catch (failure) {
      if (_selectedId != id || _searchQuery != trimmed) {
        return;
      }
      _searchHits = const <SearchHit>[];
      _searchError = failure.message;
    } finally {
      if (_selectedId == id && _searchQuery == trimmed) {
        _searching = false;
        _notify();
      }
    }
  }

  void clearSearch() {
    _searchQuery = '';
    _searchHits = const <SearchHit>[];
    _searchError = null;
    _searching = false;
  }

  void _replaceLocal(String localId, ChatMessage replacement) {
    _messages = _messages
        .map((message) => message.clientMessageId == localId &&
                message.delivery != DeliveryState.sent &&
                message.id == localId
            ? replacement
            : message)
        .toList(growable: false)
      ..sort(_bySequence);
  }

  Future<void> claim() async {
    final id = _selectedId;
    if (id == null) {
      return;
    }
    try {
      await api.claim(id);
      // The claim endpoint only acknowledges, so the assignment is read back
      // through the detail endpoint rather than assumed.
      await _loadDetail(id);
      await refreshConversations(silent: true);
    } on ApiException catch (failure) {
      // A 409 means someone else got there first, which is information the agent
      // needs, not an error to hide.
      _threadError = failure.message;
      _notify();
      await refreshConversations(silent: true);
    }
  }

  Future<void> setStatus(String status) async {
    final id = _selectedId;
    if (id == null) {
      return;
    }
    try {
      await api.setStatus(id, status);
      _patchLocal(id, (conversation) => conversation.copyWith(status: status));
      _notify();
      await refreshConversations(silent: true);
    } on ApiException catch (failure) {
      _threadError = failure.message;
      _notify();
    }
  }

  Future<void> transfer(String agentId, {String note = ''}) async {
    final id = _selectedId;
    if (id == null) {
      return;
    }
    try {
      await api.transfer(conversationId: id, agentId: agentId, note: note);
      await refreshConversations(silent: true);
      await _loadDetail(id);
    } on ApiException catch (failure) {
      _threadError = failure.message;
      _notify();
    }
  }

  Future<void> setPriority(int priority) async {
    final id = _selectedId;
    if (id == null) {
      return;
    }
    _patchLocal(
        id, (conversation) => conversation.copyWith(priority: priority));
    _notify();
    try {
      await api.setPriority(id, priority);
    } on ApiException catch (failure) {
      _threadError = failure.message;
      _notify();
    }
  }

  Future<void> setTags(List<String> tags) async {
    final id = _selectedId;
    if (id == null) {
      return;
    }
    try {
      final applied = await api.setTags(id, tags);
      _patchLocal(id, (conversation) => conversation.copyWith(tags: applied));
      _notify();
      await loadTags();
    } on ApiException catch (failure) {
      _threadError = failure.message;
      _notify();
    }
  }

  final Set<String> _alertedMessages = {};
  bool readingThread = false;
  final Map<String, int> _readAcknowledged = {};
  bool _readBusy = false;
  Future<void> markRead(String conversationId) async {
    if (!readingThread ||
        !pageVisible() ||
        _selectedId != conversationId ||
        _lastSequence <= (_readAcknowledged[conversationId] ?? 0) ||
        _readBusy) return;
    final boundary = _lastSequence;
    _readBusy = true;
    try {
      await api.markRead(conversationId, sequence: boundary);
      _readAcknowledged[conversationId] = boundary;
      if (_selectedId == conversationId) {
        final matched = _conversations.where((c) => c.id == conversationId);
        final previous = matched.isEmpty ? 0 : matched.first.agentUnread;
        final next = _messages
            .where((m) => m.sequence > boundary && m.isFromVisitor)
            .length;
        _patchLocal(
          conversationId,
          (conversation) => conversation.copyWith(agentUnread: next),
        );
        // 侧栏未读角标跟服务端汇总对齐：本地已读后立刻扣掉差额，不等整表刷新。
        _unread = math.max(0, _unread - previous + next);
      }
      _notify();
    } on ApiException {
      // Retry on the next visible pass.
    } finally {
      _readBusy = false;
    }
  }

  /// Reports the highest sequence this console holds.
  ///
  /// Debounced and monotonic: a burst of arriving messages produces one request
  /// carrying the newest watermark, and a late reply can never rewind it. The
  /// server applies `greatest()` for the same reason, so both ends agree that
  /// delivery only moves forward.
  void _scheduleDelivered({int? sequence}) {
    final target = math.max(sequence ?? _lastSequence, _deliveredSequence);
    if (target <= _deliveredSequence) {
      return;
    }
    _deliveredSequence = target;
    _deliveredDebounce?.cancel();
    _deliveredDebounce = Timer(const Duration(milliseconds: 400), () {
      final id = _selectedId;
      if (id == null) {
        return;
      }
      unawaited(api
          .markDelivered(id, sequence: _deliveredSequence)
          .catchError((Object _) {}));
    });
  }

  /// Replaces one message in the transcript by id, keeping the ordering intact.
  void _substitute(ChatMessage updated) {
    if (updated.id.isEmpty) {
      return;
    }
    var found = false;
    _messages = _messages.map((message) {
      if (message.id != updated.id) {
        return message;
      }
      found = true;
      return updated;
    }).toList(growable: false);
    if (found) {
      _notify();
    }
  }

  void notifyVisitorTyping(String conversationId) {
    _socket?.sendTyping(conversationId);
  }

  void _patchLocal(
    String conversationId,
    Conversation Function(Conversation) update,
  ) {
    _conversations = _conversations
        .map((conversation) => conversation.id == conversationId
            ? update(conversation)
            : conversation)
        .toList(growable: false);
    final detail = _detail;
    if (detail != null && detail.conversation.id == conversationId) {
      _detail = ConversationDetail(
        conversation: update(detail.conversation),
        visitor: detail.visitor,
        rating: detail.rating,
      );
    }
  }

  // -------------------------------------------------------------- reference data

  Future<void> loadReferenceData() async {
    await Future.wait(<Future<void>>[
      loadAgents(),
      loadCanned(),
      loadTags(),
    ]);
  }

  Future<void> loadAgents() async {
    try {
      _agents = await api.agents();
      _notify();
    } on ApiException {
      // Reference data is optional: the workbench still works without it.
    }
  }

  Future<void> loadCanned() async {
    try {
      _canned = await api.cannedResponses();
      _notify();
    } on ApiException {
      // Ignored.
    }
  }

  Future<void> loadTags() async {
    try {
      _tags = await api.tags();
      _notify();
    } on ApiException {
      // Ignored.
    }
  }

  // ---------------------------------------------------------------- internals

  /// Keeps the newest [maxKept] messages. A very long thread is not something an
  /// agent scrolls through; it is something they search, and holding an unbounded
  /// list in memory only slows every rebuild.
  static const int maxKept = 500;

  List<ChatMessage> _trimHistory(List<ChatMessage> input) {
    if (input.length <= maxKept) {
      return input;
    }
    final trimmed = input.sublist(input.length - maxKept);
    _hasMoreHistory = true;
    return trimmed;
  }

  /// Ascending by sequence, with not-yet-acknowledged local bubbles (sequence 0)
  /// pinned after everything the server has confirmed.
  static int _bySequence(ChatMessage a, ChatMessage b) {
    if (a.sequence == 0 && b.sequence == 0) {
      return a.createdAt.compareTo(b.createdAt);
    }
    if (a.sequence == 0) {
      return 1;
    }
    if (b.sequence == 0) {
      return -1;
    }
    return a.sequence.compareTo(b.sequence);
  }

  void _notify() {
    if (!_closed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _listDebounce?.cancel();
    _syncTimer?.cancel();
    _typingDecay?.cancel();
    _deliveredDebounce?.cancel();
    _eventSubscription?.cancel();
    _stateSubscription?.cancel();
    _reconnectSubscription?.cancel();
    _socket?.dispose();
    super.dispose();
  }
}
