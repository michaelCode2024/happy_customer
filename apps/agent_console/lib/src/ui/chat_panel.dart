import 'package:tongyu_agent_console/src/ui/error_banner.dart';
import 'package:tongyu_agent_console/src/ui/workspace_layout.dart';
import 'package:tongyu_agent_console/src/ui/ai_assist_panel.dart';
import 'dart:async';
import 'package:tongyu_agent_console/src/ui/reception_guidance.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';

import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/theme.dart';
import 'package:tongyu_agent_console/src/util/attachment_picker.dart';
import 'package:tongyu_agent_console/src/util/voice_recording.dart';
import 'package:tongyu_agent_console/src/ui/voice_recorder_button.dart';
import 'package:tongyu_agent_console/src/util/format.dart';
import 'package:tongyu_agent_console/src/util/labels.dart';
import 'package:tongyu_agent_console/src/util/voice_player.dart';

/// The middle pane: the conversation itself.
///
/// The composer is the whole point of the screen, so everything else is arranged
/// to keep it in place: the header is one row, the thread scrolls under it, and
/// the composer never moves or changes height as messages arrive.
class ChatPanel extends StatefulWidget {
  const ChatPanel({
    super.key,
    required this.workbench,
    required this.picker,
    this.onOpenProfile,
    this.onBack,
    this.assistDraft,
    this.showInlineAssist = true,
  });

  final WorkbenchController workbench;
  final AttachmentPicker picker;

  /// Opens the customer sidebar; null hides the affordance on layouts that
  /// always show it.
  final VoidCallback? onOpenProfile;
  final VoidCallback? onBack;
  final ValueNotifier<AssistResult?>? assistDraft;
  final bool showInlineAssist;

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  final _scroll = ScrollController();
  final _searchField = TextEditingController();

  /// Files chosen but not yet sent. They are attached to the next message, which
  /// is what a chat client is expected to do.
  final List<Attachment> _pending = <Attachment>[];

  bool _noteMode = false;
  bool _isAiDraft = false;
  bool _sending = false;
  bool _uploading = false;
  String? _uploadError;
  final Map<String, int> _voiceDurations = {};

  Future<void> _attachVoice(RecordedVoice voice) async {
    final conversationId = widget.workbench.selectedId;
    if (conversationId == null) throw StateError('请先选择会话');
    final uploaded = await widget.workbench.api.upload(
        conversationId: conversationId,
        fileName: voice.fileName,
        bytes: voice.bytes,
        contentType: voice.contentType);
    if (!mounted || widget.workbench.selectedId != conversationId) {
      throw StateError('会话已切换，请重新录制');
    }
    setState(() {
      _pending.add(Attachment(
          id: uploaded.id,
          fileName: uploaded.fileName,
          contentType: uploaded.contentType,
          sizeBytes: uploaded.sizeBytes,
          url: uploaded.url));
      _voiceDurations[uploaded.id] = voice.duration.inMilliseconds;
    });
  }

  /// The conversation whose draft is currently in the composer, and whether the
  /// server's copy has been read yet. Until it has, an empty composer means "not
  /// loaded" rather than "nothing written", so a save would erase a draft the
  /// agent left on another device.
  String? _draftConversationId;
  bool _draftLoaded = false;
  Timer? _draftDebounce;

  bool _searchOpen = false;
  Timer? _searchDebounce;

  /// The message currently flashing after a jump from search or the pin bar.
  int? _flashSequence;
  Timer? _flashTimer;

  Timer? _typingThrottle;
  bool _typingSent = false;

  /// Set while the thread is being re-laid out, so the auto-scroll does not
  /// fight the agent's own scrolling.
  bool _stickToBottom = true;
  bool _userScrolling = false;
  bool _bottomScrollQueued = false;
  String? _scrollConversationId;
  String? _lastMessageId;
  Timer? _readTimer;

