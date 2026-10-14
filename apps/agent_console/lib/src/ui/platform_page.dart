import 'manual_quota_page.dart';
import 'platform_plans_page.dart';
import 'package:relaydesk_agent_console/src/ui/product_brand.dart';
import 'package:relaydesk_agent_console/src/ui/brand.dart';
import 'package:flutter/material.dart';
import 'package:relaydesk_agent_console/src/api/api_exception.dart';
import 'package:relaydesk_agent_console/src/platform/platform_models.dart';
import 'package:relaydesk_agent_console/src/ui/workspace_layout.dart';
import 'package:relaydesk_agent_console/src/ui/platform_account_page.dart';

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
  static const _nav = [
    PlatformSection.overview,
    PlatformSection.tenants,
    PlatformSection.plans,
    PlatformSection.history,
    PlatformSection.about
  ];
  int _navIndex(PlatformSection section) {
    final i = _nav.indexOf(section);
    return i < 0 ? 4 : i;
  }

  static const _sectionTitles = <PlatformSection, String>{
    PlatformSection.overview: '平台概览',
    PlatformSection.tenants: '企业与账号',
    PlatformSection.plans: '套餐与额度',
    PlatformSection.ai: '智能服务',
    PlatformSection.about: '平台设置',
    PlatformSection.account: '账号安全',
    PlatformSection.history: '操作记录',
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final wide = MediaQuery.sizeOf(context).width >= 700;
        return Scaffold(
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _navIndex(controller.section),
                  onDestinationSelected: (index) =>
                      controller.selectSection(_nav[index]),
                  destinations: const [
                    NavigationDestination(
                        icon: Icon(Icons.dashboard_outlined), label: '概览'),
                    NavigationDestination(
                        icon: Icon(Icons.apartment_outlined), label: '企业'),
                    NavigationDestination(
                        icon: Icon(Icons.workspace_premium_outlined),
                        label: '额度'),
                    NavigationDestination(
                        icon: Icon(Icons.receipt_long_outlined), label: '记录'),
                    NavigationDestination(
                        icon: Icon(Icons.settings_outlined), label: '设置'),
                  ],
                ),
          body: Column(
            children: <Widget>[
              if (controller.error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: ErrorBanner(
                    message: controller.error!,
                    onDismiss: controller.clearError,
                  ),
                ),
              Expanded(
                child: Row(
                  children: <Widget>[
                    if (wide)
                      Theme(
                          data: Theme.of(context).copyWith(
                              colorScheme: Theme.of(context)
                                  .colorScheme
                                  .copyWith(
                                      brightness: Brightness.dark,
                                      surface: const Color(0xFF182334),
                                      onSurface: Colors.white,
                                      onSurfaceVariant: const Color(0xFF9CAAC0),
                                      primary: const Color(0xFF9AABFF),
                                      primaryContainer: const Color(0xFF314CB0),
                                      onPrimaryContainer: Colors.white,
                                      outlineVariant: const Color(0xFF324158))),
                          child: WorkspaceSidebar(
                            subtitle: controller.isSuperAdmin
                                ? '超级管理员 · 手动额度管理'
                                : '平台管理员 · 仅可查看',
                            selectedIndex: _navIndex(controller.section),
                            onSelected: (index) =>
                                controller.selectSection(_nav[index]),
                            items: const [
                              WorkspaceNavItem(
                                  '平台概览', Icons.dashboard_outlined),
                              WorkspaceNavItem(
                                  '企业与账号', Icons.apartment_outlined),
                              WorkspaceNavItem(
                                  '套餐与额度', Icons.workspace_premium_outlined),
                              WorkspaceNavItem(
                                  '操作记录', Icons.receipt_long_outlined),
                              WorkspaceNavItem('平台设置', Icons.settings_outlined),
                            ],
                            footer: _PlatformSessionFooter(
                              server: controller.server,
                              onRefresh:
                                  controller.busy ? null : _refreshCurrent,
                              onSignOut: _signOut,
                              onAgentLogin: widget.onAgentLogin,
                            ),
                          )),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(wide ? 10 : 0, 10, 10, 10),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            borderRadius: BorderRadius.circular(0),
                            border: Border.all(
                              color:
                                  Theme.of(context).colorScheme.outlineVariant,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: Column(
                              children: [
                                _PlatformTopBar(
                                  title: _sectionTitles[controller.section] ??
                                      '平台管理后台',
                                  server: controller.server,
                                  showBrand: !wide,
                                  busy: controller.busy,
                                  onRefresh: _refreshCurrent,
                                  onCreateTenant: controller.isSuperAdmin
                                      ? () => _TenantsSection(
                                              controller: controller)
                                          ._create(context)
                                      : null,
                                  onSignOut: wide ? null : _signOut,
                                ),
                                Expanded(child: _section(context)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
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
      case PlatformSection.account:
      case PlatformSection.history:
      case PlatformSection.plans:
        return;
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
        content: const Text('退出后将返回平台登录页，需重新输入密码才能进入。'),
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
    // 只清会话；根路由看到 locked 后留在平台登录页，不跳去客服登录。
    await widget.controller.signOut();
  }

  Widget _section(BuildContext context) {
    switch (widget.controller.section) {
      case PlatformSection.history:
        return ManualQuotaPage(
            key: const ValueKey("history"),
            controller: widget.controller,
            history: true);
      case PlatformSection.account:
        return _PlatformSettings(controller: widget.controller, index: 2);
      case PlatformSection.overview:
        return ManualQuotaPage(
            key: const ValueKey('overview'),
            controller: widget.controller,
            overview: true);
      case PlatformSection.tenants:
        return _TenantsSection(controller: widget.controller);
      case PlatformSection.plans:
        return Column(children: [
          Padding(padding: const EdgeInsets.all(12), child: Align(alignment: Alignment.centerRight, child: OutlinedButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: const Text('套餐详情与年费')), body: PlatformPlansPage(controller: widget.controller)))), child: const Text('套餐详情与年费')))),
          Expanded(child: ManualQuotaPage(key: const ValueKey('quotas'), controller: widget.controller)),
        ]);
      case PlatformSection.ai:
        return _PlatformSettings(controller: widget.controller, index: 1);
      case PlatformSection.about:
        return _PlatformSettings(controller: widget.controller);
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
        const WorkspaceHeading('工作概览', '查看企业服务、会话负载与平台运行情况'),
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
        WorkspacePair(
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
                                controller
                                    .selectSection(PlatformSection.tenants);
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
          title: '待处理企业（当前已加载列表）',
          child: controller.tenants
                  .where((tenant) => tenant.openConversations > 0)
                  .isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text('暂无待处理企业'))
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(columns: const [
                    DataColumn(label: Text('企业名称')),
                    DataColumn(label: Text('待处理会话'), numeric: true),
                    DataColumn(label: Text('开通时间')),
                    DataColumn(label: Text('套餐')),
                    DataColumn(label: Text('状态')),
                    DataColumn(label: Text('操作')),
                  ], rows: [
                    for (final tenant in controller.tenants
                        .where((tenant) => tenant.openConversations > 0))
                      DataRow(cells: [
                        DataCell(Text(tenant.name)),
                        DataCell(Text('${tenant.openConversations}')),
                        DataCell(Text(fullTime(tenant.createdAt))),
                        DataCell(Text(planLabel(tenant.plan))),
                        DataCell(Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                                color: tenant.isSuspended
                                    ? const Color(0xFFFFF2E5)
                                    : const Color(0xFFE8F8ED),
                                borderRadius: BorderRadius.circular(6)),
                            child: Text(tenantStatusLabel(tenant.status),
                                style: TextStyle(
                                    fontSize: 12,
                                    color: tenant.isSuspended
                                        ? const Color(0xFFFF7D00)
                                        : const Color(0xFF00B42A))))),
                        DataCell(TextButton(
                            onPressed: () {
                              controller.selectSection(PlatformSection.tenants);
                              controller.openTenant(tenant.id);
                            },
                            child: const Text('查看'))),
                      ]),
                  ])),
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
      onAssignPlan:
          controller.busy ? null : (tenant) => _assignPlan(context, tenant.id),
      onLoadMore: controller.hasMoreTenants ? controller.loadMoreTenants : null,
    );

    final listPane = Column(
      children: <Widget>[
        if (controller.assignmentPlan != null)
          Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Expanded(
                    child: Text(
                        '已选择${planLabel(controller.assignmentPlan!)}，请为目标企业点击「分配套餐」。')),
                TextButton(
                    onPressed: controller.clearPlanAssignment,
                    child: const Text('取消')),
              ])),
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
                onPressed: controller.busy || !controller.isSuperAdmin
                    ? null
                    : () => _create(context),
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

  Future<void> _assignPlan(BuildContext context, String id) async {
    final plan = controller.assignmentPlan;
    await controller.openTenant(id);
    if (!context.mounted) return;
    final tenant = controller.detail;
    if (tenant == null || tenant.id != id) return;
    final ok =
        await assignTenantPlan(context, controller, tenant, initialPlan: plan);
    if (ok) controller.clearPlanAssignment();
  }

  Future<void> _create(BuildContext context) async {
    final created = await showDialog<CreatedTenant>(
      context: context,
      barrierDismissible: false,
      builder: (context) => CreateTenantDialog(onSubmit: (request) async {
        final result = await controller.createTenant(
            inlineFailure: true,
            name: request.name,
            slug: request.slug,
            ownerEmail: request.ownerEmail,
            ownerName: request.ownerName,
            ownerPassword: request.ownerPassword,
            inboxName: request.inboxName,
            publicKey: request.publicKey,
            plan: request.plan,
            trialDays: request.trialDays);
        if (result == null) {
          throw ApiException(
              statusCode: 400,
              code: 'CREATE_FAILED',
              message: controller.error ?? '开通失败，请重试');
        }
        return result;
      }),
    );
    if (created == null || !context.mounted) return;
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
        const WorkspaceHeading('AI 使用情况', '按时间范围了解模型调用、解决率与转人工原因'),
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
        WorkspacePair(
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
                                      value:
                                          provider.deflectionRate.clamp(0, 1),
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
                                      style:
                                          theme.textTheme.labelSmall?.copyWith(
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
        const WorkspaceHeading('平台设置', '查看当前实例配置与服务能力'),
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
                value: '8 小时；退出或修改密码后立即失效',
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
    final icon =
        label.contains('企业') || label.contains('使用') || label.contains('停用')
            ? Icons.business_outlined
            : label.contains('坐席')
                ? Icons.people_outline
                : label.contains('连接')
                    ? Icons.wifi
                    : label.contains('AI')
                        ? Icons.auto_awesome_outlined
                        : Icons.chat_bubble_outline;
    return SizedBox(
      width: MediaQuery.sizeOf(context).width < 600 ? 280 : 236,
      child:
          WorkspaceKpiCard(label: label, value: value, icon: icon, tone: tone),
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
        color: theme.colorScheme.surface,
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

/// 侧栏底部会话区：刷新、切客服门面、退出（退出后留在平台登录页）。
class _PlatformSessionFooter extends StatelessWidget {
  const _PlatformSessionFooter({
    required this.server,
    required this.onSignOut,
    required this.onAgentLogin,
    this.onRefresh,
  });

  final String server;
  final VoidCallback? onRefresh;
  final VoidCallback onSignOut;
  final VoidCallback onAgentLogin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (server.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              server,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        TextButton.icon(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('刷新当前页'),
        ),
        TextButton(
          onPressed: onAgentLogin,
          child: const Text('切换到客服登录'),
        ),
        FilledButton.tonal(
          onPressed: onSignOut,
          child: const Text('退出登录'),
        ),
      ],
    );
  }
}

class _PlatformTopBar extends StatelessWidget {
  const _PlatformTopBar({
    required this.title,
    required this.server,
    required this.showBrand,
    required this.busy,
    required this.onRefresh,
    required this.onCreateTenant,
    this.onSignOut,
  });

  final String title;
  final String server;
  final bool showBrand;
  final bool busy;
  final VoidCallback onRefresh;
  final VoidCallback? onCreateTenant;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: theme.colorScheme.surface,
      child: Row(
        children: [
          if (showBrand) ...[
            const LiaoQiaoBrand(compact: true),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  ProductBrand.platformTitle,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: busy ? null : onRefresh,
            icon: const Icon(Icons.refresh),
          ),
          FilledButton.icon(
            onPressed: busy ? null : onCreateTenant,
            icon: const Icon(Icons.add, size: 18),
            label: Text(
              MediaQuery.sizeOf(context).width < 900 ? '开通' : '开通企业',
            ),
          ),
          if (onSignOut != null)
            IconButton(
              tooltip: '退出登录',
              onPressed: onSignOut,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
    );
  }
}

class _PlatformSettings extends StatelessWidget {
  const _PlatformSettings({required this.controller, this.index = 0});
  final PlatformController controller;
  final int index;
  @override
  Widget build(BuildContext context) => DefaultTabController(
      length: 3,
      initialIndex: index,
      child: Column(children: [
        const TabBar(
            tabs: [Tab(text: '服务配置'), Tab(text: '智能服务'), Tab(text: '账号安全')]),
        Expanded(
            child: TabBarView(children: [
          _AboutSection(controller: controller),
          _AiSection(controller: controller),
          PlatformAccountPage(controller: controller)
        ]))
      ]));
}

