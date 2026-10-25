import 'package:tongyu_agent_console/src/util/labels.dart';
import 'package:tongyu_agent_console/src/util/format.dart';
import 'package:tongyu_agent_console/src/ui/workspace_layout.dart';
import 'package:tongyu_agent_console/src/ui/support_assets_page.dart';
import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/ui/console_form_dialog.dart';
import 'package:tongyu_agent_console/src/api/api_exception.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/ui/error_banner.dart';

/// 企业管理员的自助管理空间；所有数据仍由服务端按当前企业鉴权。
class TenantAdminPage extends StatefulWidget {
  const TenantAdminPage(
      {super.key, required this.api, this.tenantSlug = '', this.onMemberSaved});
  final TongYuApi api;
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
  Future<void> _member([Map<String, dynamic>? member]) async {
    String? initialPassword;
    final saved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _MemberDialog(
            member: member,
            inboxes: _inboxes,
            onSubmit: (data) async {
              if (member == null) {
                // 主管自助建号：席位由服务端校验；初始密码仅本次响应返回。
                final created = await widget.api.adminWrite(
                    'POST',
                    'agents',
                    _fields(data, [
                      'displayName',
                      'email',
                      'role',
                      'maxConcurrent',
                      'inboxIds'
                    ]));
                initialPassword = asString(created['initialPassword']);
                return;
              }
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
      if ((initialPassword ?? '').isNotEmpty && mounted) {
        await showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
                  title: const Text('成员已创建'),
                  content: SelectableText(
                      '登录用户名与初始密码仅显示一次，请立即交给对应成员：\n\n'
                      '初始密码：$initialPassword'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('已记下'))
                  ],
                ));
      }
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
                          'autoAccept',
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
                      'autoAccept',
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
      // 自动回复 / 渠道管理已提到左侧一级菜单，这里只留企业账号与入口。
      length: 5,
      child: Scaffold(
        appBar: WorkspaceAppBar(
            title: '企业管理',
            description: '管理团队、客服入口与服务用量',
            icon: Icons.apartment_outlined,
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
                  ]),
      ));

  Widget _heading(String title, String description, String action,
          VoidCallback callback) =>
      Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 20,
              runSpacing: 10,
              children: [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontSize: 15)),
                  const SizedBox(height: 3),
                  Text(description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant))
                ]),
                FilledButton.icon(
                    onPressed: callback,
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: Text(action)),
              ]));
  Widget _memberList() => LayoutBuilder(builder: (context, constraints) {
        final theme = Theme.of(context);
        final members = _members
            .where((m) => '${m['displayName']} ${m['email']}'
                .toLowerCase()
                .contains(_memberQuery.toLowerCase()))
            .toList();
        final online = _members
            .where((m) =>
                m['status'] == 'ACTIVE' && m['presence'] == 'ONLINE')
            .length;
        final supervisors =
            _members.where((m) => m['role'] == 'SUPERVISOR').length;
        final seatLimit = asInt(_subscription['seatLimit']);
        final usedSeats = asInt(_subscription['usedSeats']);
        final seatsLeft =
            seatLimit > 0 ? (seatLimit - usedSeats).clamp(0, seatLimit) : 0;
        return ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 24), children: [
          _heading(
              '团队成员',
              seatLimit > 0
                  ? '集中查看团队账号、接待权限与在线状态。可在席位额度内添加成员（已用 $usedSeats / $seatLimit，剩余 $seatsLeft）。'
                  : '集中查看团队账号、接待权限与在线状态。可在席位额度内添加成员。',
              '添加成员',
              () => _member()),
          // 汇总当前企业的真实成员数据；搜索只筛选列表，不改变团队总览。
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(children: [
              Expanded(
                  child: _memberMetric('团队成员', _members.length,
                      Icons.groups_2_outlined, const Color(0xFF3263FF))),
              const SizedBox(width: 10),
              Expanded(
                  child: _memberMetric('在线成员', online,
                      Icons.bolt_rounded, const Color(0xFF31977C))),
              const SizedBox(width: 10),
              Expanded(
                  child: _memberMetric('主管', supervisors,
                      Icons.shield_outlined, const Color(0xFF7C5CFC))),
            ]),
          ),
          WorkspaceCard(
              padding: EdgeInsets.zero,
              title: '成员列表',
              subtitle: '共 ${_members.length} 人 · 搜索只影响下方结果',
              icon: Icons.people_alt_outlined,
              actions: [
                SizedBox(
                    width: constraints.maxWidth < 420
                        ? constraints.maxWidth - 120
                        : 240,
                    child: TextField(
                        onChanged: (v) => setState(() => _memberQuery = v),
                        style: const TextStyle(fontSize: 12.5),
                        decoration: const InputDecoration(
                            isDense: true,
                            hintText: '搜索姓名或用户名',
                            fillColor: Color(0xFFF7F9FD),
                            prefixIconConstraints:
                                BoxConstraints(minWidth: 32, minHeight: 32),
                            prefixIcon:
                                Icon(Icons.search_rounded, size: 16),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 8, vertical: 8)))),
              ],
              child: members.isEmpty
                  ? const WorkspaceEmptyState(
                      icon: Icons.person_search_outlined,
                      title: '没有匹配的团队成员',
                      description: '换一个姓名或用户名再试，或点击「添加成员」新建账号。',
                      compact: true)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (constraints.maxWidth >= 850)
                          SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                      minWidth: constraints.maxWidth - 42),
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
                                          Container(
                                            width: 24,
                                            height: 24,
                                            decoration: BoxDecoration(
                                              color: theme.colorScheme.primary
                                                  .withOpacity(.09),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            alignment: Alignment.center,
                                            child: Text(
                                                asString(member['displayName'])
                                                        .isEmpty
                                                    ? '人'
                                                    : asString(member[
                                                            'displayName'])
                                                        .substring(0, 1),
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                    color: theme
                                                        .colorScheme.primary)),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(asString(member['displayName']))
                                        ])),
                                        DataCell(Text(asString(member['email']))),
                                        DataCell(Text(_role(member['role']))),
                                        DataCell(Text(
                                            '${asList(member['inboxIds']).length} 个渠道')),
                                        DataCell(Row(children: [
                                          Icon(Icons.circle,
                                              size: 7,
                                              color: member['status'] !=
                                                      'ACTIVE'
                                                  ? Colors.grey
                                                  : member['presence'] ==
                                                          'ONLINE'
                                                      ? const Color(0xff34a853)
                                                      : Colors.grey),
                                          const SizedBox(width: 6),
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
                                  ]))),
                        if (constraints.maxWidth < 850)
                          for (final member in members)
                            ListTile(
                                dense: true,
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

  Widget _memberMetric(String label, int count, IconData icon, Color tone) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
              color: tone.withOpacity(.09),
              borderRadius: BorderRadius.circular(7)),
          child: Icon(icon, size: 14, color: tone),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
              Text('$count 人',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontSize: 17, height: 1.25)),
            ],
          ),
        ),
      ]),
    );
  }
  Widget _inboxList() => ListView(padding: const EdgeInsets.only(bottom: 20), children: [
        _heading(
            '客服入口',
            '每个入口单独设置接待文案、允许域名，以及「自动分配 / 分配后自动接单」（点进入口编辑）。',
            '创建入口',
            () => _inbox()),
        for (final inbox in _inboxes)
          Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: WorkspaceCard(
                padding: EdgeInsets.zero,
                child: WorkspaceListRow(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: asString(inbox['name']),
                  subtitle:
                      '${inbox['publicKey']} · ${inbox['autoAssign'] == true ? (inbox['autoAccept'] == true ? '自动分配并接单' : '自动分配（仍需点接单）') : '人工领取'}',
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    WorkspaceTag(
                        text: inbox['status'] == 'ACTIVE' ? '已启用' : '已停用',
                        tone: inbox['status'] == 'ACTIVE'
                            ? const Color(0xFF31977C)
                            : const Color(0xFFF97316)),
                    const SizedBox(width: 8),
                    OutlinedButton(
                        onPressed: () => _inbox(inbox),
                        child: const Text('配置')),
                  ]),
                ),
              )),
      ]);
  Widget _usage() => ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 24), children: [
        const WorkspaceHeading('套餐与用量', '查看当前服务额度与本月实际使用情况'),
        WorkspaceCard(
            padding: const EdgeInsets.all(18),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity(.08),
                          borderRadius: BorderRadius.circular(8)),
                      child: Icon(Icons.workspace_premium_outlined,
                          size: 17,
                          color: Theme.of(context).colorScheme.primary),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(planLabel(asString(_subscription['plan'])),
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontSize: 16)),
                            Text(
                                '订阅状态：${billingStatusLabel(asString(_subscription['status']))}',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant)),
                          ]),
                    ),
                  ]),
                  const SizedBox(height: 18),
                  _usageRow('活跃坐席', asInt(_subscription['usedSeats']),
                      asInt(_subscription['seatLimit'])),
                  const SizedBox(height: 18),
                  _usageRow('本月消息', asInt(_subscription['usedMessages']),
                      asInt(_subscription['monthlyMessageLimit'])),
                  const SizedBox(height: 18),
                  _usageRow('本月 AI 回复', asInt(_subscription['usedAi']),
                      asInt(_subscription['monthlyAiLimit'])),
                  const SizedBox(height: 18),
                  Divider(color: Theme.of(context).colorScheme.outlineVariant),
                  const SizedBox(height: 12),
                  Text(
                      '服务截止：${_subscription['serviceEndsAt'] == null ? '长期有效' : fullTime(asDate(_subscription['serviceEndsAt']))}',
                      style: Theme.of(context).textTheme.bodySmall),
                  if (_subscription['plan'] == 'TRIAL') ...[
                    const SizedBox(height: 4),
                    Text('试用截止：${fullTime(asDate(_subscription['trialEndsAt']))}',
                        style: Theme.of(context).textTheme.bodySmall)
                  ],
                ])),
        const SizedBox(height: 12),
        Center(
          child: Text('如需增加坐席、提升额度或变更套餐，请联系平台超级管理员。',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      ]);
  Widget _usageRow(String label, int used, int limit) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w500))),
          Text('$used / $limit',
              style: TextStyle(
                  fontSize: 11.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
              value: limit > 0 ? (used / limit).clamp(0, 1).toDouble() : 0,
              minHeight: 6,
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHigh),
        ),
      ]);
  Widget _auditList() => ListView(padding: const EdgeInsets.fromLTRB(20, 16, 20, 24), children: [
        const WorkspaceHeading('操作记录', '最近的管理操作与执行人'),
        WorkspaceListCard(
          title: '最近的管理操作',
          icon: Icons.history_rounded,
          children: [
            for (final item in _audit)
              WorkspaceListRow(
                icon: Icons.history_rounded,
                title: auditActionLabel(asString(item['action'])),
                subtitle:
                    '${asString(item['actorName']).isNotEmpty ? item['actorName'] : (item['actorType'] == 'PLATFORM' ? '平台管理员' : '团队成员')} · ${fullTime(asDate(item['createdAt']))}',
              ),
          ],
          empty: const WorkspaceEmptyState(
            icon: Icons.history_rounded,
            title: '还没有管理操作',
            description: '成员、入口和套餐变更会记录在这里。',
            compact: true,
          ),
        ),
      ]);
}