  @override
  void initState() {
    super.initState();
    _readTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final id = widget.workbench.selectedId;
      if (mounted && _stickToBottom && _scroll.hasClients && id != null) {
        unawaited(widget.workbench.markRead(id));
      }
    });
    _scroll.addListener(_onScroll);
    widget.workbench.addListener(_onWorkbenchChanged);
    widget.assistDraft?.addListener(_adoptAssist);
    _onWorkbenchChanged();
  }

  void _adoptAssist() {
    final result = widget.assistDraft?.value;
    if (result == null) return;
    _adoptResult(result);
  }

  String? _assistInteractionId;
  void _adoptResult(AssistResult result) {
    _assistInteractionId =
        result.interactionId.isEmpty ? null : result.interactionId;
    _insertAssist(result.text);
  }

  void _insertAssist(String text) {
    setState(() {
      _noteMode = false;
      _isAiDraft = true;
      _composer.text = text;
      _composer.selection = TextSelection.collapsed(offset: text.length);
    });
    _onComposerChanged(text);
    _composerFocus.requestFocus();
  }

  @override
  void didUpdateWidget(covariant ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assistDraft != widget.assistDraft) {
      oldWidget.assistDraft?.removeListener(_adoptAssist);
      widget.assistDraft?.addListener(_adoptAssist);
    }
  }

  @override
  void dispose() {
    _readTimer?.cancel();
    if (_draftLoaded && _draftConversationId != null) {
      unawaited(widget.workbench.api.saveDraft(
          _draftConversationId!, _composer.text,
          assistInteractionId: _noteMode ? null : _assistInteractionId,
          localPrivate: _noteMode));
    }
    _draftDebounce?.cancel();
    _flashTimer?.cancel();
    _searchDebounce?.cancel();
    widget.workbench.removeListener(_onWorkbenchChanged);
    widget.assistDraft?.removeListener(_adoptAssist);
    _composer.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    _searchField.dispose();
    _typingThrottle?.cancel();
    super.dispose();
  }

  /// Keeps the composer in step with the open conversation: a draft is fetched
  /// when one is opened, and saved as it is typed. The controller is the only
  /// place that knows both the open thread and the half-written answer, so this
  /// is where the two are joined.
  void _onWorkbenchChanged() {
    final id = widget.workbench.selectedId;
    final messages = widget.workbench.messages;
    final lastId = messages.isEmpty ? null : messages.last.id;
    if (id != _scrollConversationId) {
      _scrollConversationId = id;
      _lastMessageId = null;
      _stickToBottom = true;
      _userScrolling = false;
      _scrollToBottom();
    }
    if (lastId != _lastMessageId) {
      _lastMessageId = lastId;
      _scrollToBottom();
    }
    if (id == _draftConversationId) {
      return;
    }
    unawaited(_syncDraft(id));
  }

  Future<void> _syncDraft(String? conversationId) async {
    _draftDebounce?.cancel();
    final previous = _draftConversationId;
    if (_draftLoaded && previous != null) {
      unawaited(widget.workbench.api.saveDraft(previous, _composer.text,
          assistInteractionId: _noteMode ? null : _assistInteractionId,
          localPrivate: _noteMode));
    }
    _draftConversationId = conversationId;
    _draftLoaded = false;
    _isAiDraft = false;
    _assistInteractionId = null;
    _composer.clear();
    if (conversationId == null) {
      _draftLoaded = true;
      return;
    }
    Map<String, dynamic> draftData = {};
    try {
      draftData = await widget.workbench.api.draftData(conversationId);
    } catch (_) {/* 草稿读取失败不阻断接待。 */}
    final draft = asString(draftData['content']);
    // The agent may have moved on while the request was in flight; adopting it
    // then would drop the text they are typing into the new thread.
    if (_draftConversationId != conversationId) {
      return;
    }
    if (_composer.text.isNotEmpty) {
      _draftLoaded = true;
      _scheduleDraftSave(_composer.text);
      return;
    }
    _noteMode = draftData['localPrivate'] == true;
    _composer.text = draft;
    final restoredAssist = asString(draftData['assistInteractionId']);
    _assistInteractionId = restoredAssist.isEmpty ? null : restoredAssist;
    _isAiDraft = _assistInteractionId != null;
    _composer.selection = TextSelection.collapsed(offset: draft.length);
    _draftLoaded = true;
    if (mounted) setState(() {});
  }

  void _scheduleDraftSave(String value) {
    if (!_draftLoaded) {
      return;
    }
    _draftDebounce?.cancel();
    final assistID = _noteMode ? null : _assistInteractionId;
    final conversationId = _draftConversationId;
    final noteMode = _noteMode;
    _draftDebounce = Timer(const Duration(milliseconds: 350), () {
      if (conversationId != null) {
        unawaited(widget.workbench.api
            .saveDraft(conversationId, value,
                assistInteractionId: assistID, localPrivate: noteMode)
            .catchError((Object _) {}));
      }
    });
  }

  void _onScroll() {
    if (!_userScrolling || !_scroll.hasClients) {
      return;
    }
    final distance = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    final stick = distance < 80;
    if (stick != _stickToBottom) setState(() => _stickToBottom = stick);
  }

  /// Advances the thread to the newest message, but only when the agent was
  /// already at the bottom: reading history must not be interrupted by an
  /// incoming message.
  bool _onThreadNotification(Notification notification) {
    if (notification is UserScrollNotification && notification.depth == 0) {
      // 仅用户操作改变跟随状态；消息增高、图片加载和窗口缩放不会误判为翻历史。
      _userScrolling = true;
      _onScroll();
      _userScrolling = notification.direction != ScrollDirection.idle;
    }
    if (notification is ScrollMetricsNotification &&
        notification.depth == 0 &&
        _stickToBottom) {
      _scrollToBottom();
    }
    return false;
  }

  void _scrollToBottom({bool force = false}) {
    if (force && !_stickToBottom) setState(() => _stickToBottom = true);
    if (!_stickToBottom || _bottomScrollQueued) return;
    _bottomScrollQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bottomScrollQueued = false;
      if (!mounted || !_scroll.hasClients || !_stickToBottom) return;
      final position = _scroll.position;
      if ((position.maxScrollExtent - position.pixels).abs() > 0.5) {
        _scroll.jumpTo(position.maxScrollExtent);
      }
    });
    // 滚动后懒加载列表可能重新估算高度；尺寸通知会继续追到真实底部。
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _pickImage({bool document = false}) async {
    final conversationId = widget.workbench.selectedId;
    if (conversationId == null || _uploading) return;
    setState(() {
      _uploading = true;
      _uploadError = null;
    });
    try {
      final picked = document
          ? await widget.picker.pickFile()
          : await widget.picker.pickImage();
      if (picked == null) {
        return;
      }
      if (!mounted || widget.workbench.selectedId != conversationId) {
        return;
      }
      final uploaded = await widget.workbench.api.upload(
        conversationId: conversationId,
        fileName: picked.fileName,
        bytes: picked.bytes,
        contentType: picked.contentType,
      );
      if (!mounted || widget.workbench.selectedId != conversationId) return;
      setState(() {
        _pending.add(
          Attachment(
            id: uploaded.id,
            fileName: uploaded.fileName,
            contentType: uploaded.contentType,
            sizeBytes: uploaded.sizeBytes,
            url: uploaded.url,
          ),
        );
      });
    } catch (error) {
      if (mounted) setState(() => _uploadError = '上传失败：$error');
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
      }
    }
  }

  /// 输入区常驻说明：拦截原因优先；已解决则提示发送会重新打开。
  String? _composerHint(Conversation conversation, String selfId) {
    if (_noteMode) {
      return null;
    }
    if (conversation.isUnassigned) {
      return '当前会话尚未接待，请先点击右上角「开始接待」再回复；内部备注仍可发送。';
    }
    if (conversation.isHeldByOther(selfId)) {
      final name = conversation.assigneeName.trim().isEmpty
          ? '其他客服'
          : conversation.assigneeName.trim();
      return '该会话由「$name」接待中，请先转派给自己后再回复；内部备注仍可发送。';
    }
    if (conversation.needsAcceptance) {
      return '请先点击右上角「确认接单」再回复客户；内部备注仍可发送。';
    }
    if (conversation.isResolved) {
      return '会话已解决。发送回复将自动重新打开会话。';
    }
    return null;
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty && _pending.isEmpty) {
      return;
    }
    if (_sending) {
      return;
    }
    final workbench = widget.workbench;
    if (workbench.api.isOffline) {
      final id = workbench.selectedId;
      if (id != null)
        await workbench.api.saveDraft(id, _composer.text,
            assistInteractionId: _noteMode ? null : _assistInteractionId,
            localPrivate: _noteMode);
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(workbench.api.offlineStore?.writeFailed == true
                ? '本机存储不可用，未能保存草稿，请勿关闭页面'
                : '当前离线，回复已保存为本机草稿；联网后请确认再发送')));
      return;
    }
    final conversation = workbench.selected;
    // 未接待 / 他人会话时先提示、不清空输入，避免只看到「发送失败」。
    if (!_noteMode && conversation != null) {
      final block = conversation.publicReplyBlockReason(workbench.selfId);
      if (block != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(block)),
        );
        return;
      }
    }
    final attachments = List<Attachment>.of(_pending);
    // The quote is captured before the composer is cleared, so the bubble keeps
    // showing which message it answers.
    final quote = workbench.replyTo?.toQuote();
    final assistID = _noteMode ? null : _assistInteractionId;
    setState(() {
      _sending = true;
      _isAiDraft = false;
      _assistInteractionId = null;
      _pending.clear();
      _composer.clear();
    });
    _draftDebounce?.cancel();
    _stickToBottom = true;
    final ok = await workbench.send(
      content: text,
      attachments: attachments,
      private: _noteMode,
      quote: quote,
      metadata: {
        if (assistID != null && attachments.isEmpty)
          'assistInteractionId': assistID,
        if (attachments.length == 1 &&
            _voiceDurations.containsKey(attachments.first.id))
          'durationMs': _voiceDurations[attachments.first.id],
      },
    );
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    if (ok) {
      _scrollToBottom(force: true);
    } else {
      // 优先展示服务端/拦截的具体原因；没有时再退回气泡重试引导。
      final reason = workbench.threadError?.trim();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            reason != null && reason.isNotEmpty ? reason : '消息发送失败，可在气泡上重试',
          ),
        ),
      );
    }
  }

  /// Rewrites an existing message. The dialog starts from the current text so a
  /// correction is an edit rather than a retype.
  Future<void> _editMessage(ChatMessage message) async {
    final controller = TextEditingController(text: message.content);
    final next = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑消息'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 6,
          decoration: const InputDecoration(hintText: '修改后的内容'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = next?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == message.content) {
      return;
    }
    await widget.workbench.editMessage(message, trimmed);
  }

  /// Recalls a message. Confirmed first, because the transcript keeps a
  /// tombstone and the visitor sees the message disappear.
  Future<void> _recallMessage(ChatMessage message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤回这条消息？'),
        content: const Text('撤回后访客将看不到这条消息，会话记录里会留下“已撤回”的标记。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('撤回'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await widget.workbench.deleteMessage(message);
  }

  /// The reaction picker. Ten emoji, matching the server's allow-list, so a
  /// choice can never come back as a validation error.
  Future<void> _pickReaction(ChatMessage message) async {
    final emoji = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final entry in kReactionLabels.entries)
                Tooltip(
                  message: entry.value,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(entry.key),
                    iconSize: 26,
                    icon: Text(entry.key),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (emoji == null) {
      return;
    }
    await widget.workbench.react(message, emoji);
  }

  void _toggleSearch() {
    _searchDebounce?.cancel();
    setState(() => _searchOpen = !_searchOpen);
    if (!_searchOpen) {
      _searchField.clear();
      widget.workbench.clearSearch();
      return;
    }
    widget.workbench.clearSearch();
  }

  /// Searches the open thread. The query is debounced at the call site, so a
  /// burst of typing produces one request rather than one per keystroke.
  Future<void> _runSearch(String value) async {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(widget.workbench.searchThread(value));
    });
  }

  /// Picks a conversation to forward a message into.
  ///
  /// The list is the queue the agent already has loaded rather than a fresh
  /// search endpoint, which is both cheaper and matches their mental model: the
  /// conversations they can see are the ones they can forward to.
  Future<void> _forwardMessage(ChatMessage message) async {
    final workbench = widget.workbench;
    final options = workbench.conversations
        .where((conversation) => conversation.id != message.conversationId)
        .toList(growable: false);
    final target = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('转发到'),
        content: SizedBox(
          width: 420,
          height: 380,
          child: options.isEmpty
              ? const Center(child: Text('当前列表里没有其它会话'))
              : ListView.builder(
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final conversation = options[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        conversation.isUnassigned
                            ? Icons.inbox_outlined
                            : Icons.support_agent,
                        size: 18,
                      ),
                      title: Text(
                        conversation.visitorName.isEmpty
                            ? shortId(conversation.id)
                            : conversation.visitorName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        conversation.lastMessagePreview.isEmpty
                            ? conversation.subject
                            : conversation.lastMessagePreview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      onTap: () => Navigator.of(context).pop(conversation.id),
                    );
                  },
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (target == null || !mounted) {
      return;
    }
    final ok = await workbench.forward(message, target);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '已转发' : '转发失败，请稍后重试')),
    );
  }

  /// Tells the visitor the agent is typing. Throttled to one frame every few
  /// seconds: the indicator only needs to switch on.
  void _onComposerChanged(String value) {
    if (value.trim().isEmpty) _assistInteractionId = null;
    if (_isAiDraft && value.trim().isEmpty) setState(() => _isAiDraft = false);
    _scheduleDraftSave(value);
    final conversationId = widget.workbench.selectedId;
    if (conversationId == null || _noteMode) {
      return;
    }
    if (_typingSent || value.trim().isEmpty) {
      return;
    }
    _typingSent = true;
    widget.workbench.notifyVisitorTyping(conversationId);
    _typingThrottle?.cancel();
    _typingThrottle = Timer(const Duration(seconds: 4), () {
      _typingSent = false;
    });
  }

  bool _mobileAi = false;
  bool _mobileAiChecked = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_mobileAiChecked && MediaQuery.sizeOf(context).width < 760) {
      _mobileAiChecked = true;
      unawaited(_loadMobileAi());
    }
  }

  Future<void> _loadMobileAi() async {
    try {
      final data = await widget.workbench.api.entitlements();
      if (mounted)
        setState(() => _mobileAi = (data['features'] as Map?)?['ai'] == true);
    } catch (_) {/* 能力由后端确认，不把客服角色误当成套餐权限。 */}
  }

  void _showMobileAssist() {
    final id = widget.workbench.selectedId;
    if (id == null || !_mobileAi) return;
    _composerFocus.unfocus();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => SizedBox(
          height: MediaQuery.sizeOf(ctx).height * .78,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 24),
            child: widget.workbench.messages.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('AI 助手已开启。会话有消息后，可生成摘要、建议回复和翻译。'))
                : AiAssistPanel(
                    api: widget.workbench.api,
                    conversationId: id,
                    messages: widget.workbench.messages,
                    initiallyExpanded: true,
                    onAdopt: (result) {
                      _adoptResult(result);
                      Navigator.pop(ctx);
                    }),
          )),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.workbench,
      builder: (context, _) {
        final workbench = widget.workbench;
        final conversation = workbench.selected;
        if (conversation == null) {
          return const _EmptyThread();
        }
        return Column(
          children: <Widget>[
            _ThreadHeader(
              conversation: conversation,
              workbench: workbench,
              searchOpen: _searchOpen,
              onOpenProfile: widget.onOpenProfile,
              onBack: widget.onBack,
              onOpenAssist: _mobileAi ? _showMobileAssist : null,
              onToggleSearch: _toggleSearch,
            ),
            if (_searchOpen)
              _SearchBar(
                controller: _searchField,
                onChanged: _runSearch,
                onClose: _toggleSearch,
              ),
            if (workbench.searchQuery.isNotEmpty)
              _SearchResults(
                workbench: workbench,
                onJump: (hit) => _scrollToMessage(workbench, hit.sequence),
              ),
            if (workbench.pins.isNotEmpty)
              _PinBar(
                pins: workbench.pins,
                onJump: (message) =>
                    _scrollToMessage(workbench, message.sequence),
                onUnpin: workbench.togglePin,
              ),
            Expanded(
              // 消息区浅灰底：对齐微信 / 腾讯 IM，和白底列表、白底输入区分层。
              child: Column(
                children: [
                  // v2：消息流顶部斜切彩条（静态装饰，不遮挡内容）
                  Transform(
                    transform: Matrix4.skewY(-0.01),
                    alignment: Alignment.center,
                    child: Container(
                      height: 3.5,
                      width: double.infinity,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Color(0xFF5B8CFF),
                            Color(0xFF845EF7),
                            Color(0xFF12B886),
                            Color(0xFFF59F00),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ColoredBox(
                color: MediaQuery.sizeOf(context).width < 760 &&
                        Theme.of(context).brightness == Brightness.light
                    ? const Color(0xFFF2F3F5)
                    : RelayTheme.chatCanvas(Theme.of(context).colorScheme),
                child: NotificationListener<Notification>(
                    onNotification: _onThreadNotification,
                    child: _MessageList(
                      key: ValueKey<String>(conversation.id),
                      workbench: workbench,
                      scroll: _scroll,
                      flashSequence: _flashSequence,
                      onRetry: workbench.retry,
                      onLoadOlder: workbench.loadOlder,
                      onQuote: workbench.quote,
                      onEdit: _editMessage,
                      onRecall: _recallMessage,
                      onReact: _pickReaction,
                      onPin: workbench.togglePin,
                      onForward: _forwardMessage,
                      showJumpToBottom: !_stickToBottom,
                      onJumpToBottom: () => _scrollToBottom(force: true),
                    )),
              ),
                  ),
                ],
              ),
            ),
            if (workbench.threadError != null)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  MediaQuery.sizeOf(context).width < 760 ? 12 : 24,
                  8,
                  MediaQuery.sizeOf(context).width < 760 ? 12 : 24,
                  0,
                ),
                child: ErrorBanner(
                  message: workbench.threadError!,
                  onDismiss: workbench.clearThreadError,
                ),
              ),
            if (!_noteMode && workbench.messages.isNotEmpty)
              ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _composer,
                  builder: (context, value, _) => AiAssistPanel(
                        api: workbench.api,
                        conversationId: conversation.id,
                        messages: workbench.messages,
                        onAdopt: _adoptResult,
                        draftText: value.text,
                        writingOnly: !widget.showInlineAssist,
                      )),
            if (_isAiDraft)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
                color: Theme.of(context).colorScheme.surface,
                child: Text('✦ AI 草稿 · 请确认后发送',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 12)),
              ),
            if (!conversation.isResolved &&
                conversation.canClaim(workbench.selfId))
              ReceptionAction(
                  conversation: conversation,
                  busy: workbench.claiming,
                  onClaim: () async {
                    await workbench.claim();
                    if (mounted &&
                        workbench.selectedId == conversation.id &&
                        workbench.selected
                                ?.publicReplyBlockReason(workbench.selfId) ==
                            null) {
                      _composerFocus.requestFocus();
                    }
                  }),
            _Composer(
              controller: _composer,
              focusNode: _composerFocus,
              noteMode: _noteMode,
              sending: _sending,
              uploading: _uploading,
              pending: _pending,
              uploadError: _uploadError,
              visitorTyping: workbench.visitorTyping,
              canned: workbench.cannedForSelection,
              supportsFiles: widget.picker.supportsArbitraryFiles,
              quote: workbench.replyTo,
              // 未接待 / 他人会话 / 已解决：输入区常驻说明，避免只靠失败气泡。
              statusHint: _composerHint(conversation, workbench.selfId),
              lockPublicReply: !_noteMode &&
                  conversation.publicReplyBlockReason(workbench.selfId) != null,
              onChanged: _onComposerChanged,
              onToggleNote: (value) => setState(() => _noteMode = value),
              onPickImage: () => _pickImage(),
              onPickFile: () => _pickImage(document: true),
              voiceControl: VoiceRecorderButton(
                  key: ValueKey(conversation.id),
                  enabled: !_sending &&
                      !_uploading &&
                      !_noteMode &&
                      conversation.publicReplyBlockReason(workbench.selfId) ==
                          null,
                  onRecorded: _attachVoice),
              onClearQuote: () => workbench.quote(null),
              onRemovePending: (id) => setState(
                () => _pending.removeWhere((item) => item.id == id),
              ),
              onSend: _send,
            ),
          ],
        );
      },
    );
  }

  /// Scrolls to a message the agent picked out of the search panel or the pin
  /// bar and flashes it, which is what makes a hit in a long thread findable.
  void _scrollToMessage(WorkbenchController workbench, int sequence) {
    final index =
        workbench.messages.indexWhere((item) => item.sequence == sequence);
    if (index < 0) {
      // The message is outside the retained window. Older history is loaded on
      // demand, so the honest answer is that it is not loaded yet rather than
      // silently doing nothing.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这条消息不在已加载的范围内')),
      );
      return;
    }
    _stickToBottom = false;
    setState(() => _flashSequence = sequence);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) {
        return;
      }
      // Rows are laid out lazily, so an estimate is used only to get close; the
      // highlight is what confirms the right row was reached.
      final position = _scroll.position;
      final fraction =
          workbench.messages.isEmpty ? 0.0 : index / workbench.messages.length;
      _scroll.jumpTo((position.maxScrollExtent * fraction).clamp(
        0.0,
        position.maxScrollExtent,
      ));
    });
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _flashSequence = null);
      }
    });
  }

  /// Called by the parent when a conversation is opened, so the thread starts at
  /// the newest message instead of the oldest.
  void jumpToBottom() => _scrollToBottom(force: true);
}

