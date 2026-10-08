import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/state/workbench_controller.dart';
import 'package:relaydesk_agent_console/src/theme.dart';
import 'package:relaydesk_agent_console/src/util/attachment_picker.dart';
import 'package:relaydesk_agent_console/src/util/format.dart';
import 'package:relaydesk_agent_console/src/util/voice_player.dart';

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
  });

  final WorkbenchController workbench;
  final AttachmentPicker picker;

  /// Opens the customer sidebar; null hides the affordance on layouts that
  /// always show it.
  final VoidCallback? onOpenProfile;

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
  bool _sending = false;
  bool _uploading = false;
  String? _uploadError;

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

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    widget.workbench.addListener(_onWorkbenchChanged);
  }

  @override
  void dispose() {
    _draftDebounce?.cancel();
    _flashTimer?.cancel();
    _searchDebounce?.cancel();
    widget.workbench.removeListener(_onWorkbenchChanged);
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
    if (id == _draftConversationId) {
      return;
    }
    unawaited(_syncDraft(id));
  }

  Future<void> _syncDraft(String? conversationId) async {
    _draftDebounce?.cancel();
    _draftConversationId = conversationId;
    _draftLoaded = false;
    _composer.clear();
    if (conversationId == null) {
      _draftLoaded = true;
      return;
    }
    final draft = await widget.workbench.loadDraft(conversationId);
    // The agent may have moved on while the request was in flight; adopting it
    // then would drop the text they are typing into the new thread.
    if (_draftConversationId != conversationId) {
      return;
    }
    _composer.text = draft;
    _composer.selection = TextSelection.collapsed(offset: draft.length);
    _draftLoaded = true;
  }

  void _scheduleDraftSave(String value) {
    if (!_draftLoaded) {
      return;
    }
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(widget.workbench.saveDraft(value));
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) {
      return;
    }
    final distance = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    _stickToBottom = distance < 80;
  }

  /// Advances the thread to the newest message, but only when the agent was
  /// already at the bottom: reading history must not be interrupted by an
  /// incoming message.
  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) {
        return;
      }
      if (!force && !_stickToBottom) {
        return;
      }
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _pickImage() async {
    setState(() {
      _uploading = true;
      _uploadError = null;
    });
    try {
      final picked = await widget.picker.pickImage();
      if (picked == null) {
        return;
      }
      final conversationId = widget.workbench.selectedId;
      if (conversationId == null) {
        return;
      }
      final uploaded = await widget.workbench.api.upload(
        conversationId: conversationId,
        fileName: picked.fileName,
        bytes: picked.bytes,
        contentType: picked.contentType,
      );
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
      setState(() => _uploadError = '上传失败：$error');
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
      }
    }
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
    final attachments = List<Attachment>.of(_pending);
    // The quote is captured before the composer is cleared, so the bubble keeps
    // showing which message it answers.
    final quote = workbench.replyTo?.toQuote();
    setState(() {
      _sending = true;
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
    );
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    if (ok) {
      _scrollToBottom(force: true);
    } else {
      // The message stays in the thread marked as failed, so the agent can see
      // exactly what did not go out and retry it with one tap.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('消息发送失败，可在气泡上重试')),
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
                onJump: (message) => _scrollToMessage(workbench, message.sequence),
                onUnpin: workbench.togglePin,
              ),
            const Divider(height: 1),
            Expanded(
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
                onJumpToBottom: () => _scrollToBottom(force: true),
              ),
            ),
            const Divider(height: 1),
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
              onChanged: _onComposerChanged,
              onToggleNote: (value) => setState(() => _noteMode = value),
              onPickImage: _pickImage,
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
    final index = workbench.messages.indexWhere((item) => item.sequence == sequence);
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
      final fraction = workbench.messages.isEmpty
          ? 0.0
          : index / workbench.messages.length;
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
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.forum_outlined,
            size: 52,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 14),
          Text('选择一个会话开始回复', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            '左侧列表按优先级与最近消息排序。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
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
  });

  final Conversation conversation;
  final WorkbenchController workbench;
  final bool searchOpen;
  final VoidCallback onToggleSearch;
  final VoidCallback? onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        conversation.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (conversation.isResolved)
                      const _HeaderChip(label: '已解决', tone: _ChipTone.neutral)
                    else if (conversation.isUnassigned)
                      const _HeaderChip(label: '未分配', tone: _ChipTone.warn)
                    else
                      _HeaderChip(
                        label: conversation.assigneeName.isEmpty
                            ? '处理中'
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
                ),
                const SizedBox(height: 2),
                Text(
                  '会话 ${shortId(conversation.id)} · 来源 ${conversation.source} · '
                  '开始于 ${fullTime(conversation.createdAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (conversation.isUnassigned)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: FilledButton.tonalIcon(
                onPressed: workbench.claim,
                icon: const Icon(Icons.pan_tool_alt_outlined, size: 18),
                label: const Text('认领'),
              ),
            ),
          if (onOpenProfile != null)
            IconButton(
              tooltip: '客户资料',
              onPressed: onOpenProfile,
              icon: const Icon(Icons.person_outline),
            ),
          IconButton(
            tooltip: searchOpen ? '关闭搜索' : '搜索会话内容',
            onPressed: onToggleSearch,
            isSelected: searchOpen,
            icon: Icon(searchOpen ? Icons.search_off : Icons.search),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (value) {
              switch (value) {
                case 'resolve':
                  workbench.setStatus('RESOLVED');
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
                  Clipboard.setData(ClipboardData(text: conversation.id));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('会话 ID 已复制')),
                  );
              }
            },
            itemBuilder: (context) => <PopupMenuEntry<String>>[
              if (!conversation.isResolved)
                const PopupMenuItem<String>(
                  value: 'resolve',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.check_circle_outline, size: 18),
                    title: Text('标记已解决'),
                  ),
                )
              else
                const PopupMenuItem<String>(
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
                value: 'transfer',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.swap_horiz, size: 18),
                  title: Text('转接给同事'),
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

  Future<void> _showTransfer(BuildContext context) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => _TransferDialog(workbench: workbench),
    );
    if (selected != null) {
      await workbench.transfer(selected);
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
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withAlpha(90)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
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
      if (!dividerPlaced && message.sequence > workbench.readBoundary) {
        rows.add(const _UnreadDivider());
        dividerPlaced = true;
      }
      rows.add(
        _MessageBubble(
          message: message,
          selfId: workbench.selfId,
          fileUrl: workbench.api.fileUrl,
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
        borderRadius: BorderRadius.circular(12),
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
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Expanded(child: Divider()),
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
    if (message.isSystem || (message.messageType == 'EVENT' && !message.isPrivate)) {
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
      return _NoteBubble(message: message, flash: flash);
    }

    final isAgent = message.isFromAgent;
    final textColor = isAgent
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
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
                  Icon(Icons.auto_awesome, size: 12, color: theme.colorScheme.primary),
                  const SizedBox(width: 4),
                ],
                Text(
                  isAgent
                      ? (message.senderName.isEmpty ? '我' : message.senderName)
                      : (message.senderName.isEmpty ? '访客' : message.senderName),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  clockTime(message.createdAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
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
                  Icon(Icons.push_pin, size: 11, color: theme.colorScheme.primary),
                ],
              ],
            ),
          ),
          _BubbleShell(
            flash: flash,
            isAgent: isAgent,
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
                  if (message.attachments.isNotEmpty)
                    _Attachments(
                      attachments: message.attachments,
                      fileUrl: fileUrl,
                      alignEnd: isAgent,
                      voiceDuration: message.voiceDuration,
                    ),
                  if (message.content.trim().isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(
                        top: message.attachments.isEmpty ? 0 : 8,
                      ),
                      child: SelectableText(
                        message.content,
                        style:
                            theme.textTheme.bodyMedium?.copyWith(color: textColor),
                      ),
                    ),
                ],
              ],
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
          if (message.delivery != DeliveryState.sent)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 2),
              child: _DeliveryFooter(message: message, onRetry: onRetry),
            ),
        ],
      ),
    );
  }
}

