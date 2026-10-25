import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/ui/workspace_layout.dart';

import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/state/session_controller.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/theme.dart';
import 'package:tongyu_agent_console/src/util/format.dart';
import 'package:tongyu_agent_console/src/util/labels.dart';

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
    this.onOpenKnowledge,
  });

  final WorkbenchController workbench;
  final SessionController session;
  /// 空态「打开知识库」：仅在有真实工作台分区时传入。
  final VoidCallback? onOpenKnowledge;

  @override
  State<ConversationListPanel> createState() => _ConversationListPanelState();
}

class _ConversationListPanelState extends State<ConversationListPanel> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _searchDebounce;
  int _receptionQueueRequest = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
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
        if (_receptionQueueRequest != workbench.receptionQueueRequest) {
          _receptionQueueRequest = workbench.receptionQueueRequest;
          _searchDebounce?.cancel();
          _search.clear();
        }
        final multiInbox = widget.session.inboxes.length > 1;
        return Column(
          children: <Widget>[
            // B：标题并入筛选行，搜索与入口同行，给列表多腾出约一条高度。
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 2, 0),
              child: Row(
                children: [
                  Text(
                    '客户消息',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(width: 2),
                  // 窄侧栏时 Tab 可横滑，避免和角标、刷新挤爆。
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final entry in const [
                            (QueueFilter.all, '全部'),
                            (QueueFilter.unassigned, '待接待'),
                            (QueueFilter.mine, '我的'),
                          ])
                            _InboxFilterTab(
                              label: entry.$2,
                              selected: workbench.filter == entry.$1,
                              onTap: () => workbench.setFilter(entry.$1),
                            ),
                          Semantics(
                            button: true,
                            label: '含已解决',
                            identifier: 'desk.filter.includeResolved',
                            toggled: workbench.includeResolved,
                            child: Tooltip(
                              message: workbench.includeResolved
                                  ? '列表已含已解决会话，点击可隐藏'
                                  : '列表不含已解决会话，点击可包含',
                              child: TextButton(
                                key: const ValueKey(
                                    'desk-filter-include-resolved'),
                                onPressed: () => workbench.setIncludeResolved(
                                    !workbench.includeResolved),
                                style: TextButton.styleFrom(
                                  foregroundColor: workbench.includeResolved
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurfaceVariant,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6),
                                  minimumSize: const Size(0, 28),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  textStyle: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                child: Text(
                                  '含已解决',
                                  style: TextStyle(
                                    decoration: workbench.includeResolved
                                        ? TextDecoration.underline
                                        : TextDecoration.none,
                                    decorationColor:
                                        theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (workbench.receptionWaiting > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 2),
                      child: Tooltip(
                        message: '待领取或派给你尚未确认的会话',
                        child: InkWell(
                          onTap: workbench.showReceptionQueue,
                          borderRadius: BorderRadius.circular(8),
                          child: _QueueChip(count: workbench.receptionWaiting),
                        ),
                      ),
                    ),
                  if (workbench.unread > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 2),
                      child: Tooltip(
                        message: '未读消息 ${workbench.unread} 条',
                        child: _CountPill(count: workbench.unread),
                      ),
                    ),
                  IconButton(
                    tooltip: '刷新',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 30, minHeight: 30),
                    onPressed: () => workbench.refreshConversations(),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _search,
                      textInputAction: TextInputAction.search,
                      style: const TextStyle(fontSize: 12),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 6),
                        hintText: '搜索客户、内容',
                        prefixIcon:
                            const Icon(Icons.search_rounded, size: 16),
                        prefixIconConstraints: const BoxConstraints(
                            minWidth: 30, minHeight: 30),
                        filled: true,
                        fillColor: theme.colorScheme.surfaceContainerLow,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(7),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(7),
                          borderSide: BorderSide.none,
                        ),
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清除',
                                iconSize: 16,
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  _searchDebounce?.cancel();
                                  _search.clear();
                                  widget.workbench.setSearch('');
                                  setState(() {});
                                },
                              ),
                      ),
                      onSubmitted: (value) {
                        _searchDebounce?.cancel();
                        widget.workbench.setSearch(value.trim());
                      },
                      onChanged: (value) {
                        setState(() {});
                        _debouncedSearch(value);
                      },
                    ),
                  ),
                  if (multiInbox) ...[
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 108,
                      child: DropdownButtonFormField<String?>(
                        value: workbench.inboxFilter,
                        isDense: true,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon:
                              Icon(Icons.inbox_outlined, size: 16),
                          prefixIconConstraints: BoxConstraints(
                              minWidth: 28, minHeight: 28),
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 4, vertical: 4),
                        ),
                        items: <DropdownMenuItem<String?>>[
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text(
                              '全部客服入口',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          for (final inbox in widget.session.inboxes)
                            DropdownMenuItem<String?>(
                              value: inbox.id,
                              child: Text(
                                inbox.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) =>
                            workbench.setInboxFilter(value),
                      ),
                    ),
                  ],
                ],
              ),
            ),
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
      final canOpenKnowledge = widget.onOpenKnowledge != null &&
          workbench.search.isEmpty &&
          workbench.filter == QueueFilter.mine;
      return _Notice(
        icon: Icons.inbox_outlined,
        title: workbench.search.isNotEmpty
            ? '没有找到相关会话'
            : switch (workbench.filter) {
                QueueFilter.mine => '暂无进行中的会话',
                QueueFilter.unassigned => '待接待队列是空的',
                QueueFilter.all => '没有符合条件的会话',
              },
        message: workbench.search.isNotEmpty
            ? '搜索仅在当前筛选和客服入口内进行，可切换全部或打开「含已解决」。'
            : workbench.filter == QueueFilter.mine
                ? '新客户进线后会出现在待接待列表。也可以先整理知识库。'
                : '有新会话时会实时出现在这里。',
        actionLabel: canOpenKnowledge ? '打开知识库' : null,
        onAction: canOpenKnowledge ? widget.onOpenKnowledge : null,
      );
    }
    return RefreshIndicator(
      onRefresh: () => workbench.refreshConversations(),
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        itemCount: workbench.conversations.length,
        itemBuilder: (context, index) {
          final conversation = workbench.conversations[index];
          return Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: _ConversationRow(
                conversation: conversation,
                selected: conversation.id == workbench.selectedId,
                agentId: widget.session.agent?.id ?? '',
                onTap: () => workbench.select(conversation.id),
              ));
        },
      ),
    );
  }
}

