import 'package:relaydesk_agent_console/src/util/labels.dart';
import 'package:relaydesk_agent_console/src/util/format.dart';
import 'package:relaydesk_agent_console/src/ui/workspace_layout.dart';
import 'package:relaydesk_agent_console/src/ui/support_assets_page.dart';
import 'package:relaydesk_agent_console/src/ui/automation_page.dart';
import 'package:flutter/material.dart';
import 'package:relaydesk_agent_console/src/ui/console_form_dialog.dart';
import 'package:relaydesk_agent_console/src/api/api_exception.dart';
import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/ui/error_banner.dart';

/// 企业管理员的自助管理空间；所有数据仍由服务端按当前企业鉴权。
class TenantAdminPage extends StatefulWidget {
  const TenantAdminPage(
      {super.key, required this.api, this.tenantSlug = '', this.onMemberSaved});
  final RelayDeskApi api;
  final String tenantSlug;
  final Future<void> Function()? onMemberSaved;
  @override
  State<TenantAdminPage> createState() => _TenantAdminPageState();
}

class _TenantAdminPageState extends State<TenantAdminPage> {
  bool _loading = true;
  String? _error;
  String _memberQuery = '';
  List<Map<String, dynamic>> _members = [], _inboxes = [], _audit = [];
  Map<String, dynamic> _subscription = {};
  bool _canAI = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.api.adminGet('agents'),
        widget.api.adminGet('inboxes'),
        widget.api.adminGet('subscription'),
        widget.api.adminGet('audit'),
        widget.api.entitlements(),
      ]);
      if (!mounted) return;
      final features = Map<String, dynamic>.from(
          (results[4]['features'] as Map?) ?? const {});
      setState(() {
        _members = asMapList(results[0]['items']);
        _inboxes = asMapList(results[1]['items']);
        _subscription = results[2];
        _audit = asMapList(results[3]['items']);
        _canAI = features['ai'] == true;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _notice(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<void> _member(Map<String, dynamic> member) async {
    final saved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _MemberDialog(
            member: member,
            inboxes: _inboxes,
            onSubmit: (data) async {
              await widget.api.adminWrite(
                  'PATCH',
                  'agents/${member['id']}',
                  _fields(data, [
                    'displayName',
                    'role',
                    'maxConcurrent',
                    'status',
                    'inboxIds'
                  ]));
            }));
    if (saved == true && mounted) {
      await _load();
      await widget.onMemberSaved?.call();
    }
  }

  Future<void> _inbox([Map<String, dynamic>? inbox]) async {
    try {
      final detail = inbox == null
          ? null
          : await widget.api.adminGet('inboxes/${inbox['id']}');
      if (!mounted) return;
      final saved = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _InboxDialog(
                inbox: detail,
                members: _members,
                // 与 /entitlements 的 ai 能力对齐，避免只看套餐名与服务端脱节。
                canAI: _canAI,
                onSubmit: (data) async {
                  if (inbox == null) {
                    await widget.api.adminWrite(
                        'POST',
                        'inboxes',
                        _fields(data, [
                          'name',
                          'welcomeMessage',
                          'offlineMessage',
                          'allowedDomains',
                          'autoAssign',
                          'logoUrl',
                          'avatarUrl',
                          'fontFamily',
                          'bubbleRadius',
                          'customCss'
                        ]));
                  } else {
                    final id = asString(inbox['id']);
                    final payload = _fields(data, [
                      'name',
                      'welcomeMessage',
                      'offlineMessage',
                      'allowedDomains',
                      'autoAssign',
                      'status',
                      'logoUrl',
                      'avatarUrl',
                      'fontFamily',
                      'bubbleRadius',
                      'customCss'
                    ]);
                    if (_canAI) {
                      payload['aiEnabled'] = data['aiEnabled'];
                      payload['confidenceThreshold'] =
                          data['confidenceThreshold'];
                    }
                    payload['routing'] = {
                      'strategy': data['strategy'],
                      'fixedAgentId': data['fixedAgentId'],
                      'maxConcurrent': data['maxConcurrent'],
                      'acceptanceTimeoutSeconds':
                          data['acceptanceTimeoutSeconds']
                    };
                    await widget.api
                        .adminWrite('PATCH', 'inboxes/$id', payload);
                  }
                },
              ));
      if (saved != true || !mounted) return;
      await _load();
      if (mounted) _notice('已保存。请在团队成员中确认该入口的接待成员。');
    } on ApiException catch (e) {
      if (mounted) _notice('配置未全部保存：${e.message}，请重新打开检查');
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
            title: const Text('同事账号'),
            actions: [
              IconButton(
                  onPressed: _loading ? null : _load,
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh))
            ],
            bottom: const TabBar(isScrollable: true, tabs: [
              Tab(text: '团队成员'),
              Tab(text: '客服入口'),
              Tab(text: '套餐与用量'),
              Tab(text: '操作记录'),
              Tab(text: '团队素材'),
              Tab(text: '自动接待')
            ])),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: ErrorBanner(message: _error!, onDismiss: _load))
                : TabBarView(children: [
                    _memberList(),
                    _inboxList(),
                    _usage(),
                    _auditList(),
                    SupportAssetsPage(api: widget.api, embedded: true),
                    AutomationPage(api: widget.api)
                  ]),
      ));

  Widget _heading(String title, String description, String action,
          VoidCallback callback) =>
      Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 18),
          child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 24,
              runSpacing: 16,
              children: [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text(description,
                      style: Theme.of(context).textTheme.bodySmall)
                ]),
                FilledButton.icon(
                    onPressed: callback,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(action)),
              ]));
  Widget _memberList() => LayoutBuilder(builder: (context, constraints) {
        final members = _members
            .where((m) => '${m['displayName']} ${m['email']}'
                .toLowerCase()
                .contains(_memberQuery.toLowerCase()))
            .toList();
        return ListView(padding: const EdgeInsets.all(24), children: [
          const WorkspaceHeading('团队成员', '集中查看团队账号、接待权限与在线状态。新账号由平台管理员建立。'),
          Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        spacing: 20,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('成员列表 · ${_members.length} 人',
                              style: Theme.of(context).textTheme.titleSmall),
                          SizedBox(
                              width: 280,
                              child: TextField(
                                  onChanged: (v) =>
                                      setState(() => _memberQuery = v),
                                  decoration: const InputDecoration(
                                      hintText: '搜索姓名或用户名',
                                      prefixIcon:
                                          Icon(Icons.search, size: 18)))),
                        ]),
                    const SizedBox(height: 20),
                    if (members.isEmpty)
                      const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: Text('没有匹配的团队成员'))),
                    if (constraints.maxWidth >= 850 && members.isNotEmpty)
                      SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(columns: const [
                            DataColumn(label: Text('成员')),
                            DataColumn(label: Text('登录用户名')),
                            DataColumn(label: Text('角色')),
                            DataColumn(label: Text('接待渠道')),
                            DataColumn(label: Text('状态')),
                            DataColumn(label: Text('操作'))
                          ], rows: [
                            for (final member in members)
                              DataRow(cells: [
                                DataCell(Row(children: [
                                  CircleAvatar(
                                      radius: 14,
                                      backgroundColor: Theme.of(context)
                                          .colorScheme
                                          .primaryContainer,
                                      child: Text(
                                          asString(member['displayName'])
                                                  .isEmpty
                                              ? '人'
                                              : asString(member['displayName'])
                                                  .substring(0, 1),
                                          style:
                                              const TextStyle(fontSize: 12))),
                                  const SizedBox(width: 10),
                                  Text(asString(member['displayName']))
                                ])),
                                DataCell(Text(asString(member['email']))),
                                DataCell(Text(_role(member['role']))),
                                DataCell(Text(
                                    '${asList(member['inboxIds']).length} 个渠道')),
                                DataCell(Row(children: [
                                  Icon(Icons.circle,
                                      size: 7,
                                      color: member['status'] != 'ACTIVE'
                                          ? Colors.grey
                                          : member['presence'] == 'ONLINE'
                                              ? const Color(0xff34a853)
                                              : Colors.grey),
                                  const SizedBox(width: 7),
                                  Text(member['status'] != 'ACTIVE'
                                      ? '已停用'
                                      : member['presence'] == 'ONLINE'
                                          ? '在线'
                                          : '离线')
                                ])),
                                DataCell(TextButton(
                                    onPressed: () => _member(member),
                                    child: const Text('编辑'))),
                              ])
                          ])),
                    if (constraints.maxWidth < 850)
                      for (final member in members)
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(asString(member['displayName'])),
                            subtitle: Text(
                                '${member['email']}\n${_role(member['role'])} · ${asList(member['inboxIds']).length} 个渠道'),
                            isThreeLine: true,
                            trailing: TextButton(
                                onPressed: () => _member(member),
                                child: const Text('编辑'))),
                  ])),
        ]);
      });
  Widget _inboxList() => ListView(children: [
        _heading('客服入口', '每个入口单独设置接待文案、允许域名和自动分配规则。', '创建入口', () => _inbox()),
        for (final inbox in _inboxes)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: Card(
                  elevation: 0,
                  child: ListTile(
                    leading: CircleAvatar(
                        backgroundColor:
                            Theme.of(context).colorScheme.primaryContainer,
                        child: Icon(Icons.chat_bubble_outline,
                            color: Theme.of(context).colorScheme.primary)),
                    title: Text(asString(inbox['name'])),
                    subtitle: Text(
                        '${inbox['publicKey']}\n${inbox['status'] == 'ACTIVE' ? '接入启用' : '已停用'} · ${inbox['autoAssign'] == true ? '自动分配' : '人工领取'}'),
                    isThreeLine: true,
                    trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                  color: inbox['status'] == 'ACTIVE'
                                      ? const Color(0xFFE8F8ED)
                                      : const Color(0xFFFFF2E5),
                                  borderRadius: BorderRadius.circular(20)),
                              child: Text(
                                  inbox['status'] == 'ACTIVE' ? '已启用' : '已停用',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: inbox['status'] == 'ACTIVE'
                                          ? const Color(0xFF00B42A)
                                          : const Color(0xFFFF7D00)))),
                          OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(64, 28),
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact),
                              onPressed: () => _inbox(inbox),
                              child: const Text('配置'))
                        ]),
                  ))),
      ]);
  Widget _usage() => ListView(padding: const EdgeInsets.all(24), children: [
        const WorkspaceHeading('套餐与用量', '查看当前服务额度与本月实际使用情况'),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(planLabel(asString(_subscription['plan'])),
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 8),
                      Text(
                          '订阅状态：${billingStatusLabel(asString(_subscription['status']))}'),
                      const SizedBox(height: 24),
                      _usageRow('活跃坐席', asInt(_subscription['usedSeats']),
                          asInt(_subscription['seatLimit'])),
                      const SizedBox(height: 24),
                      _usageRow('本月消息', asInt(_subscription['usedMessages']),
                          asInt(_subscription['monthlyMessageLimit'])),
                      const SizedBox(height: 24),
                      _usageRow('本月 AI 回复', asInt(_subscription['usedAi']),
                          asInt(_subscription['monthlyAiLimit'])),
                      const SizedBox(height: 24),
                      Text(
                          '服务截止：${_subscription['serviceEndsAt'] == null ? '长期有效' : fullTime(asDate(_subscription['serviceEndsAt']))}'),
                      if (_subscription['plan'] == 'TRIAL') ...[
                        const SizedBox(height: 24),
                        Text(
                            '试用截止：${fullTime(asDate(_subscription['trialEndsAt']))}')
                      ],
                    ]))),
        const SizedBox(height: 16),
        const Text('如需增加坐席、提升额度或变更套餐，请联系平台超级管理员。'),
      ]);
  Widget _usageRow(String label, int used, int limit) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$label · $used / $limit'),
        const SizedBox(height: 12),
        LinearProgressIndicator(
            value: limit > 0 ? (used / limit).clamp(0, 1).toDouble() : 0,
            minHeight: 8),
      ]);
  Widget _auditList() => ListView(padding: const EdgeInsets.all(24), children: [
        Text('最近的管理操作', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 18),
        for (final item in _audit)
          ListTile(
              leading: const Icon(Icons.history, size: 20),
              title: Text(auditActionLabel(asString(item['action']))),
              subtitle: Text(
                  '${asString(item['actorName']).isNotEmpty ? item['actorName'] : (item['actorType'] == 'PLATFORM' ? '平台管理员' : '团队成员')} · ${fullTime(asDate(item['createdAt']))}')),
      ]);
}

