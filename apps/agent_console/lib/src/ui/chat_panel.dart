import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/state/workbench_controller.dart';
import 'package:relaydesk_agent_console/src/theme.dart';
import 'package:relaydesk_agent_console/src/util/attachment_picker.dart';
import 'package:relaydesk_agent_console/src/util/format.dart';

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

  /// Files chosen but not yet sent. They are attached to the next message, which
  /// is what a chat client is expected to do.
  final List<Attachment> _pending = <Attachment>[];

  bool _noteMode = false;
  bool _sending = false;
  bool _uploading = false;
  String? _uploadError;

  Timer? _typingThrottle;
  bool _typingSent = false;

  /// Set while the thread is being re-laid out, so the auto-scroll does not
  /// fight the agent's own scrolling.
  bool _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _composer.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    _typingThrottle?.cancel();
    super.dispose();
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
    setState(() {
      _sending = true;
      _pending.clear();
      _composer.clear();
    });
    _stickToBottom = true;
    final ok = await workbench.send(
      content: text,
      attachments: attachments,
      private: _noteMode,
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

  /// Tells the visitor the agent is typing. Throttled to one frame every few
  /// seconds: the indicator only needs to switch on.
  void _onComposerChanged(String value) {
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
              onOpenProfile: widget.onOpenProfile,
            ),
            const Divider(height: 1),
            Expanded(
              child: _MessageList(
                key: ValueKey<String>(conversation.id),
                workbench: workbench,
                scroll: _scroll,
                onRetry: workbench.retry,
                onLoadOlder: workbench.loadOlder,
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
              onChanged: _onComposerChanged,
              onToggleNote: (value) => setState(() => _noteMode = value),
              onPickImage: _pickImage,
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
    this.onOpenProfile,
  });

  final Conversation conversation;
  final WorkbenchController workbench;
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
    required this.onRetry,
    required this.onLoadOlder,
    required this.onJumpToBottom,
  });

  final WorkbenchController workbench;
  final ScrollController scroll;
  final Future<bool> Function(ChatMessage) onRetry;
  final Future<void> Function() onLoadOlder;
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
      rows.add(
        _MessageBubble(
          message: message,
          fileUrl: workbench.api.fileUrl,
          onRetry: () => onRetry(message),
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
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.fileUrl,
    required this.onRetry,
  });

  final ChatMessage message;
  final String Function(String) fileUrl;
  final VoidCallback onRetry;

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
      return _NoteBubble(message: message);
    }

    final isAgent = message.isFromAgent;
    final bubbleColor = isAgent
        ? theme.colorScheme.primaryContainer
        : RelayTheme.visitorBubble(theme.colorScheme);
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
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: FractionallySizedBox(
              widthFactor: _bubbleWidthFactor,
              alignment: isAgent ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: message.attachments.isEmpty ? 9 : 8,
                ),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(12),
                    topRight: const Radius.circular(12),
                    bottomLeft: Radius.circular(isAgent ? 12 : 3),
                    bottomRight: Radius.circular(isAgent ? 3 : 12),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (message.attachments.isNotEmpty)
                      _Attachments(
                        attachments: message.attachments,
                        fileUrl: fileUrl,
                        alignEnd: isAgent,
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
                ),
              ),
            ),
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
  const _NoteBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.tertiary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: color.withAlpha(theme.brightness == Brightness.dark ? 36 : 24),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(80)),
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
  });

  final List<Attachment> attachments;
  final String Function(String) fileUrl;
  final bool alignEnd;

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
    required this.onChanged,
    required this.onToggleNote,
    required this.onPickImage,
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
  final ValueChanged<String> onChanged;
  final ValueChanged<bool> onToggleNote;
  final Future<void> Function() onPickImage;
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