/// 腾讯 IM 会话 cell：圆角方头像 + 名/时间一行 + 预览/未读一行，少 chip。
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
    final scheme = theme.colorScheme;
    final unread = conversation.agentUnread > 0;
    final preview = conversation.lastMessagePreview.isEmpty
        ? '暂无消息'
        : conversation.lastMessagePreview;
    final sub = [
      if (conversation.isUnassigned)
        '待接待'
      else if (conversation.assigneeId != agentId &&
          conversation.assigneeName.isNotEmpty)
        conversation.assigneeName,
      if (conversation.isResolved) '已解决',
      preview,
    ].join(' · ');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          decoration: BoxDecoration(
            gradient: selected
                ? const LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xFFEAF0FF), Color(0xFFF3F6FF)],
                  )
                : null,
            border: Border(
              left: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 3,
              ),
              bottom: const BorderSide(color: Color(0xFFF1F3F7)),
            ),
          ),
          child: Row(
            children: <Widget>[
              _Avatar(
                name: conversation.visitorName,
                seed: conversation.visitorId,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        if (conversation.priority > 0) ...<Widget>[
                          Icon(
                            Icons.flag,
                            size: 13,
                            color: conversation.priority >= 2
                                ? scheme.error
                                : const Color(0xFFFF7D00),
                          ),
                          const SizedBox(width: 3),
                        ],
                        Expanded(
                          child: Text(
                            conversation.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight:
                                  unread ? FontWeight.w700 : FontWeight.w500,
                              fontSize: 13,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          relativeTime(conversation.lastMessageAt ??
                              conversation.updatedAt),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant, fontSize: 11)),
                    const SizedBox(height: 9),
                    Row(children: [
                      Flexible(
                          child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                  color: conversation.isUnassigned
                                      ? scheme.tertiaryContainer
                                          .withOpacity(.35)
                                      : scheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(5)),
                              child: Text(
                                  conversation.isUnassigned
                                      ? '待接待'
                                      : conversation.isResolved
                                          ? '已解决'
                                          : conversation.tags.isNotEmpty
                                              ? conversation.tags.first
                                              : conversationSourceLabel(
                                                  conversation.source),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(fontSize: 10)))),
                      const Spacer(),
                      if (unread) _CountPill(count: conversation.agentUnread),
                    ]),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 国内 IM 常用圆角方形头像（非大圆形）。
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.seed});

  final String name;
  final String seed;

  static const double size = 38;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            RelayTheme.avatarTray(seed),
            Color.lerp(RelayTheme.avatarTray(seed), Colors.white, 0.15)!,
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withOpacity(0.5),
            blurRadius: 0,
            spreadRadius: 1,
            offset: Offset.zero,
          ),
        ],
      ),
      child: Text(
        initials(name),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: RelayTheme.avatarInk(seed),
        ),
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
        color: theme.colorScheme.primary,
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

/// 待接待入口：带文案，避免被误认成未读红点。
class _QueueChip extends StatelessWidget {
  const _QueueChip({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '待接待 $count',
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onTertiaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// An empty or failed pane. Empty states in a support tool are read hundreds of
/// times a day, so they say what to do next rather than only what is missing.
/// 收件箱筛选：定稿用下划线 Tab，而不是分段按钮。
class _InboxFilterTab extends StatelessWidget {
  const _InboxFilterTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        // 与标题同行时压矮，给列表腾高度。
        padding: const EdgeInsets.fromLTRB(7, 4, 7, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 2,
              width: selected ? 18 : 0,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
    return WorkspaceEmptyState(
      title: title,
      description: message,
      icon: icon,
      compact: true,
      action: (actionLabel != null && onAction != null)
          ? FilledButton(onPressed: onAction, child: Text(actionLabel!))
          : null,
    );
  }
}
