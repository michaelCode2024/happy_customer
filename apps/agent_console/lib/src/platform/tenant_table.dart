import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/api/api_exception.dart';
import 'package:tongyu_agent_console/src/ui/console_form_dialog.dart';

import 'package:tongyu_agent_console/src/platform/platform_models.dart';
import 'package:tongyu_agent_console/src/ui/error_banner.dart';
import 'package:tongyu_agent_console/src/util/format.dart';
import 'package:tongyu_agent_console/src/util/labels.dart';

/// The tenant table.
///
/// Same split as the agent console's conversation list: the list widget renders
/// what it is given and reports taps, while the controller owns the data. That
/// keeps a 500-tenant table cheap to rebuild and keeps every server call in one
/// place.
///
/// The widget is stateful only because of the search field: the field keeps its
/// own [TextEditingController] so typing keeps its cursor and focus, and it
/// adopts an externally changed query (a cleared search) without fighting the
/// person typing into it.
class TenantTable extends StatefulWidget {
  const TenantTable({
    super.key,
    required this.tenants,
    required this.query,
    required this.onQueryChanged,
    required this.onOpen,
    required this.selectedId,
    required this.onRefresh,
    this.onLoadMore,
    this.onAssignPlan,
  });

  final List<TenantSummary> tenants;
  final String query;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<TenantSummary> onOpen;
  final String selectedId;
  final Future<void> Function() onRefresh;
  final VoidCallback? onLoadMore;
  final ValueChanged<TenantSummary>? onAssignPlan;

  @override
  State<TenantTable> createState() => _TenantTableState();
}

class _TenantTableState extends State<TenantTable> {
  String _status = 'ALL';
  late final TextEditingController _query =
      TextEditingController(text: widget.query);

  @override
  void didUpdateWidget(TenantTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != _query.text) {
      _query.text = widget.query;
      _query.selection = TextSelection.collapsed(offset: widget.query.length);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tenants = widget.tenants
        .where((t) => _status == 'ALL' || t.status == _status)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text('企业与账号',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700))),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(spacing: 8, children: [
              for (final status in {
                'ALL': '全部',
                'ACTIVE': '正常使用',
                'SUSPENDED': '已停用'
              }.entries)
                ChoiceChip(
                    label: Text(status.value),
                    selected: _status == status.key,
                    onSelected: (_) => setState(() => _status = status.key))
            ])),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _query,
                  onChanged: widget.onQueryChanged,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: '搜索企业名称或标识',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '刷新',
                onPressed: widget.onRefresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              Text(
                '当前显示 ${tenants.length} 家企业',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              Text(
                '按创建时间倒序',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: tenants.isEmpty
              ? Center(
                  child: Text(
                    widget.query.isEmpty ? '还没有企业' : '没有匹配「${widget.query}」的企业',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: tenants.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (context, index) {
                    final tenant = tenants[index];
                    return _TenantRow(
                      tenant: tenant,
                      selected: tenant.id == widget.selectedId,
                      onTap: () => widget.onOpen(tenant),
                      onAssignPlan: widget.onAssignPlan == null
                          ? null
                          : () => widget.onAssignPlan!(tenant),
                    );
                  },
                ),
        ),
        if (widget.onLoadMore != null)
          TextButton(onPressed: widget.onLoadMore, child: const Text('加载更多企业')),
      ],
    );
  }
}

class _TenantRow extends StatelessWidget {
  const _TenantRow({
    required this.tenant,
    required this.selected,
    required this.onTap,
    this.onAssignPlan,
  });

