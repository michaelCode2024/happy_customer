import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/platform/platform_models.dart';
import 'package:relaydesk_agent_console/src/ui/error_banner.dart';
import 'package:relaydesk_agent_console/src/util/format.dart';

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
  });

  final List<TenantSummary> tenants;
  final String query;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<TenantSummary> onOpen;
  final String selectedId;
  final Future<void> Function() onRefresh;

  @override
  State<TenantTable> createState() => _TenantTableState();
}

class _TenantTableState extends State<TenantTable> {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
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
                '共 ${widget.tenants.length} 家企业',
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
          child: widget.tenants.isEmpty
              ? Center(
                  child: Text(
                    widget.query.isEmpty
                        ? '还没有企业'
                        : '没有匹配「${widget.query}」的企业',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: widget.tenants.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (context, index) {
                    final tenant = widget.tenants[index];
                    return _TenantRow(
                      tenant: tenant,
                      selected: tenant.id == widget.selectedId,
                      onTap: () => widget.onOpen(tenant),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _TenantRow extends StatelessWidget {
  const _TenantRow({
    required this.tenant,
    required this.selected,
    required this.onTap,
  });

  final TenantSummary tenant;
  final bool selected;
  final VoidCallback onTap;

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
                          label: tenant.plan,
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
        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
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
  const CreateTenantDialog({super.key});

  @override
  State<CreateTenantDialog> createState() => _CreateTenantDialogState();
}

/// What the operator typed, handed back to the caller to submit. Returning the
/// values rather than the created record keeps the dialog free of the network.
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
  final _name = TextEditingController();
  final _slug = TextEditingController();
  final _ownerEmail = TextEditingController();
  final _ownerName = TextEditingController();
  final _ownerPassword = TextEditingController();
  final _inboxName = TextEditingController();
  final _publicKey = TextEditingController();
  String _plan = 'TRIAL';

  @override
  void dispose() {
    _name.dispose();
    _slug.dispose();
    _ownerEmail.dispose();
    _ownerName.dispose();
    _ownerPassword.dispose();
    _inboxName.dispose();
    _publicKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('开通企业'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '企业名称',
                    hintText: '例如 连语科技',
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? '请填写企业名称' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _slug,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '企业标识（可选）',
                    hintText: '留空则按名称生成，登录时使用',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _ownerName,
                  decoration: const InputDecoration(
                    labelText: '管理员姓名（可选）',
                    hintText: '默认「管理员」',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _ownerEmail,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '管理员邮箱',
                    hintText: '该账号将获得 OWNER 权限',
                  ),
                  validator: (value) {
                    final email = (value ?? '').trim();
                    if (email.isEmpty) {
                      return '请填写管理员邮箱';
                    }
                    return email.contains('@') ? null : '邮箱格式不正确';
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _ownerPassword,
                  decoration: const InputDecoration(
                    labelText: '初始密码（可选）',
                    hintText: '留空由服务器生成，只显示一次',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _inboxName,
                  decoration: const InputDecoration(
                    labelText: '客服入口名称（可选）',
                    hintText: '留空则使用「企业名称 + 网站客服」',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _publicKey,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'publicKey（可选）',
                    hintText: '网站组件用它识别入口，留空则按标识生成',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _plan,
                  decoration: const InputDecoration(labelText: '套餐'),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(
                      value: 'TRIAL',
                      child: Text('TRIAL · 2 坐席 / 1000 条'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'STARTER',
                      child: Text('STARTER · 3 坐席 / 5000 条'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'GROWTH',
                      child: Text('GROWTH · 10 坐席 / 5 万条'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'ENTERPRISE',
                      child: Text('ENTERPRISE · 100 坐席 / 100 万条'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _plan = value);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (!(_formKey.currentState?.validate() ?? false)) {
              return;
            }
            Navigator.of(context).pop(
              CreateTenantRequest(
                name: _name.text.trim(),
                slug: _slug.text.trim(),
                ownerEmail: _ownerEmail.text.trim(),
                ownerName: _ownerName.text.trim(),
                ownerPassword: _ownerPassword.text,
                inboxName: _inboxName.text.trim(),
                publicKey: _publicKey.text.trim(),
                plan: _plan,
                trialDays: _plan == 'TRIAL' ? 14 : 0,
              ),
            );
          },
          child: const Text('开通'),
        ),
      ],
    );
  }
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
              _DetailRow(label: '管理员', value: created.ownerEmail),
              if (created.initialPassword.isNotEmpty)
                _DetailRow(
                  label: '初始密码',
                  value: created.initialPassword,
                  emphasised: true,
                ),
              _DetailRow(label: 'publicKey', value: created.publicKey),
              _DetailRow(label: '组件地址', value: created.scriptUrl),
              const SizedBox(height: 12),
              Text(
                created.initialPassword.isEmpty
                    ? '密码由你设定，请转告管理员。'
                    : '初始密码只显示这一次，请立即转告管理员。',
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