class _EmptyThread extends StatelessWidget {
  const _EmptyThread();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 空态不占满整块画布：用统一的空状态块，避免中间出现「营销卡片」。
    return ColoredBox(
      color: RelayTheme.chatCanvas(scheme),
      child: const Center(
        child: WorkspaceEmptyState(
          icon: Icons.chat_bubble_outline_rounded,
          title: '选择一个会话开始接待',
          description: '从左侧打开客户消息，或等待新进线。空闲时可以复习接待规范与接入说明。',
        ),
      ),
    );
  }
}

/// The conversation header: who this is, what state the thread is in, and the
/// actions an agent takes on it.
class _ThreadHeader extends StatelessWidget {
  const _ThreadHeader({
    required this.conversation,
    required this.workbench,
    required this.searchOpen,
    required this.onToggleSearch,
    this.onOpenProfile,
    this.onBack,
    this.onOpenAssist,
  });

  final Conversation conversation;
  final WorkbenchController workbench;
  final bool searchOpen;
  final VoidCallback onToggleSearch;
  final VoidCallback? onOpenProfile;
  final VoidCallback? onBack;
  final VoidCallback? onOpenAssist;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 760;
    return Container(
      height: 58,
      padding: EdgeInsets.fromLTRB(compact ? 2 : 14, 0, 8, 0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: <Widget>[
          if (compact)
            IconButton(
              tooltip: '返回会话列表',
              visualDensity: VisualDensity.compact,
              onPressed: onBack ?? workbench.clearSelection,
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 17),
            ),
          if (!compact) ...<Widget>[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(.08),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                conversation.title.trim().isEmpty
                    ? '客'
                    : conversation.title.trim().substring(0, 1),
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.primary),
              ),
            ),
            const SizedBox(width: 9),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        conversation.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (MediaQuery.sizeOf(context).width >= 760) ...<Widget>[
                      const SizedBox(width: 8),
                      if (conversation.isResolved)
                        const _HeaderChip(label: '已解决', tone: _ChipTone.neutral)
                      else if (conversation.isUnassigned)
                        const _HeaderChip(label: '待接待', tone: _ChipTone.warn)
                      else if (conversation.needsAcceptance)
                        _HeaderChip(
                          // 别人待确认时写清是谁，避免自己误点「确认接单」。
                          label: conversation.isHeldByOther(workbench.selfId)
                              ? '${conversation.assigneeName.isEmpty ? '其他客服' : conversation.assigneeName}待确认'
                              : '等待确认接单',
                          tone: _ChipTone.warn,
                        )
                      else
                        _HeaderChip(
                          label: conversation.assigneeName.isEmpty
                              ? '接待中'
                              : conversation.assigneeName,
                          tone: _ChipTone.info,
                        ),
                      if (conversation.priority > 0) ...<Widget>[
                        const SizedBox(width: 6),
                        _HeaderChip(
                          label: conversation.priority >= 2 ? '高优先' : '优先',
                          tone: conversation.priority >= 2
                              ? _ChipTone.danger
                              : _ChipTone.warn,
                        ),
                      ],
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  MediaQuery.sizeOf(context).width < 760
                      ? (conversation.isResolved
                          ? '已解决'
                          : conversation.isUnassigned
                              ? '待接待'
                              : conversation.needsAcceptance
                                  ? (conversation
                                          .isHeldByOther(workbench.selfId)
                                      ? '${conversation.assigneeName.isEmpty ? '其他客服' : conversation.assigneeName}待确认'
                                      : '等待确认接单')
                                  : conversation.assigneeName.isEmpty
                                      ? '接待中'
                                      : '${conversation.assigneeName} · 接待中')
                      : [
                          'ID: ${shortId(conversation.id)}',
                          conversationSourceLabel(conversation.source),
                          if (conversation.visitorUnread > 0)
                            '访客未读 ${conversation.visitorUnread}',
                        ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (!conversation.isUnassigned &&
              !conversation.needsAcceptance &&
              MediaQuery.sizeOf(context).width >= 760)
            Padding(
                padding: const EdgeInsets.only(left: 8),
                child: conversation.isResolved
                    ? Semantics(
                        button: true,
                        label: '重新打开',
                        identifier: 'desk.resolve.reopen',
                        child: OutlinedButton(
                          key: const ValueKey('desk-resolve-reopen'),
                          onPressed: () => workbench.setStatus('OPEN'),
                          child: const Text('重新打开'),
                        ),
                      )
                    : Semantics(
                        button: true,
                        label: '标记解决',
                        identifier: 'desk.resolve.mark',
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: RelayTheme.tealGradient,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: RelayTheme.teal.withOpacity(0.28),
                                blurRadius: 18,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: FilledButton(
                            key: const ValueKey('desk-resolve-mark'),
                            onPressed: () => _markResolved(context),
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text('标记解决'),
                          ),
                        ),
                      )),
          // 仅未领取或「派给自己、待确认」才显示接单；他人会话只可转派，避免点了也失败。
          if (conversation.canClaim(workbench.selfId))
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: FilledButton.tonalIcon(
                onPressed: workbench.claiming ? null : workbench.claim,
                icon: const Icon(Icons.pan_tool_alt_outlined, size: 18),
                label: Text(conversation.receptionActionLabel),
              ),
            ),
          if (MediaQuery.sizeOf(context).width >= 760)
            Padding(
              // Keep clear of top-bar notification bell hit area.
              padding: const EdgeInsets.only(left: 10, right: 6),
              child: Semantics(
                button: true,
                label: '转交',
                identifier: 'desk.transfer.open',
                child: TextButton.icon(
                  key: const ValueKey('desk-transfer-open'),
                  onPressed: () => _showTransfer(context),
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text('转交'),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.onSurfaceVariant,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(48, 40),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                ),
              ),
            ),
          if (onOpenProfile != null && MediaQuery.sizeOf(context).width >= 760)
            IconButton(
              tooltip: '客户资料',
              onPressed: onOpenProfile,
              icon: const Icon(Icons.person_outline),
            ),
          if (MediaQuery.sizeOf(context).width >= 760)
            IconButton(
              tooltip: searchOpen ? '关闭搜索' : '搜索会话内容',
              onPressed: onToggleSearch,
              isSelected: searchOpen,
              icon: Icon(searchOpen ? Icons.search_off : Icons.search),
            ),
          if (MediaQuery.sizeOf(context).width < 760 && onOpenAssist != null)
            TextButton.icon(
                key: const ValueKey('mobile-ai-assist'),
                onPressed: onOpenAssist,
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('AI'),
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8))),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (value) {
              switch (value) {
                case 'profile':
                  onOpenProfile?.call();
                case 'resolve':
                  _markResolved(context);
                case 'reopen':
                  workbench.setStatus('OPEN');
                case 'pending':
                  workbench.setStatus('PENDING');
                case 'priority0':
                  workbench.setPriority(0);
                case 'priority1':
                  workbench.setPriority(1);
                case 'priority2':
                  workbench.setPriority(2);
                case 'transfer':
                  _showTransfer(context);
                case 'tags':
                  _showTags(context);
                case 'copy':
                  copyToClipboard(context, conversation.id, '会话 ID');
                case 'search':
                  onToggleSearch();
              }
            },
            itemBuilder: (context) => <PopupMenuEntry<String>>[
              if (MediaQuery.sizeOf(context).width < 760 &&
                  onOpenProfile != null)
                const PopupMenuItem(value: 'profile', child: Text('客户资料')),
              if (MediaQuery.sizeOf(context).width < 760)
                const PopupMenuItem(value: 'search', child: Text('搜索会话内容')),
              if (!conversation.isResolved)
                const PopupMenuItem<String>(
                  key: ValueKey('desk-menu-resolve'),
                  value: 'resolve',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.check_circle_outline, size: 18),
                    title: Text('标记解决'),
                  ),
                )
              else
                const PopupMenuItem<String>(
                  key: ValueKey('desk-menu-reopen'),
                  value: 'reopen',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.lock_open_outlined, size: 18),
                    title: Text('重新打开'),
                  ),
                ),
              const PopupMenuItem<String>(
                value: 'pending',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.hourglass_empty, size: 18),
                  title: Text('标记等待中'),
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'priority2',
                child: Text('优先级：高'),
              ),
              const PopupMenuItem<String>(
                value: 'priority1',
                child: Text('优先级：普通偏高'),
              ),
              const PopupMenuItem<String>(
                value: 'priority0',
                child: Text('优先级：普通'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                key: ValueKey('desk-menu-transfer'),
                value: 'transfer',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.swap_horiz, size: 18),
                  title: Text('转交'),
                ),
              ),
              const PopupMenuItem<String>(
                value: 'tags',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.sell_outlined, size: 18),
                  title: Text('编辑标签'),
                ),
              ),
              const PopupMenuItem<String>(
                value: 'copy',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.content_copy, size: 18),
                  title: Text('复制会话 ID'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _markResolved(BuildContext context) async {
    await workbench.setStatus('RESOLVED');
    if (!context.mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('已标记解决'),
        action: SnackBarAction(
          key: const ValueKey('desk-resolve-view-resolved'),
          label: '查看已解决',
          onPressed: () {
            workbench.setIncludeResolved(true);
          },
        ),
      ),
    );
  }

  Future<void> _showTransfer(BuildContext context) async {
    final selected = await showDialog<(String, String)>(
      context: context,
      barrierColor: const Color(0x6B0C1D40),
      builder: (context) => _TransferDialog(workbench: workbench),
    );
    if (selected != null) {
      await workbench.transfer(selected.$1, note: selected.$2);
    }
  }

  Future<void> _showTags(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _TagDialog(workbench: workbench),
    );
  }
}