/// The rounded box a message sits in, so the bubble and the jump highlight are
/// defined once instead of at every call site.
class _BubbleShell extends StatelessWidget {
  const _BubbleShell({
    required this.flash,
    required this.isAgent,
    required this.child,
  });

  final bool flash;
  final bool isAgent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bubbleColor = isAgent
        ? theme.colorScheme.primaryContainer
        : RelayTheme.visitorBubble(theme.colorScheme);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: FractionallySizedBox(
        widthFactor: _bubbleWidthFactor,
        alignment: isAgent ? Alignment.centerRight : Alignment.centerLeft,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(12),
              topRight: const Radius.circular(12),
              bottomLeft: Radius.circular(isAgent ? 12 : 3),
              bottomRight: Radius.circular(isAgent ? 3 : 12),
            ),
            border: flash
                ? Border.all(color: theme.colorScheme.primary, width: 2)
                : null,
          ),
          child: child,
        ),
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
    final color = onSurface
        ? theme.colorScheme.onPrimaryContainer
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
    return Opacity(
      opacity: 0.65,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _MiniAction(icon: Icons.reply, tooltip: '引用回复', onPressed: onQuote),
          _MiniAction(icon: Icons.add_reaction_outlined, tooltip: '添加回应', onPressed: onReact),
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
            _MiniAction(icon: Icons.edit_outlined, tooltip: '编辑', onPressed: onEdit),
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

/// The delivery state under an outgoing bubble: sending, or failed with a retry.
class _DeliveryFooter extends StatelessWidget {
  const _DeliveryFooter({required this.message, required this.onRetry});

  final ChatMessage message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (message.delivery == DeliveryState.sending) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          ),
          const SizedBox(width: 6),
          Text(
            '发送中',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
        const SizedBox(width: 6),
        Text(
          message.error ?? '发送失败',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        TextButton(
          onPressed: onRetry,
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 28),
          ),
          child: const Text('重试'),
        ),
      ],
    );
  }
}