List<dynamic> asList(dynamic value) => value is List ? value : [];
// 管理 API 严格校验字段，各请求只发送自己的字段，避免对话框复用数据导致保存失败。
Map<String, dynamic> _fields(Map<String, dynamic> data, List<String> keys) => {
      for (final key in keys)
        if (data.containsKey(key)) key: data[key]
    };
String _role(dynamic value) =>
    switch (value) { 'SUPERVISOR' => '客服主管', _ => '客服坐席' };

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
      : asString(widget.member?['role']);
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
        description: widget.member == null
            ? '在席位额度内新建成员，并分配可接待的客服入口。系统生成初始密码，创建后仅显示一次。'
            : '管理成员资料、账号状态与可接待的客服入口。',
        busy: _saving,
        error: _error,
        submitLabel: widget.member == null ? '添加成员' : '保存修改',
        onSubmit: _save,
        icon: widget.member == null
            ? Icons.person_add_alt_1_outlined
            : Icons.manage_accounts_outlined,
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
      // 默认关闭：分配后仍需点「开始接待」。
      _autoAccept = widget.inbox?['autoAccept'] == true,
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
                            onChanged: (v) => setState(() {
                                  _auto = v;
                                  if (!v) _autoAccept = false;
                                })),
                        SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('分配后自动接单'),
                            subtitle: Text(
                              _auto
                                  ? '开启后：系统分到的会话直接可回复；客服打开待接待会话也会自动接入，无需再点「开始接待」'
                                  : '需先开启「自动分配给在线成员」',
                            ),
                            value: _auto && _autoAccept,
                            onChanged: !_auto
                                ? null
                                : (v) => setState(() => _autoAccept = v)),
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
                            'autoAccept': _auto && _autoAccept,
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