enum _ChipTone { neutral, info, warn, danger }

class _HeaderChip extends StatelessWidget {
  const _HeaderChip({required this.label, required this.tone});

  final String label;
  final _ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (tone) {
      _ChipTone.neutral => scheme.outline,
      _ChipTone.info => scheme.primary,
      _ChipTone.warn => scheme.tertiary,
      _ChipTone.danger => scheme.error,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color, fontSize: 10.5, height: 1.35),
      ),
    );
  }
}

/// The scrolling transcript.
class _MessageList extends StatelessWidget {
  const _MessageList({
    super.key,
    required this.workbench,
    required this.scroll,
    required this.flashSequence,
    required this.onRetry,
    required this.onLoadOlder,
    required this.onQuote,
    required this.onEdit,
    required this.onRecall,
    required this.onReact,
    required this.onPin,
    required this.onForward,
    required this.onJumpToBottom,
    required this.showJumpToBottom,
  });

  final WorkbenchController workbench;
  final ScrollController scroll;

  /// The sequence to flash, set after a jump from search or the pin bar.
  final int? flashSequence;

  final Future<bool> Function(ChatMessage) onRetry;
  final Future<void> Function() onLoadOlder;
  final ValueChanged<ChatMessage?> onQuote;
  final Future<void> Function(ChatMessage) onEdit;
  final Future<void> Function(ChatMessage) onRecall;
  final Future<void> Function(ChatMessage) onReact;
  final Future<void> Function(ChatMessage) onPin;
  final Future<void> Function(ChatMessage) onForward;
  final VoidCallback onJumpToBottom;
  final bool showJumpToBottom;

  @override
  Widget build(BuildContext context) {
    final messages = workbench.messages;
    if (workbench.loadingThread && messages.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (messages.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Text(
          workbench.threadError ?? '还没有消息，发出第一条回复吧。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    // Day separators are derived from the transcript rather than stored, so a
    // conversation that spans weeks still reads as a timeline.
    final rows = <Widget>[];
    DateTime? lastDay;
    DateTime? lastTime;
    // The divider belongs at the first message this agent had not read, which is
    // the position it occupied when the thread was opened. It is inserted once
    // and only when both sides of it are actually loaded, so it never appears at
    // the very top of a window that simply started mid-thread.
    var dividerPlaced = !workbench.showUnreadDivider;
    for (final message in messages) {
      final day = DateTime(
        message.createdAt.year,
        message.createdAt.month,
        message.createdAt.day,
      );
      if (lastDay == null || day != lastDay) {
        rows.add(_DaySeparator(label: dayLabel(message.createdAt)));
        lastDay = day;
      }
      if (lastTime == null ||
          message.createdAt.difference(lastTime).inMinutes >= 5) {
        final local = message.createdAt.toLocal();
        rows.add(_DaySeparator(
            label:
                '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}'));
      }
      lastTime = message.createdAt;
      if (!dividerPlaced && message.sequence > workbench.readBoundary) {
        rows.add(const _UnreadDivider());
        dividerPlaced = true;
      }
      rows.add(
        _MessageBubble(
          message: message,
          selfId: workbench.selfId,
          fileUrl: workbench.api.fileUrl,
          receipt: workbench.receiptFor(message),
          flash: flashSequence != null && message.sequence == flashSequence,
          onRetry: () => onRetry(message),
          onQuote: () => onQuote(message),
          onEdit: () => onEdit(message),
          onRecall: () => onRecall(message),
          onReact: () => onReact(message),
          onPin: () => onPin(message),
          onForward: () => onForward(message),
        ),
      );
    }
    return Stack(
      children: <Widget>[
        ListView.builder(
          controller: scroll,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          itemCount: rows.length + (workbench.hasMoreHistory ? 1 : 0),
          itemBuilder: (context, index) {
            if (workbench.hasMoreHistory && index == 0) {
              return Center(
                child: workbench.loadingMore
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : TextButton(
                        onPressed: onLoadOlder,
                        child: const Text('加载更早的消息'),
                      ),
              );
            }
            final offset = workbench.hasMoreHistory ? index - 1 : index;
            return rows[offset];
          },
        ),
        if (showJumpToBottom)
          Positioned(
              right: 16,
              bottom: 12,
              child: FilledButton.tonalIcon(
                onPressed: onJumpToBottom,
                icon: const Icon(Icons.arrow_downward, size: 16),
                label: const Text('回到最新消息'),
              )),
        if (workbench.visitorTyping)
          Positioned(
            left: 20,
            bottom: 10,
            child: _TypingHint(),
          ),
      ],
    );
  }
}

/// A "以下为新消息" rule, drawn at the message the agent had not read when the
/// thread was opened. It is derived from the transcript rather than from a stored
/// marker so it cannot drift as the list is re-paged.
class _UnreadDivider extends StatelessWidget {
  const _UnreadDivider();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          const Expanded(child: Divider(color: Colors.transparent)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '以下为新消息',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          Expanded(
            child: Divider(color: theme.colorScheme.error.withAlpha(120)),
          ),
        ],
      ),
    );
  }
}

/// The pin bar: the messages an agent keeps in view while scrolling.
class _PinBar extends StatelessWidget {
  const _PinBar({
    required this.pins,
    required this.onJump,
    required this.onUnpin,
  });

