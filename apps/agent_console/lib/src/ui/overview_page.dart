import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/ui/workspace_layout.dart';

/// 工作台首页：先给「现在该做什么」，再给数字和最近会话。
///
/// 视觉对齐 Stitch B：浅灰画布、白色 12 圆角面板、1px 冷色描边，
/// 顶部一行概况 + 左侧待办主卡 + 右侧快捷入口，信息密度高于旧版大卡片。
class OverviewPage extends StatelessWidget {
  const OverviewPage({
    super.key,
    required this.workbench,
    required this.name,
    required this.onInbox,
    required this.onKnowledge,
    this.isAdmin = false,
    this.onIntegrations,
    this.onAutomation,
    this.onEnterprise,
  });

  final WorkbenchController workbench;
  final String name;
  final VoidCallback onInbox;
  final VoidCallback onKnowledge;
  final bool isAdmin;
  final VoidCallback? onIntegrations;
  final VoidCallback? onAutomation;
  final VoidCallback? onEnterprise;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: workbench,
        builder: (context, _) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          final unread =
              workbench.conversations.fold<int>(0, (n, c) => n + c.agentUnread);
          final greeting = name.trim().isEmpty ? '同事' : name.trim();

          return LayoutBuilder(builder: (context, constraints) {
            final narrow = constraints.maxWidth < 900;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  narrow ? 16 : 20, 16, narrow ? 16 : 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _GreetingBar(
                    greeting: greeting,
                    queued: workbench.queued,
                    onInbox: onInbox,
                    onKnowledge: onKnowledge,
                  ),
                  const SizedBox(height: 14),
                  _metricRow(context, unread, narrow),
                  const SizedBox(height: 14),
                  if (narrow) ...[
                    _primaryAction(context, unread),
                    const SizedBox(height: 14),
                    _recentCard(context),
                    const SizedBox(height: 14),
                    _shortcuts(context),
                  ] else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 7,
                          child: Column(children: [
                            _primaryAction(context, unread),
                            const SizedBox(height: 14),
                            _recentCard(context),
                          ]),
                        ),
                        const SizedBox(width: 14),
                        Expanded(flex: 4, child: _shortcuts(context)),
                      ],
                    ),
                  const SizedBox(height: 18),
                  Center(
                    child: Text(
                      '数据来自当前已加载的会话，刷新后更新',
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            );
          });
        },
      );

  Widget _metricRow(BuildContext context, int unread, bool narrow) {
    final metrics = <Widget>[
      WorkspaceKpiCard(
        label: '待接待客户',
        value: '${workbench.queued}',
        icon: Icons.support_agent_rounded,
        tone: workbench.queued > 0
            ? const Color(0xFFF59F00)
            : const Color(0xFF12B886),
        caption: workbench.queued > 0 ? '排队中，尽快领取' : '队列已清空',
        onTap: onInbox,
      ),
      WorkspaceKpiCard(
        label: '未读消息',
        value: '$unread',
        icon: Icons.mark_chat_unread_rounded,
        tone: const Color(0xFF3263FF),
        caption: unread > 0 ? '客户在等你回复' : '暂时没有未读',
        onTap: onInbox,
      ),
      WorkspaceKpiCard(
        label: '已加载会话',
        value: '${workbench.conversations.length}',
        icon: Icons.forum_rounded,
        tone: const Color(0xFF845EF7),
        caption: '当前接待视图',
        onTap: onInbox,
      ),
      WorkspaceKpiCard(
        label: '知识库',
        value: '标准答案',
        icon: Icons.menu_book_rounded,
        tone: const Color(0xFF845EF7),
        caption: '回复前先核对知识与口径',
        onTap: onKnowledge,
      ),
    ];
    if (narrow) {
      return GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.45,
        children: metrics,
      );
    }
    return Row(
      children: [
        for (var i = 0; i < metrics.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(child: metrics[i]),
        ]
      ],
    );
  }

  Widget _primaryAction(BuildContext context, int unread) {
    final scheme = Theme.of(context).colorScheme;
    final hasQueue = workbench.queued > 0;
    final title = hasQueue
        ? '有 ${workbench.queued} 位客户正在等待'
        : unread > 0
            ? '有 $unread 条未读消息待处理'
            : '接待队列已清空';
    final subtitle = hasQueue
        ? '领取后即可开始会话，首响时间会计入服务质量。'
        : unread > 0
            ? '打开客户消息，把未读一次性清掉。'
            : '客户从已接入的网站发来消息后，会先进入待领取队列。';
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF2F5BFF), Color(0xFF4B7BFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(WbTokens.cardRadius),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF3263FF).withOpacity(.18),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(WbTokens.cardRadius),
          onTap: onInbox,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 16, 16),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.16),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.bolt_rounded,
                    color: Colors.white, size: 21),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              height: 1.35)),
                      const SizedBox(height: 3),
                      Text(subtitle,
                          style: TextStyle(
                              color: Colors.white.withOpacity(.82),
                              fontSize: 12,
                              height: 1.5)),
                    ]),
              ),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(hasQueue ? '去接待' : '打开会话',
                      style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF2F5BFF))),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_forward_rounded,
                      size: 14, color: Color(0xFF2F5BFF)),
                ]),
              ),
            ]),
          ),
        ),
      ),
      // 兜底：确保浅色主题下不会出现透明叠层。
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(WbTokens.cardRadius),
        border: Border.all(color: scheme.primary.withOpacity(.10)),
      ),
    );
  }

  Widget _recentCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (workbench.loadingList && workbench.conversations.isEmpty) {
      return const WorkspaceCard(
        child: SizedBox(
          height: 160,
          child: Center(
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))),
        ),
      );
    }
    if (workbench.conversations.isEmpty) {
      return WorkspaceCard(
        title: '最近客户',
        icon: Icons.history_rounded,
        padding: EdgeInsets.zero,
        child: WorkspaceEmptyState(
          icon: Icons.forum_outlined,
          title: '还没有客户来过',
          description: isAdmin
              ? '先到「接入管理」挂上网站代码，客户点开就能发起会话。'
              : '客户从网站发来消息后，会出现在这里。',
          action: isAdmin && onIntegrations != null
              ? FilledButton(
                  onPressed: onIntegrations, child: const Text('去接入网站'))
              : null,
        ),
      );
    }

    final items = workbench.conversations.take(7).toList();
    return WorkspaceListCard(
      title: '最近客户',
      subtitle: '按最近消息排序，点击直接进入会话',
      icon: Icons.history_rounded,
      actions: [
        TextButton(
          onPressed: onInbox,
          child: const Text('查看全部', style: TextStyle(fontSize: 12)),
        ),
      ],
      children: [
        for (final c in items)
          WorkspaceListRow(
            leading: _Avatar(text: conversationInitial(c.title)),
            title: c.title,
            subtitle: c.lastMessagePreview,
            onTap: () {
              workbench.select(c.id);
              onInbox();
            },
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (c.agentUnread > 0)
                WorkspaceTag(text: '${c.agentUnread}', solid: true)
              else
                Icon(Icons.chevron_right_rounded,
                    size: 16, color: scheme.outline),
            ]),
          ),
      ],
    );
  }

  Widget _shortcuts(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = <Widget>[
      WorkspaceListRow(
        icon: Icons.chat_bubble_outline_rounded,
        title: '客户会话',
        subtitle: '接待、回复与转接',
        trailing: Icon(Icons.chevron_right_rounded,
            size: 16, color: scheme.outline),
        onTap: onInbox,
      ),
      WorkspaceListRow(
        icon: Icons.menu_book_outlined,
        title: '知识库',
        subtitle: '标准答案与话术核对',
        trailing: Icon(Icons.chevron_right_rounded,
            size: 16, color: scheme.outline),
        onTap: onKnowledge,
      ),
      if (isAdmin && onIntegrations != null)
        WorkspaceListRow(
          icon: Icons.code_rounded,
          iconTone: const Color(0xFF7C5CFC),
          title: '渠道接入',
          subtitle: '复制代码挂到官网',
          trailing: Icon(Icons.chevron_right_rounded,
              size: 16, color: scheme.outline),
          onTap: onIntegrations,
        ),
      if (isAdmin && onAutomation != null)
        WorkspaceListRow(
          icon: Icons.auto_awesome_rounded,
          iconTone: const Color(0xFFF97316),
          title: '自动接待',
          subtitle: '无人在线时兜底应答',
          trailing: Icon(Icons.chevron_right_rounded,
              size: 16, color: scheme.outline),
          onTap: onAutomation,
        ),
      if (isAdmin && onEnterprise != null)
        WorkspaceListRow(
          icon: Icons.group_outlined,
          iconTone: const Color(0xFF31977C),
          title: '团队成员',
          subtitle: '账号、权限与在线状态',
          trailing: Icon(Icons.chevron_right_rounded,
              size: 16, color: scheme.outline),
          onTap: onEnterprise,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkspaceListCard(
          title: '快捷入口',
          subtitle: '常用功能一步直达',
          icon: Icons.grid_view_rounded,
          padded: false,
          children: items,
        ),
        const SizedBox(height: 14),
        WorkspaceCard(
          title: '服务提醒',
          icon: Icons.lightbulb_outline_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              _TipRow(text: '首响时间从客户发出消息开始计算，尽量保持在线。'),
              SizedBox(height: 8),
              _TipRow(text: '离开或离线后不再自动分配新会话，已接待的会话保留。'),
              SizedBox(height: 8),
              _TipRow(text: '涉及价格、承诺与账号信息时，先核对知识库再回复。'),
            ],
          ),
        ),
      ],
    );
  }
}

