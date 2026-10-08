import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/platform/platform_controller.dart';
import 'package:relaydesk_agent_console/src/platform/platform_models.dart';
import 'package:relaydesk_agent_console/src/ui/error_banner.dart';
import 'package:relaydesk_agent_console/src/util/format.dart';

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
                onPressed: busy ? null : () => _changePlan(context),
                child: const Text('调整套餐'),
              ),
              TextButton(
                onPressed: busy ? null : () => _extendTrial(context),
                child: const Text('延长试用'),
              ),
              if (tenant.isSuspended)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _setStatus(context, 'ACTIVE'),
                  child: const Text('恢复使用'),
                )
              else
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: busy ? null : () => _setStatus(context, 'SUSPENDED'),
                  child: const Text('停用'),
                ),
            ],
          ),
          child: Wrap(
            spacing: 24,
            runSpacing: 12,
            children: <Widget>[
              _Metric(label: '套餐', value: tenant.subscription.plan),
              _Metric(
                label: '计费状态',
                value: tenant.subscription.status,
                tone: tenant.subscription.status == 'ACTIVE'
                    ? null
                    : theme.colorScheme.error,
              ),
              _Metric(label: '状态', value: tenant.status),
              _Metric(
                label: '坐席上限',
                value: '${tenant.agents.where((a) => !a.isSystemAccount).length}'
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
          trailing: TextButton(
            onPressed: busy ? null : () => _resetOwner(context),
            child: const Text('重置管理员密码'),
          ),
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
                  subtitle: Text('${agent.email} · ${agent.role}'),
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
                  subtitle: Text('publicKey: ${inbox.publicKey}'),
                  trailing: TextButton(
                    onPressed: () =>
                        copyToClipboard(context, inbox.publicKey, 'publicKey'),
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
    final selection = await showDialog<_PlanChange>(
      context: context,
      builder: (context) => _PlanDialog(tenant: tenant),
    );
    if (selection == null || !context.mounted) {
      return;
    }
    final ok = await controller.updateTenant(
      plan: selection.plan,
      seatLimit: selection.seatLimit,
      monthlyMessageLimit: selection.messageLimit,
    );
    if (!context.mounted) {
      return;
    }
    _report(context, ok, '套餐已更新', '更新失败');
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
      (agent) => agent.role == 'OWNER',
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
        title: const Text('重置管理员密码'),
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
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(80),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
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
    final totalHandoff = ordered.fold<int>(0, (sum, day) => sum + day.aiHandoff);

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
                              heightFactor: day.total == 0
                                  ? 0.02
                                  : (day.total / peak).clamp(0.02, 1.0),
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary.withAlpha(140),
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

class _PlanChange {
  const _PlanChange({
    required this.plan,
    required this.seatLimit,
    required this.messageLimit,
  });

  final String plan;
  final int seatLimit;
  final int messageLimit;
}

/// The plan editor. Seat and message limits are pre-filled from the chosen
/// plan's defaults but stay editable, because a sales deal routinely means
/// "GROWTH, but 25 seats".
class _PlanDialog extends StatefulWidget {
  const _PlanDialog({required this.tenant});

  final TenantDetail tenant;

  @override
  State<_PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends State<_PlanDialog> {
  late String _plan = widget.tenant.subscription.plan.isEmpty
      ? 'TRIAL'
      : widget.tenant.subscription.plan;
  late final TextEditingController _seats = TextEditingController(
    text: '${widget.tenant.subscription.seatLimit}',
  );
  late final TextEditingController _messages = TextEditingController(
    text: '${widget.tenant.subscription.monthlyMessageLimit}',
  );

  @override
  void dispose() {
    _seats.dispose();
    _messages.dispose();
    super.dispose();
  }

  void _applyDefaults(String plan) {
    setState(() {
      _plan = plan;
      final limits = switch (plan) {
        'STARTER' => (3, 5000),
        'GROWTH' => (10, 50000),
        'ENTERPRISE' => (100, 1000000),
        _ => (2, 1000),
      };
      _seats.text = '${limits.$1}';
      _messages.text = '${limits.$2}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('调整套餐'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DropdownButtonFormField<String>(
              value: _plan,
              decoration: const InputDecoration(labelText: '套餐'),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem<String>(value: 'TRIAL', child: Text('TRIAL')),
                DropdownMenuItem<String>(
                  value: 'STARTER',
                  child: Text('STARTER'),
                ),
                DropdownMenuItem<String>(value: 'GROWTH', child: Text('GROWTH')),
                DropdownMenuItem<String>(
                  value: 'ENTERPRISE',
                  child: Text('ENTERPRISE'),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  _applyDefaults(value);
                }
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _seats,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '坐席上限',
                helperText: '留空或 0 表示按套餐默认值',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _messages,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '月消息上限',
                helperText: '留空或 0 表示按套餐默认值',
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _PlanChange(
              plan: _plan,
              seatLimit: int.tryParse(_seats.text.trim()) ?? 0,
              messageLimit: int.tryParse(_messages.text.trim()) ?? 0,
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
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
