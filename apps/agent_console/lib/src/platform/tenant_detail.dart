import '../ui/manual_quota_page.dart';
import 'package:tongyu_agent_console/src/platform/create_agent_dialog.dart';
import 'package:flutter/material.dart';

import 'package:tongyu_agent_console/src/platform/platform_controller.dart';
import 'package:tongyu_agent_console/src/platform/platform_models.dart';
import 'package:tongyu_agent_console/src/ui/error_banner.dart';
import 'package:tongyu_agent_console/src/util/format.dart';
import 'package:tongyu_agent_console/src/util/labels.dart';

/// The detail pane for one tenant: who is in it, what they bought, and what they
/// have used.
///
/// Every mutation on this screen goes through [PlatformController.updateTenant],
/// which re-reads the tenant afterwards. Plan limits are computed server-side
/// from the plan, so guessing the new seat limit locally would put a number on
/// screen that the server does not agree with.
class TenantDetailPane extends StatelessWidget {
  const TenantDetailPane({
    super.key,
    required this.controller,
    required this.tenant,
    required this.busy,
  });

  final PlatformController controller;
  final TenantDetail tenant;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    tenant.name,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${tenant.slug} · 创建于 ${fullTime(tenant.createdAt)}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            OutlinedButton.icon(
              onPressed: () => copyToClipboard(context, tenant.id, '租户 ID'),
              icon: const Icon(Icons.badge_outlined, size: 16),
              label: const Text('复制 ID'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _Section(
          title: '套餐与状态',
          trailing: Row(
            children: <Widget>[
              TextButton(
                onPressed: busy || !controller.isSuperAdmin
                    ? null
                    : () => _changePlan(context),
                child: const Text('分配套餐'),
              ),
              TextButton(
                onPressed: busy ||
                        !controller.isSuperAdmin ||
                        tenant.subscription.plan != 'TRIAL'
                    ? null
                    : () => _changePlan(context),
                child: const Text('延长试用'),
              ),
              if (tenant.isSuspended)
                TextButton(
                  onPressed: busy || !controller.isSuperAdmin
                      ? null
                      : () => _setStatus(context, 'ACTIVE'),
                  child: const Text('恢复使用'),
                )
              else
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: busy || !controller.isSuperAdmin
                      ? null
                      : () => _setStatus(context, 'SUSPENDED'),
                  child: const Text('停用'),
                ),
            ],
          ),
          child: Wrap(
            spacing: 24,
            runSpacing: 12,
            children: <Widget>[
              _Metric(label: '套餐', value: planLabel(tenant.subscription.plan)),
              _Metric(
                label: '计费状态',
                value: billingStatusLabel(tenant.subscription.status),
                tone: tenant.subscription.status == 'ACTIVE'
                    ? null
                    : theme.colorScheme.error,
              ),
              _Metric(label: '状态', value: tenantStatusLabel(tenant.status)),
              _Metric(
                label: '坐席上限',
                value:
                    '${tenant.agents.where((a) => !a.isSystemAccount).length}'
                    ' / ${tenant.subscription.seatLimit}',
              ),
              _Metric(
                label: '月消息上限',
                value: compactCount(tenant.subscription.monthlyMessageLimit),
              ),
              _Metric(
                label: '试用到期',
                value: tenant.subscription.trialEndsAt == null
                    ? '—'
                    : fullTime(tenant.subscription.trialEndsAt),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: '用量（近 ${tenant.usage.length} 天）',
          child: tenant.usage.isEmpty
              ? Text(
                  '暂无用量记录',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              : _UsageChart(days: tenant.usage),
        ),
        const SizedBox(height: 16),
        _Section(
          title: '坐席（${tenant.agents.where((a) => !a.isSystemAccount).length}）',
          trailing: Wrap(spacing: 8, children: [
            TextButton(
                onPressed: busy || !controller.isSuperAdmin
                    ? null
                    : () => _resetOwner(context),
                child: const Text('重置客服主管密码')),
            FilledButton.icon(
                onPressed: busy || !controller.isSuperAdmin
                    ? null
                    : () async {
                        final created = await showDialog<bool>(
                            context: context,
                            barrierDismissible: false,
                            builder: (_) => CreateAgentDialog(
                                controller: controller, tenantId: tenant.id));
                        if (created == true && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('账户已建立，请在企业后台分配客服入口。')));
                        }
                      },
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('建立账户')),
          ]),
          child: Column(
            children: <Widget>[
              for (final agent in tenant.agents)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 14,
                    backgroundColor: HSLColor.fromAHSL(
                      1,
                      avatarHue(agent.id).toDouble(),
                      0.3,
                      0.6,
                    ).toColor(),
                    child: Text(
                      initials(agent.displayName.isEmpty
                          ? agent.email
                          : agent.displayName),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  title: Text(
                    agent.displayName.isEmpty ? agent.email : agent.displayName,
                  ),
                  subtitle:
                      Text('${agent.email} · ${agentRoleLabel(agent.role)}'),
                  trailing: _StatusDot(
                    label: agent.status == 'DISABLED'
                        ? '停用'
                        : agent.isOnline
                            ? '在线'
                            : '离线',
                    online: agent.isOnline,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: '客服入口',
          child: Column(
            children: <Widget>[
              for (final inbox in tenant.inboxes)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.web_asset_outlined, size: 18),
                  title: Text(inbox.name),
                  subtitle: Text('入口公钥：${inbox.publicKey}'),
                  trailing: TextButton(
                    onPressed: () =>
                        copyToClipboard(context, inbox.publicKey, '入口公钥'),
                    child: const Text('复制'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _changePlan(BuildContext context) async {
    await assignTenantPlan(context, controller, tenant);
  }

  Future<void> _extendTrial(BuildContext context) async {
    final days = await showDialog<int>(
      context: context,
      builder: (context) => const _DaysDialog(),
    );
    if (days == null || !context.mounted) {
      return;
    }
    final ok = await controller.extendTrial(days);
    if (!context.mounted) {
      return;
    }
    _report(context, ok, '试用期已延长 $days 天', '延长失败');
  }

  Future<void> _setStatus(BuildContext context, String status) async {
    if (status == 'SUSPENDED') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('停用企业'),
          content: const Text(
            '停用会立即注销该企业全部坐席的登录状态，访客组件也会停止收发消息。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认停用'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) {
        return;
      }
    }
    final ok = await controller.updateTenant(status: status);
    if (!context.mounted) {
      return;
    }
    _report(
      context,
      ok,
      status == 'SUSPENDED' ? '已停用' : '已恢复使用',
      '操作失败',
    );
  }

  Future<void> _resetOwner(BuildContext context) async {
    final owner = tenant.agents.firstWhere(
      (agent) => agent.role == 'SUPERVISOR',
      orElse: () => tenant.agents.isEmpty
          ? const TenantAgent(
              id: '',
              email: '',
              displayName: '',
              role: '',
              status: '',
              presence: '',
            )
          : tenant.agents.first,
    );
    if (owner.email.isEmpty) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重置客服主管密码'),
        content: Text(
          '将为 ${owner.email} 生成新密码，并注销该账号的全部登录状态。'
          '旧密码立即失效，新密码只显示一次。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    final password = await controller.resetOwner(owner.email);
    if (!context.mounted) {
      return;
    }
    if (password == null) {
      _report(context, false, '', controller.error ?? '重置失败');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新密码已生成'),
        content: SelectableText(
          '$password\n\n请立即转告 ${owner.email}，此密码只显示这一次。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => copyToClipboard(context, password, '密码'),
            child: const Text('复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  void _report(BuildContext context, bool ok, String success, String failure) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? success : failure),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

/// A titled block with an optional action row.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: <Widget>[
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.tone});

  final String label;
  final String value;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value.isEmpty ? '—' : value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: tone,
          ),
        ),
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.label, required this.online});

  final String label;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = online ? const Color(0xFF2E7D32) : theme.colorScheme.outline;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// A 30-day bar chart of message volume with the AI share drawn on top.
///
/// Hand-drawn rather than a charting dependency: it is one stacked bar per day
/// and the console must build with the Flutter a developer already has, which
/// rules out pulling in a package for a hundred lines of painting.
class _UsageChart extends StatelessWidget {
  const _UsageChart({required this.days});

  final List<TenantUsageDay> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The server returns newest first; a chart reads left to right.
    final ordered = days.reversed.toList(growable: false);
    final peak = ordered.fold<int>(
      1,
      (max, day) => day.total > max ? day.total : max,
    );
    final totalIn = ordered.fold<int>(0, (sum, day) => sum + day.messagesIn);
    final totalOut = ordered.fold<int>(0, (sum, day) => sum + day.messagesOut);
    final totalAi = ordered.fold<int>(0, (sum, day) => sum + day.aiAnswered);
    final totalHandoff =
        ordered.fold<int>(0, (sum, day) => sum + day.aiHandoff);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          height: 96,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              for (final day in ordered)
                Expanded(
                  child: Tooltip(
                    message: '${day.date}\n'
                        '收到 ${day.messagesIn} · 发出 ${day.messagesOut}\n'
                        'AI 回答 ${day.aiAnswered} · 转人工 ${day.aiHandoff}',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
                          Expanded(
                            child: FractionallySizedBox(
                              widthFactor: ordered.length < 7 ? 0.08 : 0.7,
                              heightFactor: day.total == 0
                                  ? 0.02
                                  : (day.total / peak).clamp(0.02, 1.0),
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                decoration: BoxDecoration(
                                  color:
                                      theme.colorScheme.primary.withAlpha(140),
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 20,
          runSpacing: 6,
          children: <Widget>[
            _Metric(label: '收到消息', value: compactCount(totalIn)),
            _Metric(label: '发出消息', value: compactCount(totalOut)),
            _Metric(label: 'AI 回答', value: compactCount(totalAi)),
            _Metric(label: '转人工', value: compactCount(totalHandoff)),
            _Metric(
              label: 'AI 解决率',
              value: totalAi + totalHandoff == 0
                  ? '—'
                  : percentText(totalAi / (totalAi + totalHandoff)),
            ),
          ],
        ),
      ],
    );
  }
}

/// 保存成功后关闭；失败保留企业、套餐与自定义额度，允许重试。
Future<bool> assignTenantPlan(
    BuildContext context, PlatformController controller, TenantDetail tenant,
    {String? initialPlan}) async {
  final ok = await openQuotaEditor(context, controller, tenant.id,
      initialPlan: initialPlan);
  if (ok) {
    await controller.openTenant(tenant.id);
    await controller.refreshTenants();
    await controller.refreshOverview();
  }
  return ok;
}

class _DaysDialog extends StatefulWidget {
  const _DaysDialog();

  @override
  State<_DaysDialog> createState() => _DaysDialogState();
}

class _DaysDialogState extends State<_DaysDialog> {
  int _days = 14;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('延长试用期'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('在企业当前试用到期时间上顺延，最多 90 天。'),
          const SizedBox(height: 12),
          Slider(
            value: _days.toDouble(),
            min: 1,
            max: 90,
            divisions: 89,
            label: '$_days 天',
            onChanged: (value) => setState(() => _days = value.round()),
          ),
          Center(
            child: Text(
              '$_days 天',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_days),
          child: const Text('确认'),
        ),
      ],
    );
  }
}