/// An internal note. Rendered full width in a warning tone, because the one
/// mistake that matters here is an agent thinking they replied to the customer.
class _NoteBubble extends StatelessWidget {
  const _NoteBubble({required this.message, this.flash = false});

  final ChatMessage message;
  final bool flash;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.tertiary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: color.withAlpha(theme.brightness == Brightness.dark ? 36 : 24),
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
                  '${message.senderName.isEmpty ? '同事' : message.senderName} · '
                  '${clockTime(message.createdAt)}',
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
            SelectableText(message.content, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
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
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260, maxHeight: 260),
                      child: Image.network(
                        fileUrl(attachment.url),
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stack) => _FileChip(
                          attachment: attachment,
                          url: fileUrl(attachment.url),
                        ),
                        loadingBuilder: (context, child, progress) => progress == null
                            ? child
                            : const SizedBox(
                                width: 180,
                                height: 120,
                                child: Center(
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                      ),
                    ),
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
                        : (_playing ? Icons.stop_circle_outlined : Icons.play_circle_outline),
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
                            style: theme.textTheme.labelSmall?.copyWith(color: color),
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
              Clipboard.setData(ClipboardData(text: url));
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
    required this.onChanged,
    required this.onToggleNote,
    required this.onPickImage,
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

  final ValueChanged<String> onChanged;
  final ValueChanged<bool> onToggleNote;
  final Future<void> Function() onPickImage;
  final VoidCallback onClearQuote;
  final ValueChanged<String> onRemovePending;
  final Future<void> Function() onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (uploadError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                uploadError!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (quote != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border(
                    left: BorderSide(color: theme.colorScheme.primary, width: 3),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.reply, size: 15, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            '回复 ${quote!.senderName.isEmpty ? (quote!.isFromVisitor ? '访客' : '客服') : quote!.senderName}',
                            style: theme.textTheme.labelSmall,
                          ),
                          Text(
                            quote!.content.isEmpty
                                ? '[${messageTypeLabel(quote!.messageType)}]'
                                : quote!.content,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '取消引用',
                      onPressed: onClearQuote,
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ),
          if (pending.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final attachment in pending)
                    InputChip(
                      avatar: Icon(
                        attachment.isImage
                            ? Icons.image_outlined
                            : Icons.attach_file,
                        size: 16,
                      ),
                      label: Text(
                        '${attachment.fileName} · ${fileSize(attachment.sizeBytes)}',
                      ),
                      onDeleted: () => onRemovePending(attachment.id),
                    ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Shortcuts(
                  shortcuts: const <ShortcutActivator, Intent>{
                    // Enter sends and Shift+Enter breaks the line, which is what
                    // a chat client is expected to do on desktop.
                    SingleActivator(LogicalKeyboardKey.enter): _SendIntent(),
                    SingleActivator(LogicalKeyboardKey.numpadEnter): _SendIntent(),
                  },
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      _SendIntent: CallbackAction<_SendIntent>(
                        onInvoke: (_) {
                          onSend();
                          return null;
                        },
                      ),
                    },
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      minLines: 1,
                      maxLines: 6,
                      onChanged: onChanged,
                      textInputAction: TextInputAction.newline,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                        hintText: noteMode
                            ? '写一条内部备注，访客看不到'
                            : (visitorTyping ? '对方正在输入…' : '输入回复，Enter 发送，Shift+Enter 换行'),
                        hintStyle: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: noteMode
                                ? theme.colorScheme.tertiary
                                : theme.colorScheme.outlineVariant,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: noteMode
                                ? theme.colorScheme.tertiary
                                : theme.colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Tooltip(
                        message: noteMode ? '切换到回复访客' : '切换为内部备注',
                        child: IconButton(
                          onPressed: () => onToggleNote(!noteMode),
                          isSelected: noteMode,
                          color: noteMode ? theme.colorScheme.tertiary : null,
                          icon: Icon(
                            noteMode
                                ? Icons.sticky_note_2
                                : Icons.sticky_note_2_outlined,
                          ),
                        ),
                      ),
                      Tooltip(
                        message: '发送图片',
                        child: IconButton(
                          onPressed: uploading ? null : onPickImage,
                          icon: uploading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.image_outlined),
                        ),
                      ),
                      if (canned.isNotEmpty)
                        _CannedMenu(
                          canned: canned,
                          onPick: (content) {
                            controller.text = content;
                            controller.selection = TextSelection.collapsed(
                              offset: content.length,
                            );
                            focusNode.requestFocus();
                          },
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: FilledButton.icon(
                      onPressed: sending ? null : onSend,
                      icon: sending
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(noteMode ? Icons.note_add_outlined : Icons.send, size: 18),
                      label: Text(noteMode ? '记备注' : '发送'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (!supportsFiles)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '当前客户端支持发送图片；其他文件类型可通过开放接口发送。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
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
    // Agents may not be loaded yet on a cold start; loading here keeps the
    // dialog usable without blocking the workbench.
    if (widget.workbench.agents.isEmpty) {
      widget.workbench.loadAgents();
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('转接会话'),
      content: SizedBox(
        width: 380,
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
              children: <Widget>[
                if (candidates.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('没有其他可转接的坐席。'),
                  )
                else
                  DropdownButtonFormField<String>(
                    value: _agentId,
                    decoration: const InputDecoration(labelText: '选择坐席'),
                    items: <DropdownMenuItem<String>>[
                      for (final agent in candidates)
                        DropdownMenuItem<String>(
                          value: agent.id,
                          child: Text(
                            '${agent.displayName} · ${agent.isOnline ? '在线' : '离线'}'
                            '（进行中 ${agent.openConversations}）',
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(() => _agentId = value),
                  ),
                const SizedBox(height: 14),
                TextField(
                  controller: _note,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '交接说明（会作为内部备注记录）',
                  ),
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
          onPressed: _agentId == null
              ? null
              : () => Navigator.of(context).pop(_agentId),
          child: const Text('转接'),
        ),
      ],
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
    _selected = List<String>.of(widget.workbench.selected?.tags ?? const <String>[]);
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