  final List<ChatMessage> pins;
  final ValueChanged<ChatMessage> onJump;
  final Future<void> Function(ChatMessage) onUnpin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(Icons.push_pin, size: 15, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 26,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: pins.length,
                separatorBuilder: (context, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final pin = pins[index];
                  return InkWell(
                    onTap: () => onJump(pin),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        children: <Widget>[
                          Text(
                            pin.isDeleted
                                ? '已撤回的消息'
                                : (pin.content.isEmpty
                                    ? '[${messageTypeLabel(pin.messageType)}]'
                                    : pin.content),
                            style: theme.textTheme.labelSmall,
                          ),
                          IconButton(
                            tooltip: '取消置顶',
                            onPressed: () => onUnpin(pin),
                            visualDensity: VisualDensity.compact,
                            iconSize: 14,
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The in-thread search field. The query is debounced by the caller so typing
/// does not issue a request per keystroke against the full-text index.
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.onChanged,
    required this.onClose,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              onChanged: onChanged,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: '搜索本会话的消息',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭搜索',
            onPressed: onClose,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// The search results, drawn above the transcript rather than inside it so a hit
/// does not have to be loaded to be readable.
class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.workbench, required this.onJump});

  final WorkbenchController workbench;
  final ValueChanged<SearchHit> onJump;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (workbench.searching) {
      return const LinearProgressIndicator(minHeight: 2);
    }
    final hits = workbench.searchHits;
    if (hits.isEmpty) {
      return Container(
        color: theme.colorScheme.surface,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(
          workbench.searchError ?? '没有找到包含该关键词的消息',
          style: theme.textTheme.labelSmall?.copyWith(
            color: workbench.searchError == null
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.error,
          ),
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(maxHeight: 190),
      color: theme.colorScheme.surface,
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: hits.length,
        separatorBuilder: (context, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final hit = hits[index];
          final fromVisitor = hit.senderType == 'VISITOR';
          return ListTile(
            dense: true,
            leading: Icon(
              fromVisitor ? Icons.person_outline : Icons.support_agent,
              size: 18,
            ),
            title: _HighlightedExcerpt(text: hit.excerpt),
            subtitle: Text(
              '${hit.senderName.isEmpty ? (fromVisitor ? '访客' : '客服') : hit.senderName}'
              ' · ${fullTime(hit.createdAt)}',
              style: theme.textTheme.labelSmall,
            ),
            onTap: () => onJump(hit),
          );
        },
      ),
    );
  }
}

/// Renders a server-built excerpt, turning the `<< >>` markers into a highlight.
///
/// The markers are escaped before they are interpreted, so a message that
/// literally contains `<<` cannot forge a highlight — only the delimiter the
/// server inserted can.
class _HighlightedExcerpt extends StatelessWidget {
  const _HighlightedExcerpt({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall;
    final spans = <TextSpan>[];
    var index = 0;
    while (index < text.length) {
      final open = text.indexOf('<<', index);
      if (open < 0) {
        spans.add(TextSpan(text: text.substring(index)));
        break;
      }
      final close = text.indexOf('>>', open + 2);
      if (close < 0) {
        spans.add(TextSpan(text: text.substring(index)));
        break;
      }
      if (open > index) {
        spans.add(TextSpan(text: text.substring(index, open)));
      }
      spans.add(
        TextSpan(
          text: text.substring(open + 2, close),
          style: base?.copyWith(
            backgroundColor: theme.colorScheme.primaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      index = close + 2;
    }
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _TypingHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '对方正在输入…',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: <Widget>[
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// One message.
///
/// Four things can appear in a thread and each is framed differently so the
/// agent can tell them apart without reading: the visitor's messages (left),
/// their own (right, tinted), internal notes (full width, warning colour, never
/// sent to the customer) and system events (centred, subtle).
///
/// A recalled message keeps its place as a tombstone rather than disappearing,
/// so the transcript an agent scrolled past does not shift underneath them.
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.selfId,
    required this.fileUrl,
    required this.receipt,
    required this.flash,
    required this.onRetry,
    required this.onQuote,
    required this.onEdit,
    required this.onRecall,
    required this.onReact,
    required this.onPin,
    required this.onForward,
  });

  final ChatMessage message;
  final String selfId;
  final String Function(String) fileUrl;
  final MessageReceipt receipt;

  /// True while this message is the target of a jump, which draws a brief
  /// highlight so the agent can see where they landed.
  final bool flash;

  final VoidCallback onRetry;
  final VoidCallback onQuote;
  final VoidCallback onEdit;
  final VoidCallback onRecall;
  final VoidCallback onReact;
  final VoidCallback onPin;
  final VoidCallback onForward;

  /// The agent's own bubble keeps the reply bar and the quote control, but a
  /// system event or a note has none of them.
  bool get _mine => message.isMine(selfId);

  bool get _canEdit =>
      !message.isDeleted &&
      message.messageType == 'TEXT' &&
      message.attachments.isEmpty &&
      _mine;

  bool get _canRecall => !message.isDeleted && _mine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (message.isSystem ||
        (message.messageType == 'EVENT' && !message.isPrivate)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(
            message.content,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    if (message.isPrivate) {
      return _NoteBubble(
        message: message,
        flash: flash,
        receipt: receipt,
        onRetry: onRetry,
      );
    }

    final isAgent = message.isFromAgent;
    // 坐席实心蓝气泡用白字；访客白气泡用正文色（腾讯 IM / 云信习惯）。
    final textColor = isAgent && theme.brightness == Brightness.dark
        ? Colors.white
        : theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment:
            isAgent ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 4, left: 4, right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (message.isAi) ...<Widget>[
                  Icon(Icons.auto_awesome,
                      size: 12, color: theme.colorScheme.primary),
                  const SizedBox(width: 4),
                ],
                Text(
                  isAgent
                      ? (message.senderName.isEmpty ? '我' : message.senderName)
                      : (message.senderName.isEmpty
                          ? '访客'
                          : message.senderName),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (message.isAi) ...<Widget>[
                  const SizedBox(width: 6),
                  Text(
                    'AI 自动回复',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
                if (message.isForwarded) ...<Widget>[
                  const SizedBox(width: 6),
                  Text(
                    '转发',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (message.isEdited) ...<Widget>[
                  const SizedBox(width: 6),
                  Text(
                    '已编辑',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (message.isPinned) ...<Widget>[
                  const SizedBox(width: 6),
                  Icon(Icons.push_pin,
                      size: 11, color: theme.colorScheme.primary),
                ],
              ],
            ),
          ),
          _BubbleShell(
            flash: flash,
            isAgent: isAgent,
            onLongPress: message.isDeleted || message.sequence <= 0
                ? null
                : () {
                    final actions = <String, VoidCallback>{
                      '复制': () =>
                          copyToClipboard(context, message.content, '消息内容'),
                      '引用回复': onQuote,
                      '添加回应': onReact,
                      '置顶': onPin,
                      '转发到其它会话': onForward,
                      if (_canEdit) '编辑': onEdit,
                      if (_canRecall) '撤回': onRecall
                    };
                    showModalBottomSheet<void>(
                        context: context,
                        useSafeArea: true,
                        isScrollControlled: true,
                        builder: (sheet) => SafeArea(
                            top: false,
                            child: SingleChildScrollView(
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                  for (final entry in actions.entries)
                                    ListTile(
                                        title: Text(entry.key),
                                        onTap: () {
                                          Navigator.pop(sheet);
                                          entry.value();
                                        }),
                                ]))));
                  },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (message.replyTo != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _QuoteBlock(
                      quote: message.replyTo!,
                      onSurface: isAgent,
                    ),
                  ),
                if (message.isDeleted)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.block,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '这条消息已被撤回',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  )
                else ...<Widget>[
                  if (message.messageType == 'CARD' &&
                      message.metadata['card'] is Map)
                    _CommerceCard(
                        card: Map<String, dynamic>.from(
                            message.metadata['card'] as Map)),
                  if (message.attachments.isNotEmpty)
                    _Attachments(
                      attachments: message.attachments,
                      fileUrl: fileUrl,
                      alignEnd: isAgent,
                      voiceDuration: message.voiceDuration,
                    ),
                  if (message.content.trim().isNotEmpty &&
                      !(message.messageType == 'CARD' &&
                          message.metadata['card'] is Map))
                    Padding(
                      padding: EdgeInsets.only(
                        top: message.attachments.isEmpty ? 0 : 8,
                      ),
                      child: MediaQuery.sizeOf(context).width < 760
                          ? Text(message.content,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color: textColor, fontSize: 15, height: 1.65))
                          : SelectableText(
                              message.content,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: textColor),
                            ),
                    ),
                ],
              ],
            ),
          ),
          // 气泡下方固定展示发送时间；坐席消息再跟投递/已读状态。
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2, right: 2),
            child: _MessageStatusRow(
              sentAt: message.createdAt,
              receipt: receipt,
              alignEnd: isAgent,
              error: message.error,
              onRetry: receipt == MessageReceipt.failed ? onRetry : null,
            ),
          ),
          if (message.reactions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _ReactionRow(reactions: message.reactions),
            ),
          if (!message.isDeleted && message.sequence > 0)
            _BubbleActions(
              isAgent: isAgent,
              onQuote: onQuote,
              onReact: onReact,
              onPin: onPin,
              onForward: onForward,
              onEdit: _canEdit ? onEdit : null,
              onRecall: _canRecall ? onRecall : null,
            ),
        ],
      ),
    );
  }
}

/// The rounded box a message sits in, so the bubble and the jump highlight are
/// defined once instead of at every call site.
class _CommerceCard extends StatelessWidget {
  const _CommerceCard({required this.card});
  final Map<String, dynamic> card;
  @override
  Widget build(BuildContext context) {
    final amount = card['amountMinor'];
    final price = amount is int && amount >= 0
        ? '${amount ~/ 100}.${(amount % 100).toString().padLeft(2, '0')}'
        : '';
    final image = Uri.tryParse('${card['imageUrl'] ?? ''}');
    final link = Uri.tryParse('${card['url'] ?? ''}');
    final order = card['kind'] == 'ORDER';
    return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (image != null && ['http', 'https'].contains(image.scheme))
            Image.network(image.toString(),
                height: 140,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.image_not_supported_outlined)),
          Text('${card['title'] ?? ''}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (order) ...[
            SelectableText('订单号：${card['orderNumber'] ?? ''}'),
            Text('${card['status'] ?? ''}')
          ],
          SelectableText('${card['currency'] ?? ''} $price'),
          if (link != null && ['http', 'https'].contains(link.scheme))
            TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: link.toString()));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('链接已复制')));
                  }
                },
                child: Text('复制${order ? '订单' : '商品'}链接')),
        ]));
  }
}

class _BubbleShell extends StatelessWidget {
  const _BubbleShell({
    required this.flash,
    required this.isAgent,
    required this.child,
    this.onLongPress,
  });

  final bool flash;
  final bool isAgent;
  final Widget child;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mobile = MediaQuery.sizeOf(context).width < 760;
    final bubbleColor = isAgent
        ? RelayTheme.agentBubble(scheme)
        : RelayTheme.visitorBubble(scheme);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: FractionallySizedBox(
        widthFactor: mobile ? .84 : _bubbleWidthFactor,
        alignment: isAgent ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
            onLongPress: mobile ? onLongPress : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                gradient: isAgent && !(mobile && scheme.brightness == Brightness.light)
                    ? RelayTheme.actionGradient
                    : null,
                color: isAgent
                    ? (mobile && scheme.brightness == Brightness.light
                        ? const Color(0xFFDFE8FF)
                        : null)
                    : (mobile && scheme.brightness == Brightness.light
                        ? Colors.white
                        : bubbleColor),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(isAgent ? 16 : 16),
                  topRight: Radius.circular(isAgent ? 16 : 16),
                  bottomLeft: Radius.circular(isAgent ? 16 : 6),
                  bottomRight: Radius.circular(isAgent ? 6 : 16),
                ),
                border: Border.all(
                  color: flash
                      ? scheme.primary
                      : (isAgent
                          ? Colors.transparent
                          : scheme.outlineVariant.withOpacity(.85)),
                  width: flash ? 2 : 1,
                ),
                boxShadow: isAgent && !(mobile && scheme.brightness == Brightness.light)
                    ? RelayTheme.agentBubbleShadow()
                    : [
                        BoxShadow(
                          color: const Color(0xFF3263FF).withOpacity(0.05),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
              ),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  color: isAgent
                      ? (mobile && scheme.brightness == Brightness.light
                          ? scheme.onSurface
                          : Colors.white)
                      : scheme.onSurface,
                ),
                child: child,
              ),
            )),
      ),
    );
  }
}

/// The quote inside a reply. It is a snapshot taken when the reply was written,
/// so editing or recalling the original afterwards does not rewrite history.
class _QuoteBlock extends StatelessWidget {
  const _QuoteBlock({required this.quote, required this.onSurface});

  final QuotedMessage quote;
  final bool onSurface;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // onSurface=true 表示嵌在坐席蓝气泡内，引用条用半透明白。
    final color = onSurface && theme.brightness == Brightness.dark
        ? Colors.white.withOpacity(0.92)
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: color.withAlpha(120), width: 3),
        ),
        color: color.withAlpha(20),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(6),
          bottomRight: Radius.circular(6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            quote.senderName.isEmpty
                ? (quote.senderType == 'VISITOR' ? '访客' : '客服')
                : quote.senderName,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
          Text(
            quote.label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontStyle: quote.isDeleted ? FontStyle.italic : FontStyle.normal,
            ),
          ),
        ],
      ),
    );
  }
}

/// The aggregated reactions under a bubble.
class _ReactionRow extends StatelessWidget {
  const _ReactionRow({required this.reactions});

  final List<MessageReaction> reactions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: <Widget>[
        for (final reaction in reactions)
          Tooltip(
            message: kReactionLabels[reaction.emoji] ?? reaction.emoji,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: reaction.mine
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: reaction.mine
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant,
                ),
              ),
              child: Text(
                '${reaction.emoji} ${reaction.count}',
                style: theme.textTheme.labelSmall,
              ),
            ),
          ),
      ],
    );
  }
}