class _GreetingBar extends StatelessWidget {
  const _GreetingBar(
      {required this.greeting,
      required this.queued,
      required this.onInbox,
      required this.onKnowledge});
  final String greeting;
  final int queued;
  final VoidCallback onInbox;
  final VoidCallback onKnowledge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = DateTime.now();
    final hour = now.hour;
    final period = hour < 6
        ? '凌晨'
        : hour < 12
            ? '上午'
            : hour < 14
                ? '中午'
                : hour < 18
                    ? '下午'
                    : '晚上';
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 620;
      if (narrow) {
        // 手机工作台：渐变 Hero + 在线态，指标仍用下方真实 KPI 卡。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Text('工作台',
                  style: theme.textTheme.headlineSmall?.copyWith(
                      fontSize: 20, fontWeight: FontWeight.w700, height: 1.2)),
              const SizedBox(width: 8),
              WorkspaceTag(
                text: '在线',
                tone: const Color(0xFF12B886),
              ),
            ]),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF5B4FD6),
                    Color(0xFF3263FF),
                    Color(0xFF5B8CFF),
                  ],
                ),
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF3263FF).withOpacity(0.28),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$period好，$greeting',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xE6FFFFFF),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    queued > 0
                        ? '待接待 $queued · 点此进入客户消息'
                        : '接待队列已清空 · 点此查看会话',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _HeroPill(
                        label: queued > 0 ? '待接待 $queued' : '队列空闲',
                        onTap: onInbox,
                      ),
                      _HeroPill(label: '打开知识库', onTap: onKnowledge),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      }
      final copy = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Text('工作台',
                style: theme.textTheme.headlineSmall?.copyWith(
                    fontSize: 22, fontWeight: FontWeight.w700, height: 1.2)),
            const SizedBox(width: 8),
            WorkspaceTag(
                text: queued > 0 ? '$queued 个待接待' : '队列已清空',
                tone: queued > 0
                    ? const Color(0xFFF59F00)
                    : const Color(0xFF12B886)),
          ]),
          const SizedBox(height: 4),
          Text(
            '$period好，$greeting。这里汇总当前接待情况与常用入口。',
            style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: scheme.onSurfaceVariant),
          ),
        ],
      );
      final action = Row(mainAxisSize: MainAxisSize.min, children: [
        OutlinedButton.icon(
          onPressed: onKnowledge,
          icon: const Icon(Icons.menu_book_outlined, size: 15),
          label: const Text('知识库'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: onInbox,
          icon: const Icon(Icons.chat_bubble_outline_rounded, size: 15),
          label: const Text('去接待'),
        ),
      ]);
      return Row(children: [
        Expanded(child: copy),
        const SizedBox(width: 16),
        action,
      ]);
    });
  }
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(0.18),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _TipRow extends StatelessWidget {
  const _TipRow({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Container(
          width: 4,
          height: 4,
          decoration: BoxDecoration(
              color: scheme.primary.withOpacity(.55), shape: BoxShape.circle),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(text,
            style: TextStyle(
                fontSize: 11.5,
                height: 1.55,
                color: scheme.onSurfaceVariant)),
      ),
    ]);
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: scheme.primary.withOpacity(.09),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Text(text,
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: scheme.primary)),
    );
  }
}

String conversationInitial(String title) {
  final t = title.trim();
  if (t.isEmpty) return '?';
  return t.substring(0, 1).toUpperCase();
}
