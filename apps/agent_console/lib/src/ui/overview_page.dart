import 'package:relaydesk_agent_console/src/ui/design_a.dart';
import 'package:flutter/material.dart';
import 'package:relaydesk_agent_console/src/state/workbench_controller.dart';
import 'package:relaydesk_agent_console/src/ui/workspace_layout.dart';

/// 傻瓜式首页：先告诉人「现在该做什么」，再给数字和最近会话。
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
          final scheme = Theme.of(context).colorScheme;
          final theme = Theme.of(context);
          final unread =
              workbench.conversations.fold<int>(0, (n, c) => n + c.agentUnread);
          final greeting = name.trim().isEmpty ? '同事' : name.trim();

          return LayoutBuilder(builder: (context, constraints) {
            final narrow = constraints.maxWidth < 720;
            return SingleChildScrollView(
              padding: EdgeInsets.all(narrow ? 20 : 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  WorkspaceHeading('工作概览', '$greeting，查看当前接待情况与团队工作状态。'),
                  const SizedBox(height: 20),
                  TongYuHero(
                      title: '有温度的服务，\n从一次好好回应开始。',
                      description: '把客户、团队与知识连接起来。专注每一次对话，也看见服务的全貌。',
                      action: FilledButton.icon(
                          onPressed: onInbox,
                          icon: const Icon(Icons.chat_bubble_outline, size: 17),
                          label: const Text('进入消息工作台'))),
                  const SizedBox(height: 20),
                  _PrimaryActionCard(
                    title: workbench.queued > 0
                        ? '有 ${workbench.queued} 位客户在等'
                        : unread > 0
                            ? '有 $unread 条未读消息'
                            : '去接待客户',
                    subtitle: workbench.queued > 0
                        ? '点进去领取并回复，别让客户干等。'
                        : unread > 0
                            ? '打开客户消息，把未读清掉。'
                            : '客户从网站发来的对话都在这里。',
                    icon: Icons.chat_bubble_rounded,
                    primary: true,
                    onTap: onInbox,
                  ),
                  if (isAdmin) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        if (onIntegrations != null)
                          _SecondaryActionChip(
                            label: '渠道接入',
                            hint: '复制一段代码',
                            icon: Icons.code_rounded,
                            onTap: onIntegrations!,
                            width: narrow ? double.infinity : 260,
                          ),
                        if (onAutomation != null)
                          _SecondaryActionChip(
                            label: '自动接待',
                            hint: '没人时也能应答',
                            icon: Icons.auto_awesome_rounded,
                            onTap: onAutomation!,
                            width: narrow ? double.infinity : 260,
                          ),
                        if (onEnterprise != null)
                          _SecondaryActionChip(
                            label: '团队成员',
                            hint: '多人一起接待',
                            icon: Icons.person_add_alt_1_rounded,
                            onTap: onEnterprise!,
                            width: narrow ? double.infinity : 260,
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  LayoutBuilder(builder: (context, box) {
                    final columns = box.maxWidth < 640 ? 1 : 3;
                    final width = (box.maxWidth - (columns - 1) * 16) / columns;
                    return Wrap(spacing: 16, runSpacing: 16, children: [
                      for (final metric in [
                        (
                          '当前已加载会话',
                          '${workbench.conversations.length}',
                          Icons.forum_outlined
                        ),
                        (
                          '待接待客户',
                          '${workbench.queued}',
                          Icons.schedule_outlined
                        ),
                        (
                          '已加载会话未读消息',
                          '$unread',
                          Icons.mark_chat_unread_outlined
                        ),
                      ])
                        SizedBox(
                            width: width,
                            child: WorkspaceKpiCard(
                                label: metric.$1,
                                value: metric.$2,
                                icon: metric.$3)),
                    ]);
                  }),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Text(
                        '最近客户',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: onInbox,
                        child: const Text('全部消息'),
                      ),
                    ],
                  ),
                  if (workbench.loadingList) const LinearProgressIndicator(),
                  if (workbench.listError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        workbench.listError!,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  if (!workbench.loadingList && workbench.conversations.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          vertical: 32, horizontal: 16),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Column(
                        children: [
                          const TongYuArtwork(size: 130),
                          const SizedBox(height: 12),
                          Text('还没有客户来过', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 6),
                          Text(
                            isAdmin
                                ? '先去「接入网站」挂上代码，客户一点就能聊。'
                                : '等客户从网站发消息后，会出现在这里。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              height: 1.45,
                            ),
                          ),
                          if (isAdmin && onIntegrations != null) ...[
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: onIntegrations,
                              child: const Text('去接入网站'),
                            ),
                          ],
                        ],
                      ),
                    )
                  else
                    Container(
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Column(
                        children: [
                          for (final entry in workbench.conversations
                              .take(6)
                              .toList()
                              .asMap()
                              .entries) ...[
                            if (entry.key > 0)
                              Divider(
                                height: 1,
                                color: scheme.outlineVariant.withOpacity(0.7),
                              ),
                            ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 2,
                              ),
                              leading: CircleAvatar(
                                backgroundColor: scheme.primaryContainer,
                                child: Text(
                                  conversationInitial(entry.value.title),
                                  style: TextStyle(
                                    color: scheme.onPrimaryContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              title: Text(
                                entry.value.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                entry.value.lastMessagePreview,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: entry.value.agentUnread > 0
                                  ? Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: scheme.primary,
                                        borderRadius:
                                            BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        '${entry.value.agentUnread}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    )
                                  : Icon(Icons.chevron_right,
                                      color: scheme.outline),
                              onTap: () {
                                workbench.select(entry.value.id);
                                onInbox();
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: onKnowledge,
                    icon: const Icon(Icons.menu_book_outlined, size: 18),
                    label: const Text('需要标准答案？去知识库'),
                  ),
                ],
              ),
            );
          });
        },
      );
}

class _PrimaryActionCard extends StatelessWidget {
  const _PrimaryActionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.primary = false,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color:
          primary ? scheme.primaryContainer.withOpacity(.45) : scheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 20, 18, 20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: primary ? null : Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: primary
                      ? Colors.white.withOpacity(0.18)
                      : scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  icon,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        height: 1.4,
                        color: primary
                            ? scheme.onSurfaceVariant
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_rounded,
                color: scheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SecondaryActionChip extends StatelessWidget {
  const _SecondaryActionChip({
    required this.label,
    required this.hint,
    required this.icon,
    required this.onTap,
    required this.width,
  });

  final String label;
  final String hint;
  final IconData icon;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              children: [
                Icon(icon, color: scheme.primary, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hint,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
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

String conversationInitial(String title) {
  final t = title.trim();
  if (t.isEmpty) return '?';
  return t.substring(0, 1).toUpperCase();
}