/// The hover actions under a bubble: reply, react, pin, and — for the agent's own
/// text — edit and recall.
///
/// They are always in the tree rather than revealed on hover, because the same
/// build runs on touch screens where hover does not exist; the affordances are
/// small and dimmed so they do not compete with the message.
class _BubbleActions extends StatelessWidget {
  const _BubbleActions({
    required this.isAgent,
    required this.onQuote,
    required this.onReact,
    required this.onPin,
    required this.onForward,
    this.onEdit,
    this.onRecall,
  });

  final bool isAgent;
  final VoidCallback onQuote;
  final VoidCallback onReact;
  final VoidCallback onPin;
  final VoidCallback onForward;
  final VoidCallback? onEdit;
  final VoidCallback? onRecall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (MediaQuery.sizeOf(context).width < 760) return const SizedBox.shrink();
    return Opacity(
      opacity: 0.65,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _MiniAction(icon: Icons.reply, tooltip: '引用回复', onPressed: onQuote),
          _MiniAction(
              icon: Icons.add_reaction_outlined,
              tooltip: '添加回应',
              onPressed: onReact),
          _MiniAction(
            icon: Icons.push_pin_outlined,
            tooltip: '置顶',
            onPressed: onPin,
          ),
          _MiniAction(
            icon: Icons.forward_outlined,
            tooltip: '转发到其它会话',
            onPressed: onForward,
          ),
          if (onEdit != null)
            _MiniAction(
                icon: Icons.edit_outlined, tooltip: '编辑', onPressed: onEdit),
          if (onRecall != null)
            _MiniAction(
              icon: Icons.delete_outline,
              tooltip: '撤回',
              onPressed: onRecall,
              color: theme.colorScheme.error,
            ),
        ],
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 15),
        color: color,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
      ),
    );
  }
}

/// 消息时间 + 投递回执：发送中 / 未读 / 已送达 / 已读 / 发送失败。
class _MessageStatusRow extends StatelessWidget {
  const _MessageStatusRow({
    required this.sentAt,
    required this.receipt,
    required this.alignEnd,
    this.error,
    this.onRetry,
  });

  final DateTime sentAt;
  final MessageReceipt receipt;
  final bool alignEnd;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mute = theme.colorScheme.outline;
    final children = <Widget>[
      Text(
        clockTime(sentAt),
        style: theme.textTheme.labelSmall?.copyWith(color: mute),
      ),
    ];

    if (receipt == MessageReceipt.sending) {
      children.addAll([
        const SizedBox(width: 6),
        SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            color: mute,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          MessageReceipt.sending.label,
          style: theme.textTheme.labelSmall?.copyWith(color: mute),
        ),
      ]);
    } else if (receipt == MessageReceipt.failed) {
      children.addAll([
        const SizedBox(width: 6),
        Icon(Icons.error_outline, size: 13, color: theme.colorScheme.error),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: Text(
            error?.isNotEmpty == true ? error! : MessageReceipt.failed.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
        if (onRetry != null)
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 26),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('重试'),
          ),
      ]);
    } else if (receipt != MessageReceipt.none) {
      // 三态必须可辨：未读=单勾灰、已送达=双勾灰、已读=双勾主色 + 文案。
      final color =
          receipt == MessageReceipt.read ? theme.colorScheme.primary : mute;
      final icon = switch (receipt) {
        MessageReceipt.read => Icons.done_all,
        MessageReceipt.delivered => Icons.done_all,
        _ => Icons.done,
      };
      children.addAll([
        const SizedBox(width: 6),
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(
          receipt.label,
          style: theme.textTheme.labelSmall?.copyWith(color: color),
        ),
      ]);
    }

    return Align(
      alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

/// An internal note. Rendered full width in a warning tone, because the one
/// mistake that matters here is an agent thinking they replied to the customer.
class _NoteBubble extends StatelessWidget {
  const _NoteBubble({
    required this.message,
    this.flash = false,
    this.receipt = MessageReceipt.none,
    this.onRetry,
  });

  final ChatMessage message;
  final bool flash;
  final MessageReceipt receipt;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.tertiary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            decoration: BoxDecoration(
              color: color
                  .withAlpha(theme.brightness == Brightness.dark ? 36 : 24),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: flash ? theme.colorScheme.primary : color.withAlpha(80),
                width: flash ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.sticky_note_2_outlined, size: 14, color: color),
                    const SizedBox(width: 6),
                    Text(
                      '内部备注',
                      style: theme.textTheme.labelSmall?.copyWith(color: color),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      message.senderName.isEmpty ? '同事' : message.senderName,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (message.isEdited) ...<Widget>[
                      const SizedBox(width: 6),
                      Text(
                        '已编辑',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                SelectableText(message.content,
                    style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _MessageStatusRow(
              sentAt: message.createdAt,
              receipt: receipt == MessageReceipt.none
                  ? MessageReceipt.none
                  : receipt,
              alignEnd: false,
              error: message.error,
              onRetry: receipt == MessageReceipt.failed ? onRetry : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// 坐席端图片全屏预览：双指缩放 + 点遮罩/关闭退出。
void _openImagePreview(BuildContext context, String url) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.88),
    builder: (dialogContext) {
      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(dialogContext).pop(),
                child: const SizedBox.expand(),
              ),
            ),
            Center(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stack) => const Text(
                    '图片加载失败',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(dialogContext).pop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Image and file bubbles. Images are loaded straight from the authenticated
/// file endpoint with the session token in the query, which is why the console
/// does not need a separate image cache layer.
class _Attachments extends StatelessWidget {
  const _Attachments({
    required this.attachments,
    required this.fileUrl,
    required this.alignEnd,
    this.voiceDuration,
  });

  final List<Attachment> attachments;
  final String Function(String) fileUrl;
  final bool alignEnd;

  /// The duration the sending device measured. Audio the player has not buffered
  /// cannot report one, and a voice note that shows no length at all is unhelpful.
  final Duration? voiceDuration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment:
          alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final attachment in attachments)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: attachment.isImage
                ? Builder(
                    builder: (context) {
                      final url = fileUrl(attachment.url);
                      // 主工作台缩略图可点开全屏预览，与访客端灯箱对齐全链路体验。
                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => _openImagePreview(context, url),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                  maxWidth: 260, maxHeight: 260),
                              child: Image.network(
                                url,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stack) =>
                                    _FileChip(
                                  attachment: attachment,
                                  url: url,
                                ),
                                loadingBuilder: (context, child, progress) =>
                                    progress == null
                                        ? child
                                        : const SizedBox(
                                            width: 180,
                                            height: 120,
                                            child: Center(
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2),
                                            ),
                                          ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  )
                : attachment.isAudio
                    ? _VoiceNote(
                        url: fileUrl(attachment.url),
                        duration: voiceDuration,
                        onSurface: alignEnd,
                      )
                    : _FileChip(
                        attachment: attachment,
                        url: fileUrl(attachment.url),
                      ),
          ),
        if (attachments.length > 1)
          Text(
            '共 ${attachments.length} 个附件',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// A voice note: one tap to play, one tap to stop.
///
/// The player is a singleton across the whole console, so this widget only has
/// to remember whether *it* is the note that is playing, and reset when the
/// player moves on.
class _VoiceNote extends StatefulWidget {
  const _VoiceNote({
    required this.url,
    required this.onSurface,
    this.duration,
  });

  final String url;
  final bool onSurface;
  final Duration? duration;

  @override
  State<_VoiceNote> createState() => _VoiceNoteState();
}

class _VoiceNoteState extends State<_VoiceNote> {
  bool _playing = false;
  String? _error;

  @override
  void dispose() {
    // Leaving the thread while a note plays would otherwise keep the audio
    // going with no visible control anywhere on screen.
    if (_playing) {
      unawaited(VoicePlayer.instance.stop());
    }
    super.dispose();
  }

  Future<void> _toggle() async {
    final player = VoicePlayer.instance;
    if (!VoicePlayer.supported) {
      return;
    }
    if (_playing) {
      setState(() => _playing = false);
      await player.stop();
      return;
    }
    setState(() {
      _playing = true;
      _error = null;
    });
    try {
      await player.toggle(
        widget.url,
        onStopped: () {
          if (mounted) {
            setState(() => _playing = false);
          }
        },
      );
    } on Exception catch (failure) {
      if (mounted) {
        setState(() {
          _playing = false;
          _error = '$failure';
        });
      }
    }
  }

  /// How wide to draw the pill, so a long note reads as longer than a short one.
  double get _width {
    final seconds = widget.duration?.inSeconds ?? 1;
    return (72 + seconds.clamp(1, 30) * 4.0).clamp(72.0, 200.0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.onSurface
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;
    final canPlay = VoicePlayer.supported;
    final label = widget.duration == null
        ? '语音'
        : '${widget.duration!.inSeconds.clamp(1, 999)}″';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Tooltip(
          message: canPlay ? '' : '此平台不支持在客户端播放，请下载收听',
          child: InkWell(
            onTap: canPlay ? _toggle : null,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: _width,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: color.withAlpha(28),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: color.withAlpha(70)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    !canPlay
                        ? Icons.download_outlined
                        : (_playing
                            ? Icons.stop_circle_outlined
                            : Icons.play_circle_outline),
                    size: 18,
                    color: color,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _playing
                        ? LinearProgressIndicator(
                            minHeight: 3,
                            backgroundColor: color.withAlpha(40),
                            color: color,
                          )
                        : Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: color),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '播放失败，可下载后收听',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

class _FileChip extends StatelessWidget {
  const _FileChip({required this.attachment, required this.url});

  final Attachment attachment;
  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withAlpha(160),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            attachment.isVideo
                ? Icons.videocam_outlined
                : attachment.isAudio
                    ? Icons.audiotrack_outlined
                    : Icons.insert_drive_file_outlined,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  attachment.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  fileSize(attachment.sizeBytes),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '复制下载链接',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: () {
              copyToClipboard(context, url, '下载链接');
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('下载链接已复制（含访问令牌）')),
              );
            },
            icon: const Icon(Icons.link),
          ),
        ],
      ),
    );
  }
}

/// The composer.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.noteMode,
    required this.sending,
    required this.uploading,
    required this.pending,
    required this.uploadError,
    required this.visitorTyping,
    required this.canned,
    required this.supportsFiles,
    required this.quote,
    this.statusHint,
    this.lockPublicReply = false,
    required this.onChanged,
    required this.onToggleNote,
    required this.onPickImage,
    required this.onPickFile,
    required this.voiceControl,
    required this.onClearQuote,
    required this.onRemovePending,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool noteMode;
  final bool sending;
  final bool uploading;
  final List<Attachment> pending;
  final String? uploadError;
  final bool visitorTyping;
  final List<CannedResponse> canned;
  final bool supportsFiles;

  /// The message the next reply will quote, if the agent picked one.
  final ChatMessage? quote;

  /// 输入区常驻说明（未接待 / 他人会话 / 已解决等）。
  final String? statusHint;

  /// 为 true 时禁止公开回复的附件与语音（内部备注不受影响）。
  final bool lockPublicReply;

  final ValueChanged<String> onChanged;
  final ValueChanged<bool> onToggleNote;
  final Future<void> Function() onPickImage;
  final Future<void> Function() onPickFile;
  final Widget voiceControl;
  final VoidCallback onClearQuote;
  final ValueChanged<String> onRemovePending;
  final Future<void> Function() onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 760;
    if (compact) return _MobileComposer(composer: this);
    void insert(String text) {
      final selection = controller.selection;
      final start =
          selection.start < 0 ? controller.text.length : selection.start;
      final end = selection.end < 0 ? start : selection.end;
      controller.text = controller.text.replaceRange(start, end, text);
      controller.selection =
          TextSelection.collapsed(offset: start + text.length);
      onChanged(controller.text);
      focusNode.requestFocus();
    }

    return Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            top: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                _ComposerModeTab(
                  label: '回复客户',
                  selected: !noteMode,
                  tone: scheme.primary,
                  onTap: () => onToggleNote(false),
                ),
                const SizedBox(width: 6),
                _ComposerModeTab(
                  label: '内部备注',
                  selected: noteMode,
                  tone: const Color(0xFFF97316),
                  onTap: () => onToggleNote(true),
                ),
                const Spacer(),
                if (!lockPublicReply && supportsFiles) ...[
                  Text(
                    'Ctrl + Enter 发送',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(fontSize: 10.5, color: scheme.outline),
                  ),
                ],
              ]),
              const SizedBox(height: 8),
              if (statusHint != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer.withAlpha(160),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline,
                          size: 16, color: scheme.onSecondaryContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          statusHint!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (uploadError != null)
                Text(uploadError!,
                    style: TextStyle(color: scheme.error, fontSize: 12)),
              if (quote != null)
                Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                    decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4)),
                    child: Row(children: [
                      Icon(Icons.reply, size: 15, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(
                              '回复 ${quote!.senderName.isEmpty ? '访客' : quote!.senderName}：${quote!.content}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall)),
                      IconButton(
                          tooltip: '取消引用',
                          onPressed: onClearQuote,
                          iconSize: 16,
                          icon: const Icon(Icons.close))
                    ])),
              if (pending.isNotEmpty)
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final attachment in pending)
                    InputChip(
                        avatar: Icon(
                            attachment.isImage
                                ? Icons.image_outlined
                                : Icons.attach_file,
                            size: 16),
                        label: Text(
                            '${attachment.fileName} · ${fileSize(attachment.sizeBytes)}'),
                        onDeleted: () => onRemovePending(attachment.id))
                ]),
              Shortcuts(
                  shortcuts: const <ShortcutActivator, Intent>{
                    SingleActivator(LogicalKeyboardKey.enter, control: true):
                        _SendIntent(),
                    SingleActivator(LogicalKeyboardKey.numpadEnter,
                        control: true): _SendIntent()
                  },
                  child: Actions(
                      actions: <Type, Action<Intent>>{
                        _SendIntent: CallbackAction<_SendIntent>(onInvoke: (_) {
                          onSend();
                          return null;
                        })
                      },
                      child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          minLines: compact ? 1 : 2,
                          maxLines: compact ? 2 : 5,
                          onChanged: onChanged,
                          textInputAction: TextInputAction.newline,
                          keyboardType: TextInputType.multiline,
                          decoration: InputDecoration(
                              hintText: noteMode
                                  ? '写一条内部备注，访客看不到'
                                  : lockPublicReply
                                      ? '请先完成接待或转派后再回复客户'
                                      : visitorTyping
                                          ? '对方正在输入…'
                                          : compact
                                              ? '输入回复内容…'
                                              : '输入回复内容，Ctrl + Enter 发送',
                              filled: true,
                              fillColor: noteMode
                                  ? scheme.tertiaryContainer.withAlpha(35)
                                  : scheme.surfaceContainerLow,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide:
                                    BorderSide(color: scheme.outlineVariant),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide:
                                    BorderSide(color: scheme.outlineVariant),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide:
                                    BorderSide(color: scheme.primary, width: 1.2),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                  vertical: 10, horizontal: 12),
                              hintStyle: theme.textTheme.bodyMedium
                                  ?.copyWith(color: scheme.outline))))),
              // 输入区在上、工具栏在下，保持原有发送与附件回调。
              Row(children: [
                PopupMenuButton<String>(
                    tooltip: '表情',
                    icon: Icon(Icons.sentiment_satisfied_alt_outlined,
                        size: 22, color: scheme.onSurfaceVariant),
                    onSelected: insert,
                    itemBuilder: (_) => [
                          for (final emoji in [
                            '😊',
                            '👍',
                            '🙏',
                            '🎉',
                            '❤️',
                            '🤔',
                            '✅',
                            '😄'
                          ])
                            PopupMenuItem(
                                value: emoji,
                                child: Text(emoji,
                                    style: const TextStyle(fontSize: 22)))
                        ]),
                IconButton(
                    tooltip: lockPublicReply ? '请先完成接待或转派' : '发送图片',
                    onPressed:
                        uploading || lockPublicReply ? null : onPickImage,
                    icon: Icon(Icons.image_outlined,
                        size: 22, color: scheme.onSurfaceVariant)),
                if (supportsFiles)
                  IconButton(
                      tooltip: lockPublicReply ? '请先完成接待或转派' : '发送文件',
                      onPressed:
                          uploading || lockPublicReply ? null : onPickFile,
                      icon: Icon(Icons.folder_open_outlined,
                          size: 22, color: scheme.onSurfaceVariant)),
                voiceControl,
                if (canned.isNotEmpty)
                  _CannedMenu(
                      canned: canned,
                      onPick: (content) {
                        controller.text = content;
                        controller.selection =
                            TextSelection.collapsed(offset: content.length);
                        onChanged(content);
                        focusNode.requestFocus();
                      }),
                const Spacer(),
                if (uploading)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                    child: Text(
                        noteMode
                            ? '仅团队成员可见'
                            : lockPublicReply
                                ? '需先接待或转派后才能发送'
                                : compact
                                    ? '回复前请确认内容'
                                    : 'Ctrl + Enter 发送 · Enter 换行',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.outline))),
                FilledButton(
                    onPressed: sending ? null : onSend,
                    child: sending
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(noteMode ? '保存备注' : '发送'))
              ]),
              if (!supportsFiles && !compact)
                Text('当前客户端支持发送图片；其他文件可通过开放接口发送。',
                    style: theme.textTheme.bodySmall),
            ]));
  }
}

