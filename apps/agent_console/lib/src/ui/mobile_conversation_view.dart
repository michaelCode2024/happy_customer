import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/state/session_controller.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/theme.dart';
import 'package:tongyu_agent_console/src/util/format.dart';

/// 移动端专属会话列表视图：
/// 专为手机触控、单手操作设计，具备原生移动 IM 风格的搜索栏、胶囊筛选条、卡片式会话 Cell、
/// 下拉刷新、触感反馈与长按快捷操作抽屉。
class MobileConversationListView extends StatefulWidget {
  const MobileConversationListView({
    super.key,
    required this.workbench,
    required this.session,
    this.onOpenKnowledge,
  });

  final WorkbenchController workbench;
  final SessionController session;
  final VoidCallback? onOpenKnowledge;

  @override
  State<MobileConversationListView> createState() =>
      _MobileConversationListViewState();
}

class _MobileConversationListViewState
    extends State<MobileConversationListView> {
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

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 320 && !widget.workbench.loadingList) {
      widget.workbench.refreshConversations(silent: true);
    }
  }

  void _debouncedSearch(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 280), () {
      if (mounted) {
        widget.workbench.setSearch(value);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ListenableBuilder(
      listenable: widget.workbench,
      builder: (context, _) {
        final workbench = widget.workbench;
        if (_receptionQueueRequest != workbench.receptionQueueRequest) {
          _receptionQueueRequest = workbench.receptionQueueRequest;
          _searchDebounce?.cancel();
          _search.clear();
        }

        return Container(
          color: isDark ? theme.colorScheme.surface : const Color(0xFFF7F9FC),
          child: Column(
            children: [
              // 移动端顶部搜索与筛选区
              _buildSearchAndFilters(context, workbench),
              // 会话列表主体
              Expanded(
                child: _buildListBody(context, workbench),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSearchAndFilters(
      BuildContext context, WorkbenchController workbench) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? scheme.surface : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? scheme.outlineVariant.withAlpha(50)
                : const Color(0xFFE8EEF5),
            width: 0.8,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 手机专属圆角搜索栏
          Container(
            height: 38,
            decoration: BoxDecoration(
              color: isDark
                  ? scheme.surfaceContainerHighest
                  : const Color(0xFFF1F4F9),
              borderRadius: BorderRadius.circular(19),
            ),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
                hintText: '搜索客户姓名、会话内容…',
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: isDark ? scheme.outline : RelayTheme.muted,
                ),
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  size: 19,
                  color: RelayTheme.muted,
                ),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 38, minHeight: 38),
                border: InputBorder.none,
                isDense: true,
                suffixIcon: _search.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 17),
                        color: RelayTheme.muted,
                        onPressed: () {
                          _searchDebounce?.cancel();
                          _search.clear();
                          widget.workbench.setSearch('');
                          setState(() {});
                        },
                      )
                    : null,
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
          const SizedBox(height: 10),
          // 胶囊分段筛选条
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: [
                _buildFilterChip(
                  label: '全部',
                  selected: workbench.filter == QueueFilter.all,
                  onTap: () => workbench.setFilter(QueueFilter.all),
                ),
                const SizedBox(width: 8),
                _buildFilterChip(
                  label: '待接待',
                  count: workbench.receptionWaiting > 0
                      ? workbench.receptionWaiting
                      : null,
                  countIsAlert: true,
                  selected: workbench.filter == QueueFilter.unassigned,
                  onTap: () => workbench.setFilter(QueueFilter.unassigned),
                ),
                const SizedBox(width: 8),
                _buildFilterChip(
                  label: '我的',
                  count: workbench.unread > 0 ? workbench.unread : null,
                  selected: workbench.filter == QueueFilter.mine,
                  onTap: () => workbench.setFilter(QueueFilter.mine),
                ),
                const SizedBox(width: 8),
                _buildToggleChip(
                  label: '含已解决',
                  active: workbench.includeResolved,
                  onTap: () =>
                      workbench.setIncludeResolved(!workbench.includeResolved),
                ),
                if (widget.session.inboxes.length > 1) ...[
                  const SizedBox(width: 8),
                  _buildInboxFilter(context, workbench),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    int? count,
    bool countIsAlert = false,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? RelayTheme.blue
              : (isDark
                  ? theme.colorScheme.surfaceContainerHighest
                  : const Color(0xFFEDF2F9)),
          borderRadius: BorderRadius.circular(16),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: RelayTheme.blue.withAlpha(70),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? Colors.white
                    : (isDark
                        ? theme.colorScheme.onSurface
                        : const Color(0xFF4A5A74)),
              ),
            ),
            if (count != null && count > 0) ...[
              const SizedBox(width: 5),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: selected
                      ? Colors.white
                      : (countIsAlert
                          ? const Color(0xFFF97316)
                          : RelayTheme.blue),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: selected
                        ? RelayTheme.blue
                        : Colors.white,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildToggleChip({
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return InkWell(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? RelayTheme.blueSoft
              : (isDark
                  ? theme.colorScheme.surfaceContainerHighest
                  : const Color(0xFFEDF2F9)),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active
                ? RelayTheme.blue.withAlpha(120)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? Icons.check_circle_rounded : Icons.filter_alt_outlined,
              size: 13,
              color: active ? RelayTheme.blue : RelayTheme.muted,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: active
                    ? RelayTheme.blue
                    : (isDark ? theme.colorScheme.outline : RelayTheme.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInboxFilter(
      BuildContext context, WorkbenchController workbench) {
    return PopupMenuButton<String?>(
      initialValue: workbench.inboxFilter,
      onSelected: (val) => workbench.setInboxFilter(val),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: workbench.inboxFilter != null
              ? RelayTheme.blueSoft
              : const Color(0xFFEDF2F9),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox_outlined, size: 14, color: RelayTheme.muted),
            const SizedBox(width: 4),
            Text(
              workbench.inboxFilter != null
                  ? (widget.session.inboxes
                          .firstWhere((i) => i.id == workbench.inboxFilter,
                              orElse: () => widget.session.inboxes.first)
                          .name)
                  : '入口筛选',
              style: const TextStyle(fontSize: 12, color: RelayTheme.muted),
            ),
            const Icon(Icons.arrow_drop_down, size: 16, color: RelayTheme.muted),
          ],
        ),
      ),
      itemBuilder: (ctx) => [
        const PopupMenuItem<String?>(
          value: null,
          child: Text('全部客服入口'),
        ),
        for (final inbox in widget.session.inboxes)
          PopupMenuItem<String?>(
            value: inbox.id,
            child: Text(inbox.name),
          ),
      ],
    );
  }

  Widget _buildListBody(
      BuildContext context, WorkbenchController workbench) {
    if (workbench.loadingList && workbench.conversations.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          valueColor: AlwaysStoppedAnimation<Color>(RelayTheme.blue),
        ),
      );
    }

    if (workbench.listError != null && workbench.conversations.isEmpty) {
      return _buildEmptyState(
        icon: Icons.cloud_off_rounded,
        title: '无法加载会话',
        message: workbench.listError!,
        actionLabel: '重新加载',
        onAction: () => workbench.refreshConversations(),
      );
    }

    if (workbench.conversations.isEmpty) {
      final canOpenKnowledge = widget.onOpenKnowledge != null &&
          workbench.search.isEmpty &&
          workbench.filter == QueueFilter.mine;
      return _buildEmptyState(
        icon: workbench.search.isNotEmpty
            ? Icons.search_off_rounded
            : Icons.forum_outlined,
        title: workbench.search.isNotEmpty
            ? '未搜索到相关会话'
            : switch (workbench.filter) {
                QueueFilter.mine => '暂无进行中的会话',
                QueueFilter.unassigned => '待接待队列已清空',
                QueueFilter.all => '没有符合条件的会话',
              },
        message: workbench.search.isNotEmpty
            ? '可尝试切换搜索词，或开启「含已解决」查看历史会话。'
            : workbench.filter == QueueFilter.mine
                ? '新客户进线后将出现在待接待列表，接单后即可开始沟通。'
                : '有新客户接入时会实时通知您。',
        actionLabel: canOpenKnowledge ? '查看知识库' : null,
        onAction: canOpenKnowledge ? widget.onOpenKnowledge : null,
      );
    }

    return RefreshIndicator(
      color: RelayTheme.blue,
      onRefresh: () async {
        HapticFeedback.mediumImpact();
        await workbench.refreshConversations();
      },
      child: ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: workbench.conversations.length,
        separatorBuilder: (_, __) => const Divider(
          height: 1,
          thickness: 0.6,
          indent: 72,
          endIndent: 14,
          color: Color(0xFFEDF2F7),
        ),
        itemBuilder: (context, index) {
          final conversation = workbench.conversations[index];
          return _MobileConversationCell(
            conversation: conversation,
            currentAgentId: widget.session.agent?.id ?? '',
            onTap: () {
              HapticFeedback.selectionClick();
              workbench.select(conversation.id);
            },
            onAction: (action) => _handleCellAction(conversation, action),
          );
        },
      ),
    );
  }

  void _handleCellAction(Conversation conversation, String action) {
    switch (action) {
      case 'resolve':
        widget.workbench.select(conversation.id);
        widget.workbench.setStatus('RESOLVED');
      case 'reopen':
        widget.workbench.select(conversation.id);
        widget.workbench.setStatus('OPEN');
      case 'priority':
        final next = conversation.priority >= 2 ? 0 : 2;
        widget.workbench.select(conversation.id);
        widget.workbench.setPriority(next);
      case 'copy_id':
        Clipboard.setData(ClipboardData(text: conversation.id));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已复制会话 ID')),
        );
    }
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: isDark
                    ? theme.colorScheme.surfaceContainerHighest
                    : const Color(0xFFEBF1FF),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 30, color: RelayTheme.blue),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDark ? theme.colorScheme.onSurface : RelayTheme.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: isDark ? theme.colorScheme.outline : RelayTheme.muted,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: RelayTheme.blue,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                ),
                child: Text(actionLabel, style: const TextStyle(fontSize: 13)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 移动端专属会话单元格（Cell）：
/// 契合手机触摸屏高频点击习惯，高信息辨识度，支持长按菜单。
class _MobileConversationCell extends StatelessWidget {
  const _MobileConversationCell({
    required this.conversation,
    required this.currentAgentId,
    required this.onTap,
    required this.onAction,
  });

  final Conversation conversation;
  final String currentAgentId;
  final VoidCallback onTap;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final unread = conversation.agentUnread > 0;
    final isWaiting = conversation.isUnassigned;

    final lastMessage = conversation.lastMessagePreview.isEmpty
        ? '暂无消息'
        : conversation.lastMessagePreview;

    return Material(
      color: isDark ? theme.colorScheme.surface : Colors.white,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => _showActionSheet(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 头像与来源渠道指示
              _buildAvatar(context),
              const SizedBox(width: 12),
              // 主体内容
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 第一行：客户名称 + 优先级旗帜 + 发送时间
                    Row(
                      children: [
                        if (conversation.priority > 0) ...[
                          Icon(
                            Icons.flag_rounded,
                            size: 14,
                            color: conversation.priority >= 2
                                ? const Color(0xFFEF4444)
                                : const Color(0xFFF59E0B),
                          ),
                          const SizedBox(width: 3),
                        ],
                        Expanded(
                          child: Text(
                            conversation.title.isNotEmpty
                                ? conversation.title
                                : '访客 ${conversation.id.substring(0, 4)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight:
                                  unread ? FontWeight.w700 : FontWeight.w600,
                              color: isDark
                                  ? theme.colorScheme.onSurface
                                  : RelayTheme.ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          relativeTime(conversation.lastMessageAt ??
                              conversation.updatedAt),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: unread
                                ? RelayTheme.blue
                                : (isDark
                                    ? theme.colorScheme.outline
                                    : RelayTheme.muted),
                            fontWeight:
                                unread ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    // 第二行：状态标签 + 消息预览 + 未读角标
                    Row(
                      children: [
                        if (isWaiting) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1.5),
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF4E5),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: const Color(0xFFFFD8A8),
                                width: 0.6,
                              ),
                            ),
                            child: const Text(
                              '待接待',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFD97706),
                              ),
                            ),
                          ),
                        ] else if (conversation.isResolved) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1.5),
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE6FAF3),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: const Color(0xFF96F2D7),
                                width: 0.6,
                              ),
                            ),
                            child: const Text(
                              '已解决',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: RelayTheme.teal,
                              ),
                            ),
                          ),
                        ] else if (conversation.assigneeId != currentAgentId &&
                            conversation.assigneeName.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1.5),
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? theme.colorScheme.surfaceContainerHighest
                                  : const Color(0xFFF1F3F7),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              conversation.assigneeName,
                              style: TextStyle(
                                fontSize: 10,
                                color: isDark
                                    ? theme.colorScheme.outline
                                    : RelayTheme.muted,
                              ),
                            ),
                          ),
                        ],
                        Expanded(
                          child: Text(
                            lastMessage,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: unread
                                  ? (isDark
                                      ? theme.colorScheme.onSurface
                                      : const Color(0xFF2C3E55))
                                  : (isDark
                                      ? theme.colorScheme.outline
                                      : RelayTheme.muted),
                            ),
                          ),
                        ),
                        if (unread) ...[
                          const SizedBox(width: 8),
                          _buildUnreadBadge(conversation.agentUnread),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar(BuildContext context) {
    final name = conversation.visitorName.trim();
    final letter = name.isNotEmpty
        ? name.characters.first
        : (conversation.title.isNotEmpty
            ? conversation.title.characters.first
            : '客');

    // 来源渠道小图标
    final sourceIcon = switch (conversation.source.toLowerCase()) {
      'wechat' || 'wx' => Icons.chat_bubble_outline_rounded,
      'app' || 'mobile' => Icons.phone_android_rounded,
      _ => Icons.language_rounded,
    };

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFE9F0FF), Color(0xFFD4E2FF)],
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Colors.white,
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: RelayTheme.blue.withAlpha(25),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            letter,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: RelayTheme.blue,
            ),
          ),
        ),
        // 来源图标胶囊
        Positioned(
          right: -3,
          bottom: -3,
          child: Container(
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(20),
                  blurRadius: 3,
                ),
              ],
            ),
            child: Icon(
              sourceIcon,
              size: 11,
              color: RelayTheme.blue,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildUnreadBadge(int count) {
    final text = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 19, minHeight: 19),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFFFF3B30),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF3B30).withAlpha(80),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  void _showActionSheet(BuildContext context) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  conversation.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
              const Divider(height: 1),
              if (!conversation.isResolved)
                ListTile(
                  leading: const Icon(Icons.check_circle_outline,
                      color: RelayTheme.teal),
                  title: const Text('标记解决'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onAction('resolve');
                  },
                )
              else
                ListTile(
                  leading: const Icon(Icons.lock_open_rounded,
                      color: RelayTheme.blue),
                  title: const Text('重新打开'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onAction('reopen');
                  },
                ),
              ListTile(
                leading: Icon(
                  Icons.flag_outlined,
                  color: conversation.priority >= 2
                      ? const Color(0xFFEF4444)
                      : const Color(0xFFF59E0B),
                ),
                title: Text(conversation.priority >= 2 ? '取消高优先' : '设为高优先'),
                onTap: () {
                  Navigator.pop(ctx);
                  onAction('priority');
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('复制会话 ID'),
                onTap: () {
                  Navigator.pop(ctx);
                  onAction('copy_id');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