List<dynamic> asList(dynamic value) => value is List ? value : [];
// 管理 API 严格校验字段，各请求只发送自己的字段，避免对话框复用数据导致保存失败。
Map<String, dynamic> _fields(Map<String, dynamic> data, List<String> keys) => {
      for (final key in keys)
        if (data.containsKey(key)) key: data[key]
    };
String _role(dynamic value) => switch (value) {
      'OWNER' => '客服主管',
      'ADMIN' => '客服主管',
      'SUPERVISOR' => '客服主管',
      _ => '客服坐席'
    };

class _MemberDialog extends StatefulWidget {
  const _MemberDialog(
      {required this.member, required this.inboxes, required this.onSubmit});
  final Future<void> Function(Map<String, dynamic>) onSubmit;
  final Map<String, dynamic>? member;
  final List<Map<String, dynamic>> inboxes;
  @override
  State<_MemberDialog> createState() => _MemberDialogState();
}

class _MemberDialogState extends State<_MemberDialog> {
  final _form = GlobalKey<FormState>();
  bool _saving = false;
  String? _error;
  late final _name =
      TextEditingController(text: asString(widget.member?['displayName']));
  late final _email =
      TextEditingController(text: asString(widget.member?['email']));
  late final _capacity =
      TextEditingController(text: '${widget.member?['maxConcurrent'] ?? 5}');
  late String _roleValue = asString(widget.member?['role']).isEmpty
      ? 'AGENT'
      : (['OWNER', 'ADMIN'].contains(asString(widget.member?['role']))
          ? 'SUPERVISOR'
          : asString(widget.member?['role']));
  late bool _active = widget.member?['status'] != 'DISABLED';
  late final Set<String> _selected =
      asList(widget.member?['inboxIds']).map((e) => e.toString()).toSet();
  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _capacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ConsoleFormDialog(
        description: '管理成员资料、账号状态与可接待的客服入口。',
        busy: _saving,
        error: _error,
        submitLabel: '保存修改',
        onSubmit: _save,
        icon: Icons.manage_accounts_outlined,
        title: widget.member == null ? '添加团队成员' : '管理团队成员',
        child: SizedBox(
            width: 500,
            child: SingleChildScrollView(
                child: Form(
                    key: _form,
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextFormField(
                              controller: _name,
                              decoration:
                                  const InputDecoration(labelText: '成员姓名'),
                              validator: (v) =>
                                  (v ?? '').trim().isEmpty ? '请输入姓名' : null),
                          const SizedBox(height: 16),
                          TextFormField(
                              controller: _email,
                              enabled: widget.member == null,
                              decoration:
                                  const InputDecoration(labelText: '登录用户名'),
                              validator: (v) => (v ?? '').trim().isNotEmpty
                                  ? null
                                  : '请输入用户名'),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                              value: _roleValue,
                              decoration:
                                  const InputDecoration(labelText: '角色'),
                              items: ['AGENT', 'SUPERVISOR']
                                  .map((r) => DropdownMenuItem(
                                      value: r, child: Text(_role(r))))
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => _roleValue = v!)),
                          const SizedBox(height: 16),
                          TextFormField(
                              controller: _capacity,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                  labelText: '同时接待上限（1–100）'),
                              validator: (v) =>
                                  (int.tryParse(v ?? '') ?? -1) < 0
                                      ? '请输入非负整数'
                                      : null),
                          const SizedBox(height: 20),
                          const Text('可接待的客服入口'),
                          if (widget.inboxes.isEmpty)
                            const Text('请先创建客服入口，再分配给成员。'),
                          for (final i in widget.inboxes)
                            CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(asString(i['name'])),
                                value: _selected.contains(i['id']),
                                onChanged: (v) => setState(() {
                                      v == true
                                          ? _selected.add(asString(i['id']))
                                          : _selected.remove(i['id']);
                                    })),
                          if (widget.member != null)
                            SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('启用账号'),
                                value: _active,
                                onChanged: (v) => setState(() => _active = v)),
                          if (widget.member == null)
                            const Text('系统生成初始密码，创建后仅显示一次。'),
                        ])))),
      );
  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    if (_selected.isEmpty) {
      setState(() => _error = '至少分配一个客服入口，才能接收客户消息');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSubmit(<String, dynamic>{
        'displayName': _name.text.trim(),
        'email': _email.text.trim(),
        'role': _roleValue,
        'maxConcurrent': int.parse(_capacity.text),
        'inboxIds': _selected.toList(),
        'status': _active ? 'ACTIVE' : 'DISABLED'
      });
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请检查连接后重试。已填写的信息已保留。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _InboxDialog extends StatefulWidget {
  const _InboxDialog(
      {this.inbox,
      required this.members,
      required this.canAI,
      required this.onSubmit});
  final Future<void> Function(Map<String, dynamic>) onSubmit;
  final bool canAI;
  final List<Map<String, dynamic>> members;
  final Map<String, dynamic>? inbox;
  @override
  State<_InboxDialog> createState() => _InboxDialogState();
}

class _InboxDialogState extends State<_InboxDialog> {
  bool _busy = false;
  String? _error;
  final _form = GlobalKey<FormState>();
  late final _name =
      TextEditingController(text: asString(widget.inbox?['name']));
  late final _welcome =
      TextEditingController(text: asString(widget.inbox?['welcomeMessage']));
  late final _offline =
      TextEditingController(text: asString(widget.inbox?['offlineMessage']));
  late final _domains = TextEditingController(
      text: asList(widget.inbox?['allowedDomains']).join(', '));
  late final _logo =
      TextEditingController(text: asString(widget.inbox?['logoUrl']));
  late final _avatar =
      TextEditingController(text: asString(widget.inbox?['avatarUrl']));
  late final _font =
      TextEditingController(text: asString(widget.inbox?['fontFamily']));
  late final _radius = TextEditingController(
      text: widget.inbox?['bubbleRadius']?.toString() ?? '');
  late final _css =
      TextEditingController(text: asString(widget.inbox?['customCss']));
  late bool _auto = widget.inbox?['autoAssign'] != false,
      _active = widget.inbox?['status'] != 'DISABLED',
      _ai = widget.inbox?['aiEnabled'] == true;
  late String _strategy =
      asString(asMap(widget.inbox?['routing'])['strategy']).isEmpty
          ? 'LOAD_BALANCED'
          : asString(asMap(widget.inbox?['routing'])['strategy']);
  late final _acceptanceTimeout = TextEditingController(
      text:
          '${asInt(asMap(widget.inbox?['routing'])['acceptanceTimeoutSeconds']) > 0 ? asInt(asMap(widget.inbox?['routing'])['acceptanceTimeoutSeconds']) : 60}');
  late String _fixedAgent =
      asString(asMap(widget.inbox?['routing'])['fixedAgentId']);
  @override
  void dispose() {
    _acceptanceTimeout.dispose();
    _name.dispose();
    _welcome.dispose();
    _offline.dispose();
    _domains.dispose();
    _logo.dispose();
    _avatar.dispose();
    _font.dispose();
    _radius.dispose();
    _css.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.inbox == null ? '创建客服入口' : '配置客服入口'),
          content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                  child: Form(
                      key: _form,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        if (_error != null)
                          Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(_error!,
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error))),
                        TextFormField(
                            controller: _name,
                            decoration:
                                const InputDecoration(labelText: '入口名称'),
                            validator: (v) =>
                                (v ?? '').trim().isEmpty ? '请输入入口名称' : null),
                        const SizedBox(height: 16),
                        TextFormField(
                            controller: _welcome,
                            maxLines: 2,
                            decoration:
                                const InputDecoration(labelText: '欢迎语')),
                        const SizedBox(height: 16),
                        TextFormField(
                            controller: _offline,
                            maxLines: 2,
                            decoration:
                                const InputDecoration(labelText: '离线留言提示')),
                        const SizedBox(height: 16),
                        TextFormField(
                            controller: _domains,
                            decoration: const InputDecoration(
                                labelText: '允许的域名（逗号分隔）',
                                helperText: '例如 example.com；留空不限制入口域名')),
                        const SizedBox(height: 16),
                        SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('自动分配给在线成员'),
                            value: _auto,
                            onChanged: (v) => setState(() => _auto = v)),
                        const SizedBox(height: 16),
                        ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: const Text('外观白标（访客窗口）'),
                            subtitle: const Text('自定义访客端 Logo、头像、字体与圆角'),
                            children: [
                              TextFormField(
                                  controller: _logo,
                                  decoration: const InputDecoration(
                                      labelText: 'Logo 图片地址')),
                              const SizedBox(height: 16),
                              TextFormField(
                                  controller: _avatar,
                                  decoration: const InputDecoration(
                                      labelText: '客服头像地址')),
                              const SizedBox(height: 16),
                              TextFormField(
                                  controller: _font,
                                  decoration: const InputDecoration(
                                      labelText: '字体 font-family',
                                      helperText:
                                          '例如 "PingFang SC", sans-serif')),
                              const SizedBox(height: 16),
                              TextFormField(
                                  controller: _radius,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                      labelText: '气泡圆角（0-40 px）')),
                              const SizedBox(height: 16),
                              TextFormField(
                                  controller: _css,
                                  maxLines: 4,
                                  decoration: const InputDecoration(
                                      labelText: '自定义 CSS',
                                      helperText: '将注入访客窗口 Shadow DOM')),
                              const SizedBox(height: 8),
                            ]),
                        if (widget.inbox != null) ...[
                          DropdownButtonFormField<String>(
                              value: _strategy,
                              decoration:
                                  const InputDecoration(labelText: '分配方式'),
                              items: const [
                                DropdownMenuItem(
                                    value: 'LOAD_BALANCED',
                                    child: Text('优先空闲成员')),
                                DropdownMenuItem(
                                    value: 'ROUND_ROBIN', child: Text('轮流分配')),
                                DropdownMenuItem(
                                    value: 'FIXED', child: Text('指定成员'))
                              ],
                              onChanged: (v) => setState(() => _strategy = v!)),
                          TextFormField(
                              controller: _acceptanceTimeout,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                  labelText: '接单超时（秒）',
                                  helperText: '10～600秒；超时自动重新分配，默认60秒'),
                              validator: (v) {
                                final n = int.tryParse(v ?? '');
                                return n == null || n < 10 || n > 600
                                    ? '请输入10到600之间的整数'
                                    : null;
                              }),
                          if (_strategy == 'FIXED')
                            DropdownButtonFormField<String>(
                              value: _fixedAgent.isEmpty ? null : _fixedAgent,
                              decoration:
                                  const InputDecoration(labelText: '指定接待成员'),
                              items: [
                                for (final member in widget.members)
                                  DropdownMenuItem(
                                      value: asString(member['id']),
                                      child:
                                          Text(asString(member['displayName'])))
                              ],
                              validator: (v) =>
                                  (v ?? '').isEmpty ? '请选择接待成员' : null,
                              onChanged: (v) =>
                                  setState(() => _fixedAgent = v ?? ''),
                            ),
                          if (widget.canAI)
                            SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('知识库 AI 自动接待'),
                                subtitle: const Text('需平台配置可用模型，无法回答时转人工'),
                                value: _ai,
                                onChanged: (v) => setState(() => _ai = v)),
                          SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('启用入口'),
                              value: _active,
                              onChanged: (v) => setState(() => _active = v)),
                        ],
                      ])))),
          actions: [
            TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: _busy
                    ? null
                    : () async {
                        if (!_form.currentState!.validate()) return;
                        setState(() {
                          _busy = true;
                          _error = null;
                        });
                        try {
                          await widget.onSubmit(<String, dynamic>{
                            'name': _name.text.trim(),
                            'welcomeMessage': _welcome.text,
                            'offlineMessage': _offline.text,
                            'allowedDomains': _domains.text
                                .split(RegExp('[,，]'))
                                .map((s) => s.trim())
                                .where((s) => s.isNotEmpty)
                                .toList(),
                            'autoAssign': _auto,
                            'logoUrl': _logo.text.trim(),
                            'avatarUrl': _avatar.text.trim(),
                            'fontFamily': _font.text.trim(),
                            'customCss': _css.text,
                            'bubbleRadius': int.tryParse(_radius.text.trim()),
                            'status': _active ? 'ACTIVE' : 'DISABLED',
                            'aiEnabled': _ai,
                            'confidenceThreshold':
                                widget.inbox?['confidenceThreshold'] ?? 0.35,
                            'strategy': _strategy,
                            'acceptanceTimeoutSeconds':
                                int.parse(_acceptanceTimeout.text),
                            'fixedAgentId':
                                _strategy == 'FIXED' ? _fixedAgent : '',
                            'maxConcurrent': asMap(widget.inbox?['routing'])[
                                    'maxConcurrent'] ??
                                5,
                          });
                          if (mounted) Navigator.pop(context, true);
                        } catch (e) {
                          if (mounted)
                            setState(() => _error = '保存失败，请修改后重试：$e');
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
                child: Text(_busy ? '保存中…' : '保存'))
          ]);
}