/// 输入区模式切换：实心淡底 + 主色文字，替代散落的纯文本按钮。
class _ComposerModeTab extends StatelessWidget {
  const _ComposerModeTab({
    required this.label,
    required this.selected,
    required this.tone,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? tone.withOpacity(.09) : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: selected ? tone.withOpacity(.24) : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              height: 1.3,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? tone : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

// 手机输入区只消费父级已经处理好的安全区域，避免重复 padding。
class _MobileComposer extends StatefulWidget {
  const _MobileComposer({required this.composer});
  final _Composer composer;
  @override
  State<_MobileComposer> createState() => _MobileComposerState();
}

class _MobileComposerState extends State<_MobileComposer> {
  bool _tools = false;
  @override
  void initState() {
    super.initState();
    widget.composer.focusNode.addListener(_focus);
  }

  @override
  void didUpdateWidget(covariant _MobileComposer old) {
    super.didUpdateWidget(old);
    if (old.composer.focusNode != widget.composer.focusNode) {
      old.composer.focusNode.removeListener(_focus);
      widget.composer.focusNode.addListener(_focus);
    }
  }

  void _focus() {
    if (mounted && widget.composer.focusNode.hasFocus && _tools)
      setState(() => _tools = false);
  }

  @override
  void dispose() {
    widget.composer.focusNode.removeListener(_focus);
    super.dispose();
  }

  void _insert(String text) {
    final c = widget.composer;
    final selection = c.controller.selection;
    final start =
        selection.isValid ? selection.start : c.controller.text.length;
    final end = selection.isValid ? selection.end : start;
    c.controller.text = c.controller.text.replaceRange(start, end, text);
    c.controller.selection =
        TextSelection.collapsed(offset: start + text.length);
    c.onChanged(c.controller.text);
    c.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.composer;
    final s = Theme.of(context).colorScheme;
    final dark = s.brightness == Brightness.dark;
    final background = dark ? s.surface : const Color(0xFFFAFAFA);
    Widget tool(IconData icon, String label, VoidCallback? action) => SizedBox(
        width: 66,
        child: TextButton(
            onPressed: action,
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                      color: s.surfaceContainerHighest.withOpacity(.5),
                      borderRadius: BorderRadius.circular(12)),
                  child: Icon(icon,
                      size: 23,
                      color: action == null ? s.outline : s.onSurfaceVariant)),
              const SizedBox(height: 5),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      color: action == null ? s.outline : s.onSurfaceVariant))
            ])));
    return Container(
        key: const ValueKey('mobile-composer'),
        padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
        decoration: BoxDecoration(
            color: background,
            border: Border(
                top: BorderSide(color: s.outlineVariant.withOpacity(.55)))),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (c.statusHint != null)
                Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(c.statusHint!,
                        style: TextStyle(
                            fontSize: 12, color: s.onSurfaceVariant))),
              if (c.uploadError != null)
                Text(c.uploadError!,
                    style: TextStyle(color: s.error, fontSize: 12)),
              if (c.noteMode)
                Row(children: [
                  Expanded(
                      child: Text('内部备注 · 仅团队可见',
                          style: TextStyle(fontSize: 12, color: s.tertiary))),
                  TextButton(
                      onPressed: () => c.onToggleNote(false),
                      child: const Text('取消'))
                ]),
              if (c.quote != null)
                Row(children: [
                  const Icon(Icons.reply, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(
                          '回复 ${c.quote!.senderName}：${c.quote!.content}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12))),
                  IconButton(
                      tooltip: '取消引用',
                      onPressed: c.onClearQuote,
                      icon: const Icon(Icons.close, size: 16))
                ]),
              if (c.pending.isNotEmpty)
                Wrap(spacing: 6, children: [
                  for (final a in c.pending)
                    InputChip(
                        label: Text(a.fileName),
                        onDeleted: () => c.onRemovePending(a.id))
                ]),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                SizedBox(
                    width: 30,
                    height: 44,
                    child: IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: _tools ? '收起工具' : '展开工具',
                        onPressed: () {
                          c.focusNode.unfocus();
                          setState(() => _tools = !_tools);
                        },
                        icon: Icon(
                            _tools
                                ? Icons.cancel_outlined
                                : Icons.add_circle_outline,
                            size: 26,
                            color: s.onSurfaceVariant))),
                const SizedBox(width: 6),
                Expanded(
                    child: Container(
                        decoration: BoxDecoration(
                            color: c.noteMode
                                ? s.tertiaryContainer.withOpacity(.25)
                                : s.surface,
                            border: Border.all(
                                color: s.outlineVariant.withOpacity(.6)),
                            borderRadius: BorderRadius.circular(9)),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                  child: TextField(
                                      controller: c.controller,
                                      focusNode: c.focusNode,
                                      minLines: 1,
                                      maxLines: 4,
                                      onChanged: c.onChanged,
                                      textInputAction: TextInputAction.newline,
                                      keyboardType: TextInputType.multiline,
                                      style: const TextStyle(
                                          fontSize: 15, height: 1.6),
                                      decoration: InputDecoration(
                                          hintText: c.noteMode
                                              ? '添加内部备注…'
                                              : c.lockPublicReply
                                                  ? '请先完成接待或转派'
                                                  : c.visitorTyping
                                                      ? '对方正在输入…'
                                                      : '输入消息…',
                                          isDense: true,
                                          filled: false,
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          contentPadding:
                                              const EdgeInsets.fromLTRB(
                                                  11, 9, 0, 9)))),
                              PopupMenuButton<String>(
                                  tooltip: '表情',
                                  padding: EdgeInsets.zero,
                                  constraints:
                                      const BoxConstraints(minWidth: 50),
                                  icon: Icon(
                                      Icons.sentiment_satisfied_alt_outlined,
                                      size: 22,
                                      color: s.onSurfaceVariant),
                                  onSelected: _insert,
                                  itemBuilder: (_) => [
                                        for (final emoji in [
                                          '😊',
                                          '👍',
                                          '🙏',
                                          '❤️',
                                          '✅'
                                        ])
                                          PopupMenuItem(
                                              value: emoji, child: Text(emoji))
                                      ]),
                            ]))),
                const SizedBox(width: 6),
                ValueListenableBuilder<TextEditingValue>(
                    valueListenable: c.controller,
                    builder: (context, value, _) => SizedBox(
                        width: 44,
                        height: 44,
                        child: IconButton.filled(
                            tooltip: c.noteMode ? '保存备注' : '发送',
                            style: IconButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(9))),
                            onPressed: c.sending ||
                                    c.uploading ||
                                    c.lockPublicReply ||
                                    (value.text.trim().isEmpty &&
                                        c.pending.isEmpty)
                                ? null
                                : c.onSend,
                            icon: c.sending || c.uploading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : Icon(
                                    c.noteMode ? Icons.check : Icons.arrow_upward,
                                    size: 22)))),
              ]),
              if (_tools)
                Padding(
                    padding: const EdgeInsets.only(top: 18, bottom: 6),
                    child: Wrap(spacing: 10, runSpacing: 16, children: [
                      tool(
                          Icons.image_outlined,
                          '图片',
                          c.uploading || c.lockPublicReply
                              ? null
                              : () {
                                  c.onPickImage();
                                }),
                      if (c.supportsFiles)
                        tool(
                            Icons.insert_drive_file_outlined,
                            '文件',
                            c.uploading || c.lockPublicReply
                                ? null
                                : () {
                                    c.onPickFile();
                                  }),
                      SizedBox(
                          width: 66,
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            SizedBox(height: 48, child: c.voiceControl),
                            const SizedBox(height: 5),
                            const Text('语音', style: TextStyle(fontSize: 11))
                          ])),
                      if (c.canned.isNotEmpty)
                        SizedBox(
                            width: 66,
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                      height: 48,
                                      child: _CannedMenu(
                                          canned: c.canned,
                                          onPick: (text) {
                                            c.controller.text = text;
                                            c.controller.selection =
                                                TextSelection.collapsed(
                                                    offset: text.length);
                                            c.onChanged(text);
                                            c.focusNode.requestFocus();
                                          })),
                                  const SizedBox(height: 5),
                                  const Text('常用回复',
                                      style: TextStyle(fontSize: 11))
                                ])),
                      tool(Icons.edit_note_outlined, '内部备注', () {
                        c.onToggleNote(true);
                        setState(() => _tools = false);
                        c.focusNode.requestFocus();
                      }),
                    ])),
            ]));
  }
}