  final TenantSummary tenant;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onAssignPlan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected
            ? theme.colorScheme.primary.withAlpha(24)
            : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          children: <Widget>[
            CircleAvatar(
              radius: 16,
              backgroundColor: HSLColor.fromAHSL(
                1,
                avatarHue(tenant.id).toDouble(),
                0.35,
                0.55,
              ).toColor(),
              child: Text(
                initials(tenant.name),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          tenant.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (tenant.isSuspended)
                        _Chip(
                          label: '已停用',
                          color: theme.colorScheme.error,
                        )
                      else
                        _Chip(
                          label: planLabel(tenant.plan),
                          color: theme.colorScheme.primary,
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${tenant.slug} · ${tenant.agents}/${tenant.seatLimit} 坐席 · '
                    '${tenant.openConversations} 个待处理会话',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  '${tenant.conversations}',
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  '会话',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (onAssignPlan != null)
              TextButton(
                  onPressed: onAssignPlan,
                  child: const Text('分配套餐', style: TextStyle(fontSize: 12))),
            const SizedBox(width: 10),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// A small coloured label. Deliberately not [Chip]: a Material chip carries
/// padding and touch targets sized for filtering, and these are read-only.
class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style:
            TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// The provisioning form.
///
/// Only the fields that must be decided by a human are on it: everything else
/// (inbox name, public key, slug, welcome message, routing rule, AI settings)
/// has a sensible server-side default, and a form that asks for all of them is a
/// form an operator gets wrong at 2am.
class CreateTenantDialog extends StatefulWidget {
  const CreateTenantDialog({super.key, required this.onSubmit});
  final Future<CreatedTenant> Function(CreateTenantRequest) onSubmit;

  @override
  State<CreateTenantDialog> createState() => _CreateTenantDialogState();
}

/// 表单请求与服务调用解耦；只有服务器确认成功后才关闭弹窗。
class CreateTenantRequest {
  const CreateTenantRequest({
    required this.name,
    required this.slug,
    required this.ownerEmail,
    required this.ownerName,
    required this.ownerPassword,
    required this.inboxName,
    required this.publicKey,
    required this.plan,
    required this.trialDays,
  });

  final String name;
  final String slug;
  final String ownerEmail;
  final String ownerName;
  final String ownerPassword;
  final String inboxName;
  final String publicKey;
  final String plan;
  final int trialDays;
}

class _CreateTenantDialogState extends State<CreateTenantDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _slug = TextEditingController(),
      _ownerEmail = TextEditingController(),
      _ownerName = TextEditingController(),
      _ownerPassword = TextEditingController(),
      _inboxName = TextEditingController(),
      _publicKey = TextEditingController();
  String _plan = 'TRIAL';
  bool _saving = false, _showPassword = false;
  String? _error;
  @override
  void dispose() {
    for (final controller in [
      _name,
      _slug,
      _ownerEmail,
      _ownerName,
      _ownerPassword,
      _inboxName,
      _publicKey
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final created = await widget.onSubmit(CreateTenantRequest(
          name: _name.text.trim(),
          slug: _slug.text.trim(),
          ownerEmail: _ownerEmail.text.trim(),
          ownerName: _ownerName.text.trim(),
          ownerPassword: _ownerPassword.text,
          inboxName: _inboxName.text.trim(),
          publicKey: _publicKey.text.trim(),
          plan: _plan,
          trialDays: _plan == 'TRIAL' ? 14 : 0));
      if (mounted) Navigator.pop(context, created);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '提交失败，请检查连接后重试。已填写的信息已保留。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ConsoleFormDialog(
      title: '开通企业',
      description: '为企业建立独立工作空间，并创建首位客服主管账号。',
      icon: Icons.business_outlined,
      submitLabel: '开通企业',
      busy: _saving,
      error: _error,
      onSubmit: _submit,
      child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ConsoleFormSection('企业资料',
                child: ConsoleFormGrid(children: [
                  ConsoleField('企业名称',
                      required: true,
                      child: TextFormField(
                          controller: _name,
                          autofocus: true,
                          decoration:
                              const InputDecoration(hintText: '例如：桥望科技'),
                          validator: (v) =>
                              (v ?? '').trim().isEmpty ? '请填写企业名称' : null)),
                  ConsoleField('企业标识',
                      child: TextFormField(
                          controller: _slug,
                          autocorrect: false,
                          decoration:
                              const InputDecoration(hintText: '选填，留空自动生成'))),
                ])),
            const SizedBox(height: 28),
            ConsoleFormSection('客服主管账户',
                child: ConsoleFormGrid(children: [
                  ConsoleField('客服主管姓名',
                      child: TextFormField(
                          controller: _ownerName,
                          decoration:
                              const InputDecoration(hintText: '选填，默认客服主管'))),
                  ConsoleField('客服主管用户名',
                      required: true,
                      child: TextFormField(
                          controller: _ownerEmail,
                          autocorrect: false,
                          keyboardType: TextInputType.text,
                          decoration: const InputDecoration(
                              hintText: '例如：admin 或 kefu01'),
                          validator: (v) =>
                              (v ?? '').trim().isNotEmpty ? null : '请输入有效用户名')),
                ])),
            const SizedBox(height: 20),
            ConsoleField('初始密码',
                child: TextFormField(
                    controller: _ownerPassword,
                    obscureText: !_showPassword,
                    decoration: InputDecoration(
                        hintText: '选填，留空自动生成',
                        helperText: '自动生成的密码仅在创建成功后显示一次。',
                        suffixIcon: IconButton(
                            tooltip: _showPassword ? '隐藏密码' : '显示密码',
                            onPressed: () =>
                                setState(() => _showPassword = !_showPassword),
                            icon: Icon(
                                _showPassword
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                size: 18))),
                    validator: (v) => (v ?? '').isNotEmpty && v!.length < 8
                        ? '密码至少 8 位'
                        : null)),
            const SizedBox(height: 28),
            ConsoleFormSection('服务配置',
                child: ConsoleField('套餐',
                    child: DropdownButtonFormField<String>(
                        isExpanded: true,
                        value: _plan,
                        items: const [
                          DropdownMenuItem(
                              value: 'TRIAL',
                              child: Text('体验版 · 2 坐席 / 1000 条')),
                          DropdownMenuItem(
                              value: 'STARTER',
                              child: Text('专业版 · 1 坐席 / 5000 条')),
                          DropdownMenuItem(
                              value: 'GROWTH',
                              child: Text('旗舰版 · 3 坐席 / 50,000 条')),
                          DropdownMenuItem(
                              value: 'ENTERPRISE',
                              child: Text('企业版 · 10 坐席 / 1,000,000 条'))
                        ],
                        onChanged: (v) => setState(() => _plan = v ?? _plan)))),
            const SizedBox(height: 16),
            ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('更多接入设置'),
                subtitle: const Text('客服入口名称与公钥，可在开通后调整'),
                children: [
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: ConsoleFormGrid(children: [
                        ConsoleField('客服入口名称',
                            child: TextFormField(
                                controller: _inboxName,
                                decoration: const InputDecoration(
                                    hintText: '选填，自动生成'))),
                        ConsoleField('入口公钥',
                            child: TextFormField(
                                controller: _publicKey,
                                autocorrect: false,
                                decoration: const InputDecoration(
                                    hintText: '选填，自动生成'))),
                      ])),
                ]),
          ])));
}

/// Shows the credential that was just created, which is the only time it is
/// available: the server keeps a hash, so a lost password becomes a reset.
Future<void> showCreatedTenant(
  BuildContext context,
  CreatedTenant created,
) async {
  await showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: const Text('企业已开通'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _DetailRow(label: '企业标识', value: created.slug),
              _DetailRow(label: '客服主管', value: created.ownerEmail),
              if (created.initialPassword.isNotEmpty)
                _DetailRow(
                  label: '初始密码',
                  value: created.initialPassword,
                  emphasised: true,
                ),
              _DetailRow(label: '入口公钥', value: created.publicKey),
              _DetailRow(label: '组件地址', value: created.scriptUrl),
              const SizedBox(height: 12),
              Text(
                created.initialPassword.isEmpty
                    ? '密码由你设定，请转告客服主管。'
                    : '初始密码只显示这一次，请立即转告客服主管。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => copyToClipboard(
              context,
              created.initialPassword.isEmpty
                  ? created.publicKey
                  : created.initialPassword,
              '内容',
            ),
            child: const Text('复制凭证'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ],
      );
    },
  );
}

/// A labelled value row, used by the credential and detail dialogs.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.emphasised = false,
  });

  final String label;
  final String value;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: emphasised ? FontWeight.w700 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
