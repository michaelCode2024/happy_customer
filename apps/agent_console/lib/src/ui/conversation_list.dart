import 'dart:async';

import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/state/session_controller.dart';
import 'package:relaydesk_agent_console/src/state/workbench_controller.dart';
import 'package:relaydesk_agent_console/src/util/format.dart';

/// The left pane of the workbench: which conversations to work on.
///
/// The order the server returns is deliberate and preserved here — priority
/// first, then most recent activity — because that is the order an agent should
/// work in. The console never re-sorts the queue on the client.
class ConversationListPanel extends StatefulWidget {
  const ConversationListPanel({
    super.key,
    required this.workbench,
    required this.session,
  });

  final WorkbenchController workbench;
  final SessionController session;

  @override
  State<ConversationListPanel> createState() => _ConversationListPanelState();
}

class _ConversationListPanelState extends State<ConversationListPanel> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Pulls the next page when the agent nears the bottom. The queue is capped at
  /// the requested page size server-side, so scrolling is what turns "the newest
  /// fifty" into "the whole backlog".
  void _onScroll() {
    if (!_scroll.hasClients) {
      return;
    }
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 320 && !widget.workbench.loadingList) {
      // The controller's fetch is already idempotent and de-duplicated; asking
      // again near the bottom is cheaper than tracking a page cursor here.
      widget.workbench.refreshConversations(silent: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.workbench,
      builder: (context, _) {
        final workbench = widget.workbench;
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  hintText: '搜索客户或消息内容',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除',
                          iconSize: 18,
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _search.clear();
                            widget.workbench.setSearch('');
                            setState(() {});
                          },
                        ),
                ),
                onChanged: (value) {
                  setState(() {});
                  _debouncedSearch(value);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: <Widget>[
                  Text('会话',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  if (workbench.queued > 0) ...<Widget>[
                    Text('待分配',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(width: 6),
                    Tooltip(
                      message: '待分配 ${workbench.queued} 个会话',
                      child: _CountPill(count: workbench.queued),
                    ),
                    const SizedBox(width: 10),
                  ],
                  IconButton(
                    tooltip: '刷新',
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => workbench.refreshConversations(),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<QueueFilter>(
                  showSelectedIcon: false,
                  segments: const <ButtonSegment<QueueFilter>>[
                    ButtonSegment<QueueFilter>(
                      value: QueueFilter.mine,
                      label: Text('我的'),
                    ),
                    ButtonSegment<QueueFilter>(
                      value: QueueFilter.unassigned,
                      label: Text('待分配'),
                    ),
                    ButtonSegment<QueueFilter>(
                      value: QueueFilter.all,
                      label: Text('全部'),
                    ),
                  ],
                  selected: <QueueFilter>{workbench.filter},
                  onSelectionChanged: (selection) =>
                      workbench.setFilter(selection.first),
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 4),
                    ),
                    textStyle: WidgetStatePropertyAll<TextStyle?>(
                      theme.textTheme.labelMedium,
                    ),
                  ),
                ),
              ),
            ),
            if (widget.session.inboxes.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: DropdownButtonFormField<String?>(
                  value: workbench.inboxFilter,
                  isDense: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.inbox_outlined, size: 18),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                  items: <DropdownMenuItem<String?>>[
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('全部客服入口'),
                    ),
                    for (final inbox in widget.session.inboxes)
                      DropdownMenuItem<String?>(
                        value: inbox.id,
                        child: Text(inbox.name),
                      ),
                  ],
                  onChanged: (value) => workbench.setInboxFilter(value),
                ),
              ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            Expanded(child: _body(theme)),
          ],
        );
      },
    );
  }

  /// A short debounce: the server searches, so one request per keystroke would
  /// be wasteful, but the agent should still see results while typing.
  void _debouncedSearch(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 320), () {
      if (mounted) {
        widget.workbench.setSearch(value);
      }
    });
  }

  @override
  void deactivate() {
    _searchDebounce?.cancel();
    super.deactivate();
  }

  Widget _body(ThemeData theme) {
    final workbench = widget.workbench;
    if (workbench.loadingList && workbench.conversations.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (workbench.listError != null && workbench.conversations.isEmpty) {
      return _Notice(
        icon: Icons.cloud_off_outlined,
        title: '无法加载会话',
        message: workbench.listError!,
        actionLabel: '重试',
        onAction: () => workbench.refreshConversations(),
      );
    }
    if (workbench.conversations.isEmpty) {
      return _Notice(
        icon: Icons.inbox_outlined,
        title: switch (workbench.filter) {
          QueueFilter.mine => '暂时没有分配给你的会话',
          QueueFilter.unassigned => '待分配队列是空的',
          QueueFilter.all => '没有符合条件的会话',
        },
        message: workbench.filter == QueueFilter.mine
            ? '切到「待分配」认领会话，或等待自动分配。'
            : '有新会话时会实时出现在这里。',
      );
    }
    return RefreshIndicator(
      onRefresh: () => workbench.refreshConversations(),
      child: ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: workbench.conversations.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 54),
        itemBuilder: (context, index) {
          final conversation = workbench.conversations[index];
          return _ConversationRow(
            conversation: conversation,
            selected: conversation.id == workbench.selectedId,
            agentId: widget.session.agent?.id ?? '',
            onTap: () => workbench.select(conversation.id),
          );
        },
      ),
    );
  }
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({
    required this.conversation,
    required this.selected,
    required this.agentId,
    required this.onTap,
  });

  final Conversation conversation;
  final bool selected;
  final String agentId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unread = conversation.agentUnread > 0;
    return InkWell(
      onTap: onTap,
      child: Container(
        color:
            selected ? theme.colorScheme.primaryContainer.withAlpha(120) : null,
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _Avatar(
                name: conversation.visitorName, seed: conversation.visitorId),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      if (conversation.priority > 0) ...<Widget>[
                        Icon(
                          Icons.flag,
                          size: 14,
                          color: conversation.priority >= 2
                              ? theme.colorScheme.error
                              : theme.colorScheme.tertiary,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight:
                                unread ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        relativeTime(conversation.lastMessageAt ??
                            conversation.updatedAt),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          conversation.lastMessagePreview.isEmpty
                              ? '（暂无消息）'
                              : conversation.lastMessagePreview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (unread) ...<Widget>[
                        const SizedBox(width: 8),
                        _CountPill(count: conversation.agentUnread),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      _StatusChip(status: conversation.status),
                      if (conversation.isUnassigned)
                        const _MiniChip(label: '未分配')
                      else if (conversation.assigneeId != agentId)
                        _MiniChip(
                          label: conversation.assigneeName.isEmpty
                              ? '他人处理中'
                              : conversation.assigneeName,
                        ),
                      // 列表只露一个标签，避免 chip 堆叠把队列做成仪表盘。
                      for (final tag in conversation.tags.take(1))
                        _MiniChip(label: tag, tinted: true),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The round initials badge. Colours are derived from the id so the same visitor
/// looks the same on every screen without the server storing a colour.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.seed});

  final String name;
  final String seed;

  static const double size = 32;

  @override
  Widget build(BuildContext context) {
    final hue = avatarHue(seed);
    final background =
        HSLColor.fromAHSL(1, hue.toDouble(), 0.42, 0.62).toColor();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Text(
        initials(name),
        style: const TextStyle(
          fontSize: size * 0.36,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (status) {
      'OPEN' => ('进行中', theme.colorScheme.primary),
      'PENDING' => ('等待中', theme.colorScheme.tertiary),
      'RESOLVED' => ('已解决', theme.colorScheme.outline),
      _ => (status, theme.colorScheme.outline),
    };
    return _MiniChip(label: label, tint: color);
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.label, this.tint, this.tinted = false});

  final String label;
  final Color? tint;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tint ??
        (tinted
            ? theme.colorScheme.secondary
            : theme.colorScheme.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(theme.brightness == Brightness.dark ? 40 : 28),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.error,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onError,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// An empty or failed pane. Empty states in a support tool are read hundreds of
/// times a day, so they say what to do next rather than only what is missing.
class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 14),
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