/// The Enter-to-send intent, kept as its own type so the shortcut cannot be
/// confused with anything else in the action map.
class _SendIntent extends Intent {
  const _SendIntent();
}

/// Quick replies, filtered to the open conversation's inbox.
class _CannedMenu extends StatelessWidget {
  const _CannedMenu({required this.canned, required this.onPick});

  final List<CannedResponse> canned;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '常用回复',
      icon: const Icon(Icons.bolt_outlined),
      onSelected: onPick,
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        for (final entry in canned)
          PopupMenuItem<String>(
            value: entry.content,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    entry.title,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.content,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Pick a colleague to hand the conversation to.
class _TransferDialog extends StatefulWidget {
  const _TransferDialog({required this.workbench});

  final WorkbenchController workbench;

  @override
  State<_TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends State<_TransferDialog> {
  final _note = TextEditingController();
  String? _agentId;

  @override
  void initState() {
    super.initState();
    if (widget.workbench.agents.isEmpty) {
      widget.workbench.loadAgents();
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String _presenceLabel(AgentSummary agent) {
    switch (agent.presence.toUpperCase()) {
      case 'ONLINE':
        return '在线';
      case 'BUSY':
        return '忙碌';
      case 'AWAY':
        return '离开';
      default:
        return '离线';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final assigning = widget.workbench.selected?.isUnassigned == true;
    final title = assigning ? '分配会话' : '转交会话';
    final lead = assigning
        ? '选择继续跟进的同事，并填写备注。对方将看到完整会话记录。'
        : '选择继续跟进的同事，并填写转交备注。对方将看到完整会话记录。';

    return Semantics(
      identifier: 'desk.transfer.dialog',
      label: '转交会话',
      namesRoute: true,
      scopesRoute: true,
      explicitChildNodes: true,
      child: Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Material(
          color: Colors.white.withOpacity(0.96),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: scheme.outlineVariant.withOpacity(0.95)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 4,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(0xFF5B8CFF),
                      Color(0xFF845EF7),
                      Color(0xFF12B886),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                child: ListenableBuilder(
                  listenable: widget.workbench,
                  builder: (context, _) {
                    final current = widget.workbench.selected?.assigneeId;
                    final candidates = widget.workbench.agents
                        .where((agent) => agent.id != current)
                        .toList(growable: false);
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          lead,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.7,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          assigning ? '分配给' : '转交给',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (candidates.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              '没有可分配的客服，请先给团队成员分配此客服入口。',
                              style: TextStyle(
                                fontSize: 13,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        else
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 200),
                            child: ListView.separated(
                              shrinkWrap: true,
                              itemCount: candidates.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 6),
                              itemBuilder: (context, index) {
                                final agent = candidates[index];
                                final selected = _agentId == agent.id;
                                return Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () =>
                                        setState(() => _agentId = agent.id),
                                    child: AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 160),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 10),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: selected
                                              ? const Color(0xFFB8C9FF)
                                              : scheme.outlineVariant,
                                        ),
                                        gradient: LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: selected
                                              ? const [
                                                  Color(0xFFE8EFFF),
                                                  Color(0xFFE0E9FF),
                                                ]
                                              : const [
                                                  Color(0xFFFFFFFF),
                                                  Color(0xFFF7F9FF),
                                                ],
                                        ),
                                        boxShadow: selected
                                            ? [
                                                BoxShadow(
                                                  color: const Color(0xFF3263FF)
                                                      .withOpacity(0.08),
                                                  blurRadius: 18,
                                                  offset: const Offset(0, 8),
                                                ),
                                              ]
                                            : null,
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 32,
                                            height: 32,
                                            alignment: Alignment.center,
                                            decoration: BoxDecoration(
                                              color: RelayTheme.avatarTray(
                                                  agent.id),
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                            child: Text(
                                              initials(agent.displayName),
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: RelayTheme.avatarInk(
                                                    agent.id),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  agent.displayName,
                                                  style: const TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  '客服 · ${_presenceLabel(agent)} · 接待中 ${agent.openConversations}',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: scheme
                                                        .onSurfaceVariant,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (selected)
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 3),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFEDF2FF),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: const Text(
                                                '已选',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                  color: Color(0xFF3263FF),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        const SizedBox(height: 14),
                        Text(
                          '转交备注',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Semantics(
                          identifier: 'desk.transfer.note',
                          label: '转交备注',
                          textField: true,
                          child: TextField(
                            key: const ValueKey('desk-transfer-note'),
                            controller: _note,
                            minLines: 2,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              hintText: '说明转交原因，便于同事接手（选填）',
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('取消'),
                            ),
                            const SizedBox(width: 8),
                            DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: RelayTheme.actionGradient,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: RelayTheme.popShadow(),
                              ),
                              child: FilledButton(
                                key: const ValueKey('desk-transfer-confirm'),
                                onPressed: _agentId == null
                                    ? null
                                    : () => Navigator.of(context).pop(
                                          (_agentId!, _note.text.trim()),
                                        ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  disabledBackgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: Text(assigning ? '确认分配' : '确认转交'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }
}

/// Edit the conversation's tags. Free text is allowed: a tenant's vocabulary is
/// theirs, and the server deduplicates by name.
class _TagDialog extends StatefulWidget {
  const _TagDialog({required this.workbench});

  final WorkbenchController workbench;

  @override
  State<_TagDialog> createState() => _TagDialogState();
}

class _TagDialogState extends State<_TagDialog> {
  late TextEditingController _input;
  late List<String> _selected;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController();
    _selected =
        List<String>.of(widget.workbench.selected?.tags ?? const <String>[]);
    if (widget.workbench.tags.isEmpty) {
      widget.workbench.loadTags();
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add(String value) {
    final name = value.trim();
    if (name.isEmpty || _selected.contains(name)) {
      return;
    }
    setState(() => _selected = <String>[..._selected, name]);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('会话标签'),
      content: SizedBox(
        width: 380,
        child: ListenableBuilder(
          listenable: widget.workbench,
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TextField(
                  controller: _input,
                  decoration: const InputDecoration(
                    labelText: '添加标签',
                    hintText: '输入后回车',
                    suffixIcon: Icon(Icons.add),
                  ),
                  onSubmitted: _add,
                ),
                const SizedBox(height: 12),
                if (_selected.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final tag in _selected)
                        Chip(
                          label: Text(tag),
                          onDeleted: () => setState(
                            () => _selected = _selected
                                .where((item) => item != tag)
                                .toList(growable: false),
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 12),
                Text(
                  '已有标签',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final tag in widget.workbench.tags)
                      ActionChip(
                        label: Text('${tag.name} (${tag.conversations})'),
                        onPressed: () => _add(tag.name),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            widget.workbench.setTags(_selected);
            Navigator.of(context).pop();
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// A conversation bubble is capped at a fraction of the pane width rather than a
/// fixed number of pixels: on a wide desktop the thread should still read as a
/// conversation, and on a phone the cap must not exceed the screen.
const double _bubbleWidthFactor = 0.68;
