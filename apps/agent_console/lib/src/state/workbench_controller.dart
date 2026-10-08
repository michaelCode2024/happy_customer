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
  WorkbenchController({required this.api});

  final RelayDeskApi api;

  // ------------------------------------------------------------------- state

  QueueFilter _filter = QueueFilter.mine;
  String? _inboxFilter;
  String _search = '';
  bool _includeResolved = false;

  List<Conversation> _conversations = const <Conversation>[];
  int _queued = 0;
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

  List<AgentSummary> get agents => _agents;

  List<CannedResponse> get canned => _canned;

  List<TagInfo> get tags => _tags;

  SocketState get socketState => _socketState;

  /// True while the visitor on the open thread is typing.
  bool get visitorTyping => _typingConversationId != null &&
      _selectedId != null &&
      _typingConversationId == _selectedId;

  /// Canned responses that apply to the open conversation's inbox.
  List<CannedResponse> get cannedForSelection {
    final inboxId = selected?.inboxId ?? '';
    return _canned.where((entry) => entry.appliesTo(inboxId)).toList(growable: false);
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

  void _onEvent(RealtimeEvent event) {
    switch (event.type) {
      case 'message.created':
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
      _applyIncomingMessage(event);
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
  }

  /// Merges a pushed message into the open thread without a round trip, which is
  /// what makes an incoming visitor message feel instant. The event payload is
  /// the same [messageView] the REST endpoints return, so the merge is exact.
  void _applyIncomingMessage(RealtimeEvent event) {
    if (event.conversationId != _selectedId) {
      return;
    }
    final incoming = ChatMessage.fromJson(event.data);
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
      );
      if (generation != _listGeneration) {
        return;
      }
      _conversations = page.items;
      _queued = page.queued;
      _listError = null;
      // A conversation that vanished from the filter (because someone else
      // claimed it) should not stay open in the reading pane.
      final selected = _selectedId;
      if (selected != null && !_conversations.any((item) => item.id == selected)) {
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
    _notify();
    await _loadDetail(conversationId);
    await _loadLatest(conversationId);
    unawaited(markRead(conversationId));
  }

  void clearSelection() {
    _selectedId = null;
    _detail = null;
    _messages = const <ChatMessage>[];
    _lastSequence = 0;
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
    try {
      while (pages < maxPages) {
        final page = await api.messages(conversationId, after: cursor, limit: pageSize);
        if (_selectedId != conversationId || generation != _threadGeneration) {
          return;
        }
        serverLast = math.max(serverLast, page.lastSequence);
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
    _lastSequence = math.max(serverLast, collected.isEmpty ? 0 : collected.last.sequence);
    _loadingThread = false;
    _notify();
    _refreshSelectedRow();
  }

  /// Pulls only what arrived while the socket was down.
  Future<void> _pullMissed(String conversationId) async {
    try {
      final page = await api.messages(conversationId, after: _lastSequence, limit: 200);
      if (_selectedId != conversationId || page.items.isEmpty) {
        return;
      }
      final merged = List<ChatMessage>.of(_messages)..addAll(page.items);
      merged.sort(_bySequence);
      _messages = _trimHistory(merged);
      _lastSequence = math.max(_lastSequence, page.lastSequence);
      _notify();
    } on ApiException {
      // The next reconnect or manual refresh will pick it up.
    }
  }

  /// Fetches one page of older messages, prepended to the thread.
  ///
  /// Walking backwards is not something the API offers, so this is implemented
  /// by paging forward from zero and keeping the window that ends just before
  /// what is already loaded. It is only reachable when a very long thread hit
  /// the page cap, which is rare enough to justify the extra requests.
  Future<void> loadOlder() async {
    final id = _selectedId;
    if (id == null || _loadingMore || !_hasMoreHistory || _messages.isEmpty) {
      return;
    }
    _loadingMore = true;
    _notify();
    final oldestLoaded = _messages.first.sequence;
    const pageSize = 200;
    final collected = <ChatMessage>[];
    var cursor = 0;
    try {
      while (true) {
        final page = await api.messages(id, after: cursor, limit: pageSize);
        if (_selectedId != id) {
          return;
        }
        final older = page.items
            .where((message) => message.sequence < oldestLoaded)
            .toList(growable: false);
        collected.addAll(older);
        if (page.items.isEmpty ||
            page.items.last.sequence >= oldestLoaded ||
            collected.length >= pageSize) {
          break;
        }
        cursor = page.items.last.sequence;
      }
    } on ApiException catch (failure) {
      _threadError = failure.message;
      _loadingMore = false;
      _notify();
      return;
    } finally {
      if (_selectedId == id) {
        _loadingMore = false;
      }
    }
    if (_selectedId != id) {
      return;
    }
    final merged = <ChatMessage>[...collected, ..._messages]..sort(_bySequence);
    _messages = merged;
    _hasMoreHistory = collected.length >= pageSize;
    _notify();
  }

  /// Re-reads the open row in the queue so its preview and unread badge match
  /// the thread that is on screen.
  void _refreshSelectedRow() {
    final id = _selectedId;
    final detail = _detail;
    if (id == null || detail == null) {
      return;
    }
    _conversations = _conversations
        .map((conversation) => conversation.id == id ? detail.conversation : conversation)
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
  }) async {
    final id = _selectedId;
    if (id == null) {
      return false;
    }
    final localId = clientMessageId ?? 'local-${DateTime.now().microsecondsSinceEpoch}';
    final messageType = attachments.isEmpty
        ? 'TEXT'
        : (attachments.every((item) => item.isImage) ? 'IMAGE' : 'FILE');
    final optimistic = ChatMessage.optimistic(
      localId: localId,
      conversationId: id,
      content: content,
      messageType: messageType,
      attachments: attachments,
      senderId: _detail?.conversation.assigneeId,
      isPrivate: private,
    );
    _messages = _trimHistory(<ChatMessage>[..._messages, optimistic]);
    _notify();
    try {
      final saved = await api.send(
        conversationId: id,
        content: content,
        clientMessageId: localId,
        messageType: messageType,
        attachmentIds: attachments.map((item) => item.id).toList(growable: false),
        private: private,
      );
      _replaceLocal(localId, saved.copyWith(delivery: DeliveryState.sent));
      _lastSequence = math.max(_lastSequence, saved.sequence);
      _notify();
      _scheduleListRefresh();
      return true;
    } on ApiException catch (failure) {
      _replaceLocal(localId, optimistic.copyWith(
        delivery: DeliveryState.failed,
        error: failure.message,
      ));
      _notify();
      return false;
    }
  }

  /// Retries a failed bubble, reusing its client message id so a message that
  /// actually arrived before the timeout cannot be duplicated server-side.
  Future<bool> retry(ChatMessage message) async {
    final localId = message.clientMessageId;
    if (localId == null) {
      return false;
    }
    return send(
      content: message.content,
      attachments: message.attachments,
      private: message.isPrivate,
      clientMessageId: localId,
    );
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
    _patchLocal(id, (conversation) => conversation.copyWith(priority: priority));
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

  Future<void> markRead(String conversationId) async {
    try {
      await api.markRead(conversationId, sequence: _lastSequence);
      _patchLocal(
        conversationId,
        (conversation) => conversation.copyWith(agentUnread: 0),
      );
      _notify();
    } on ApiException {
      // A missed read receipt must never block the UI.
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
        .map((conversation) =>
            conversation.id == conversationId ? update(conversation) : conversation)
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
    _typingDecay?.cancel();
    _eventSubscription?.cancel();
    _stateSubscription?.cancel();
    _reconnectSubscription?.cancel();
    _socket?.dispose();
    super.dispose();
  }
}
