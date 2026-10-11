import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/platform/platform_controller.dart';
import 'package:relaydesk_agent_console/src/platform/tenant_detail.dart';
import 'package:relaydesk_agent_console/src/platform/tenant_table.dart';
import 'package:relaydesk_agent_console/src/ui/error_banner.dart';
import 'package:relaydesk_agent_console/src/util/format.dart';
import 'package:relaydesk_agent_console/src/util/labels.dart';

/// The RelayDesk operations console.
///
/// One shell with four sections rather than four windows: an operator moves
/// between "who is on the platform" and "is the AI working" constantly, and a
/// navigation rail keeps that one click instead of one window switch.
///
/// The tenant list is wide on purpose. A tenant table is scanned by name and
/// compared by number, and the numbers (seats, open conversations, plan) all
/// belong on the row so the operator does not have to open each one.
class PlatformPage extends StatefulWidget {
  const PlatformPage({
    super.key,
    required this.controller,
    required this.onAgentLogin,
  });

  final PlatformController controller;

  /// Signs the operator out and returns to the agent sign-in form.
  final VoidCallback onAgentLogin;

  @override
  State<PlatformPage> createState() => _PlatformPageState();
}

class _PlatformPageState extends State<PlatformPage> {
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: <Widget>[
                const Icon(Icons.admin_panel_settings_outlined, size: 20),
                const SizedBox(width: 10),
                const Text('连语客服运营后台'),
                if (controller.server.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 12),
                  Text(
                    controller.server,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ],
            ),
            actions: <Widget>[
              IconButton(
                tooltip: '刷新',
                onPressed: controller.busy ? null : _refreshCurrent,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: '退出运营后台',
                onPressed: _signOut,
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
          body: Column(
            children: <Widget>[
              if (controller.error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: ErrorBanner(
                    message: controller.error!,
                    onDismiss: controller.clearError,
                  ),
                ),
              Expanded(
                child: Row(
                  children: <Widget>[
                    NavigationRail(
                      selectedIndex: PlatformSection.values
                          .indexOf(controller.section),
                      onDestinationSelected: (index) =>
                          controller.selectSection(PlatformSection.values[index]),
                      labelType: NavigationRailLabelType.all,
                      destinations: const <NavigationRailDestination>[
                        NavigationRailDestination(
                          icon: Icon(Icons.dashboard_outlined),
                          selectedIcon: Icon(Icons.dashboard),
                          label: Text('总览'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.apartment_outlined),
                          selectedIcon: Icon(Icons.apartment),
                          label: Text('企业'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.auto_awesome_outlined),
                          selectedIcon: Icon(Icons.auto_awesome),
                          label: Text('AI'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.info_outline),
                          selectedIcon: Icon(Icons.info),
                          label: Text('关于'),
                        ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _section(context)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _refreshCurrent() async {
    switch (widget.controller.section) {
      case PlatformSection.overview:
        await widget.controller.refreshOverview();
      case PlatformSection.tenants:
        await widget.controller.refreshTenants();
      case PlatformSection.ai:
        await widget.controller.refreshAiUsage();
      case PlatformSection.about:
        await widget.controller.refreshMeta();
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出运营后台'),
        content: const Text('退出后需要重新输入平台管理令牌才能进入。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await widget.controller.signOut();
    widget.onAgentLogin();
  }

  Widget _section(BuildContext context) {
    switch (widget.controller.section) {
      case PlatformSection.overview:
        return _OverviewSection(controller: widget.controller);
      case PlatformSection.tenants:
        return _TenantsSection(controller: widget.controller);
      case PlatformSection.ai:
        return _AiSection(controller: widget.controller);
      case PlatformSection.about:
        return _AboutSection(controller: widget.controller);
    }
  }
}

/// The headline numbers, plus plan mix and the busiest tenants.
class _OverviewSection extends StatelessWidget {
  const _OverviewSection({required this.controller});

  final PlatformController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overview = controller.overview;
    if (overview == null) {
      return Center(
        child: controller.busy
            ? const CircularProgressIndicator(strokeWidth: 2)
            : const Text('暂无数据'),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      children: <Widget>[
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            _StatCard(label: '企业总数', value: '${overview.tenants}'),
            _StatCard(
              label: '正常使用',
              value: '${overview.activeTenants}',
              tone: const Color(0xFF2E7D32),
            ),
            _StatCard(
              label: '已停用',
              value: '${overview.suspendedTenants}',
              tone: overview.suspendedTenants > 0
                  ? theme.colorScheme.error
                  : null,
            ),
            _StatCard(label: '坐席总数', value: '${overview.agents}'),
            _StatCard(label: '会话总数', value: '${overview.conversations}'),
            _StatCard(
              label: '待处理会话',
              value: '${overview.openConversations}',
            ),
            _StatCard(
              label: '今日消息',
              value: compactCount(overview.messagesToday),
            ),
            _StatCard(
              label: '实时连接',
              value: '${overview.realtimeConnections}',
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: _Panel(
                title: '套餐分布',
                child: overview.planDistribution.isEmpty
                    ? const Text('暂无数据')
                    : Column(
                        children: <Widget>[
                          for (final plan in overview.planDistribution)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: <Widget>[
                                  SizedBox(
                                    width: 96,
                                    child: Text(
                                       planLabel(plan.plan),
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                  ),
                                  Expanded(
                                    child: LinearProgressIndicator(
                                      minHeight: 6,
                                      value: overview.tenants == 0
                                          ? 0
                                          : plan.tenants / overview.tenants,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  SizedBox(
                                    width: 40,
                                    child: Text(
                                      '${plan.tenants}',
                                      textAlign: TextAlign.right,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _Panel(
                title: '活跃企业（近 7 天会话）',
                child: overview.topTenants.isEmpty
                    ? const Text('暂无数据')
                    : Column(
                        children: <Widget>[
                          for (final tenant in overview.topTenants)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                tenant.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${tenant.slug} · ${tenant.agents} 坐席',
                                style: theme.textTheme.labelSmall,
                              ),
                              trailing: Text(
                                '${tenant.conversations7d}',
                                style: theme.textTheme.titleSmall,
                              ),
                              onTap: () {
                                controller.selectSection(PlatformSection.tenants);
                                controller.openTenant(tenant.tenantId);
                              },
                            ),
                        ],
                      ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _Panel(
          title: '实例',
          child: Wrap(
            spacing: 24,
            runSpacing: 8,
            children: <Widget>[
              _Metric(label: '实例 ID', value: overview.instance),
              _Metric(label: 'AI 提供方', value: overview.aiProvider),
              _Metric(
                label: '服务器时间',
                value: fullTime(overview.serverTime),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The tenant list plus whichever detail is open.
class _TenantsSection extends StatelessWidget {
  const _TenantsSection({required this.controller});

  final PlatformController controller;

  @override
  Widget build(BuildContext context) {
    final detail = controller.detail;
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    final list = TenantTable(
      tenants: controller.tenants,
      query: controller.tenantQuery,
      onQueryChanged: controller.searchTenants,
      selectedId: detail?.id ?? '',
      onOpen: (tenant) => controller.openTenant(tenant.id),
      onRefresh: controller.refreshTenants,
    );

    final listPane = Column(
      children: <Widget>[
        Expanded(child: list),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '开通新企业会同时创建管理员账号、客服入口与分配规则。',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              FilledButton.icon(
                onPressed: controller.busy ? null : () => _create(context),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('开通企业'),
              ),
            ],
          ),
        ),
      ],
    );

    // Below this width a side-by-side split leaves the detail too narrow to read,
    // so the detail takes over the section instead of sitting beside the list.
    if (!wide && detail != null) {
      return Column(
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 0, 0),
              child: TextButton.icon(
                onPressed: controller.closeTenant,
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('返回企业列表'),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: TenantDetailPane(
              controller: controller,
              tenant: detail,
              busy: controller.busy,
            ),
          ),
        ],
      );
    }

    if (wide) {
      return Row(
        children: <Widget>[
          SizedBox(width: 460, child: listPane),
          const VerticalDivider(width: 1),
          Expanded(
            child: detail == null
                ? const _EmptyDetail()
                : TenantDetailPane(
                    controller: controller,
                    tenant: detail,
                    busy: controller.busy,
                  ),
          ),
        ],
      );
    }
    return listPane;
  }

  Future<void> _create(BuildContext context) async {
    final request = await showDialog<CreateTenantRequest>(
      context: context,
      builder: (context) => const CreateTenantDialog(),
    );
    if (request == null || !context.mounted) {
      return;
    }
    final created = await controller.createTenant(
      name: request.name,
      slug: request.slug,
      ownerEmail: request.ownerEmail,
      ownerName: request.ownerName,
      ownerPassword: request.ownerPassword,
      inboxName: request.inboxName,
      publicKey: request.publicKey,
      plan: request.plan,
      trialDays: request.trialDays,
    );
    if (!context.mounted) {
      return;
    }
    if (created == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controller.error ?? '开通失败')),
      );
      return;
    }
    await showCreatedTenant(context, created);
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.apartment_outlined,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            '从左侧选择一家企业查看详情',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Platform-wide AI deflection.
class _AiSection extends StatelessWidget {
  const _AiSection({required this.controller});

  final PlatformController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usage = controller.aiUsage;
    if (usage == null) {
      return Center(
        child: controller.busy
            ? const CircularProgressIndicator(strokeWidth: 2)
            : const Text('暂无数据'),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '近 ${usage.days} 天 AI 表现',
              style: theme.textTheme.titleMedium,
            ),
            const Spacer(),
            DropdownButton<int>(
              value: usage.days,
              underline: const SizedBox.shrink(),
              items: const <DropdownMenuItem<int>>[
                DropdownMenuItem<int>(value: 7, child: Text('近 7 天')),
                DropdownMenuItem<int>(value: 14, child: Text('近 14 天')),
                DropdownMenuItem<int>(value: 30, child: Text('近 30 天')),
                DropdownMenuItem<int>(value: 90, child: Text('近 90 天')),
              ],
              onChanged: (value) {
                if (value != null) {
                  controller.refreshAiUsage(days: value);
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (!usage.available)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '当前实例没有配置模型提供方，AI 自动回复处于关闭状态，'
                      '下面的计数全部为零。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            _StatCard(label: '总调用', value: '${usage.interactions}'),
            _StatCard(label: 'AI 回答', value: '${usage.answered}'),
            _StatCard(
              label: 'AI 解决率',
              value: percentText(usage.deflectionRate),
              tone: const Color(0xFF2E7D32),
            ),
            _StatCard(label: '统计窗口', value: '${usage.days} 天'),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: _Panel(
                title: '按提供方',
                child: usage.providers.isEmpty
                    ? const Text('窗口内没有 AI 调用')
                    : Column(
                        children: <Widget>[
                          for (final provider in usage.providers)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: <Widget>[
                                  SizedBox(
                                    width: 120,
                                    child: Text(
                                      provider.provider,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                  ),
                                  Expanded(
                                    child: LinearProgressIndicator(
                                      minHeight: 6,
                                      value: provider.deflectionRate.clamp(0, 1),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  SizedBox(
                                    width: 64,
                                    child: Text(
                                      percentText(provider.deflectionRate),
                                      textAlign: TextAlign.right,
                                      style: theme.textTheme.labelMedium,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 12),
                          for (final provider in usage.providers)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Text(
                                      '${provider.provider} · 调用 ${provider.interactions} · '
                                      '平均 ${provider.avgLatencyMs}ms · '
                                      '平均覆盖率 ${provider.avgScore.toStringAsFixed(2)}',
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _Panel(
                title: '交接原因',
                child: usage.reasons.isEmpty
                    ? const Text('窗口内没有 AI 调用')
                    : Column(
                        children: <Widget>[
                          for (final entry in _sortedReasons(usage.reasons))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: <Widget>[
                                  SizedBox(
                                    width: 160,
                                    child: Text(
                                      _reasonLabel(entry.key),
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                  ),
                                  Expanded(
                                    child: LinearProgressIndicator(
                                      minHeight: 6,
                                      value: usage.interactions == 0
                                          ? 0
                                          : entry.value / usage.interactions,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  SizedBox(
                                    width: 48,
                                    child: Text(
                                      '${entry.value}',
                                      textAlign: TextAlign.right,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Biggest first, so the reason that is actually hurting is at the top.
  static List<MapEntry<String, int>> _sortedReasons(Map<String, int> reasons) {
    final entries = reasons.entries.toList(growable: false)
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }

  /// The server's handoff reasons, spelled out. A reason with no translation is
  /// shown as-is: inventing a friendly name for an unknown code would hide a
  /// server change rather than surface it.
  static String _reasonLabel(String reason) => switch (reason) {
        'ANSWERED' => 'AI 已解决',
        'LOW_CONFIDENCE' => '覆盖率不足',
        'NO_KNOWLEDGE' => '知识库无命中',
        'AI_DISABLED' => 'AI 未开启',
        'RATE_LIMITED' => '触发限流',
        'PROVIDER_ERROR' => '模型调用失败',
        'HANDOFF_REQUESTED' => '访客要求转人工',
        'INJECTION_BLOCKED' => '指令注入已拦截',
        'AGENT_ACTIVE' => '人工已接管',
        _ => reason,
      };
}

/// What the instance says about itself. Kept deliberately short: it exists so an
/// operator can confirm which build and which AI provider a server is running
/// before filing a bug, not to be a control panel.
class _AboutSection extends StatelessWidget {
  const _AboutSection({required this.controller});

  final PlatformController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = controller.meta;
    if (meta == null) {
      return Center(
        child: controller.busy
            ? const CircularProgressIndicator(strokeWidth: 2)
            : const Text('暂无数据'),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      children: <Widget>[
        _Panel(
          title: meta.product,
          child: Wrap(
            spacing: 32,
            runSpacing: 14,
            children: <Widget>[
              _Metric(label: '服务端版本', value: meta.version),
              _Metric(label: '模型', value: meta.model),
              _Metric(
                label: 'AI 提供方',
                value: meta.aiAvailable ? meta.aiProvider : '未配置',
              ),
              _Metric(label: '存储', value: meta.storage),
              _Metric(label: '单文件上限', value: '${meta.uploadMaxMB} MB'),
              _Metric(label: 'Webhook 重试', value: '${meta.webhookAttempts} 次'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Panel(
          title: '平台能力',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final feature in meta.platformFeatures)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(
                    '· $feature',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Panel(
          title: '当前连接',
          child: Wrap(
            spacing: 32,
            runSpacing: 14,
            children: <Widget>[
              _Metric(label: '服务器', value: controller.server),
              const _Metric(
                label: '会话有效期',
                value: '24 小时，到期后需重新输入令牌',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A big number with a caption.
class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, this.tone});

  final String label;
  final String value;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 148,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.dividerColor.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: tone,
            ),
          ),
        ],
      ),
    );
  }
}

/// A bordered block with a title.
class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(60),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

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
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }
}
