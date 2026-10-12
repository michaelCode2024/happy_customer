import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../platform/platform_controller.dart';
import '../api/api_exception.dart';
import '../util/labels.dart';

String quotaNumber(dynamic value) {
  final raw = '${value ?? 0}';
  return raw.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
}

int qi(Map<String, dynamic> q, String key) => (q[key] as num?)?.toInt() ?? 0;
String quotaDate(dynamic value) => value == null
    ? '长期有效'
    : (DateTime.tryParse(value.toString())?.toLocal().toIso8601String() ??
            value.toString())
        .split('T')
        .first;
String quotaTime(dynamic value) {
  final date = DateTime.tryParse('$value')?.toLocal();
  if (date == null) return '';
  return '${quotaDate(value)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

String quotaRequestId() {
  final b = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  final s = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

Future<bool> openQuotaEditor(
    BuildContext context, PlatformController controller, String id,
    {String? initialPlan}) async {
  if (!controller.isSuperAdmin) return false;
  return await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => ManualQuotaEditor(
              controller: controller,
              tenantId: id,
              initialPlan: initialPlan))) ??
      false;
}

class ManualQuotaPage extends StatefulWidget {
  const ManualQuotaPage(
      {super.key,
      required this.controller,
      this.overview = false,
      this.history = false});
  final PlatformController controller;
  final bool overview;
  final bool history;
  @override
  State<ManualQuotaPage> createState() => _ManualQuotaPageState();
}

class _ManualQuotaPageState extends State<ManualQuotaPage> {
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _logs = [];
  bool _loading = true, _more = false;
  String? _error;
  String _query = '';
  int _generation = 0;
  Timer? _debounce;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final generation = ++_generation;
    setState(() => _loading = true);
    try {
      final body = widget.history
          ? await widget.controller.api
              .quotaHistory(offset: more ? _logs.length : 0)
          : await widget.controller.api
              .quotas(query: _query, offset: more ? _rows.length : 0);
      final rows = (body['items'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      List<Map<String, dynamic>> logs = [];
      if (widget.overview) {
        final history = await widget.controller.api.quotaHistory();
        logs = (history['items'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .take(3)
            .toList();
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        if (widget.history) {
          _logs = more ? [..._logs, ...rows] : rows;
        } else {
          _rows = more ? [..._rows, ...rows] : rows;
          if (widget.overview) _logs = logs;
        }
        _more = body['hasMore'] == true;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (mounted && generation == _generation)
        setState(() {
          _error = e is ApiException ? e.message : '加载失败，请重试';
          _loading = false;
        });
    }
  }

  Future<void> _edit(Map<String, dynamic> q) async {
    if (await openQuotaEditor(
        context, widget.controller, q['tenantId'].toString())) {
      if (mounted) {
        await _load();
        await widget.controller.refreshOverview();
      }
    }
  }

  Widget _card(Widget child) => Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant)),
      child: child);
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overview = widget.controller.overview;
    return ListView(padding: const EdgeInsets.all(24), children: [
      Row(children: [
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              widget.history
                  ? '操作记录'
                  : widget.overview
                      ? '平台概览'
                      : '套餐与额度',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(widget.history ? '追溯额度调整前后、操作者与原因' : '企业服务与额度统一管理',
              style: theme.textTheme.bodySmall)
        ])),
        IconButton(
            tooltip: '刷新额度',
            onPressed: _loading ? null : () => _load(),
            icon: const Icon(Icons.refresh))
      ]),
      const SizedBox(height: 20),
      if (!widget.history) ...[
        Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withOpacity(.4),
                borderRadius: BorderRadius.circular(10)),
            child: const Row(children: [
              Icon(Icons.verified_user_outlined),
              SizedBox(width: 12),
              Expanded(
                  child: Text('手动分配模式 · 暂未接入支付\n套餐、额度及服务期限仅由超级管理员调整。',
                      style: TextStyle(height: 1.8)))
            ])),
        const SizedBox(height: 20),
        if (widget.overview)
          LayoutBuilder(builder: (context, c) {
            final cards = [
              ('企业总数', '${overview?.tenants ?? 0}'),
              ('正常使用', '${overview?.activeTenants ?? 0}'),
              ('坐席总数', '${overview?.agents ?? 0}'),
              ('今日消息', '${overview?.messagesToday ?? 0}')
            ];
            return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: cards
                    .map((m) => SizedBox(
                        width: (c.maxWidth - (c.maxWidth >= 800 ? 36 : 12)) /
                            (c.maxWidth >= 800 ? 4 : 2),
                        child: _card(Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(m.$1, style: theme.textTheme.bodySmall),
                              const SizedBox(height: 12),
                              Text(quotaNumber(m.$2),
                                  style: const TextStyle(
                                      fontSize: 26,
                                      fontWeight: FontWeight.w700))
                            ]))))
                    .toList());
          }),
        const SizedBox(height: 20),
        _card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('企业额度概览',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          TextField(
              onChanged: (v) {
                _query = v;
                _generation++;
                _debounce?.cancel();
                _debounce =
                    Timer(const Duration(milliseconds: 300), () => _load());
              },
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '搜索企业名称或标识',
                  isDense: true)),
          const SizedBox(height: 16),
          LayoutBuilder(builder: (context, c) {
            if (c.maxWidth < 850)
              return Column(
                  children: _rows
                      .map((q) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _mobileRow(q)))
                      .toList());
            return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: c.maxWidth),
                    child: DataTable(
                        columnSpacing: 24,
                        headingRowHeight: 44,
                        dataRowMinHeight: 66,
                        dataRowMaxHeight: 80,
                        columns: const [
                          DataColumn(label: Text('企业')),
                          DataColumn(label: Text('服务套餐')),
                          DataColumn(label: Text('消息用量')),
                          DataColumn(label: Text('AI 用量')),
                          DataColumn(label: Text('坐席')),
                          DataColumn(label: Text('服务到期')),
                          DataColumn(label: Text('操作'))
                        ],
                        rows: _rows
                            .map((q) => DataRow(cells: [
                                  DataCell(Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text('${q['name']}',
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600)),
                                        Text('${q['slug']}',
                                            style: theme.textTheme.bodySmall)
                                      ])),
                                  DataCell(Text(planLabel('${q['plan']}'))),
                                  DataCell(Text(
                                      '${quotaNumber(q['usedMessages'])} / ${quotaNumber(qi(q, 'monthlyMessageLimit') + qi(q, 'messageBonus'))}')),
                                  DataCell(Text(
                                      '${quotaNumber(q['usedAi'])} / ${quotaNumber(qi(q, 'monthlyAiLimit') + qi(q, 'aiBonus'))}')),
                                  DataCell(Text(
                                      '${q['usedSeats']} / ${q['seatLimit']}')),
                                  DataCell(Text(quotaDate(
                                      q['serviceEndsAt'] ?? q['trialEndsAt']))),
                                  DataCell(TextButton(
                                      onPressed: widget.controller.isSuperAdmin
                                          ? () => _edit(q)
                                          : null,
                                      child: Text(widget.controller.isSuperAdmin
                                          ? '分配额度'
                                          : '仅可查看')))
                                ]))
                            .toList())));
          }),
          if (_rows.isEmpty && !_loading)
            const Padding(padding: EdgeInsets.all(24), child: Text('没有匹配的企业')),
          if (_more)
            TextButton(
                onPressed: _loading ? null : () => _load(more: true),
                child: const Text('加载更多企业')),
        ])),
      ],
      if (widget.overview || widget.history) ...[
        const SizedBox(height: 20),
        _card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
                child: Text(widget.history ? '额度调整记录' : '最近额度调整',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700))),
            if (widget.overview)
              TextButton(
                  onPressed: () =>
                      widget.controller.selectSection(PlatformSection.history),
                  child: const Text('查看更多'))
          ]),
          if (_logs.isEmpty && !_loading)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('暂无额度调整记录')),
          for (final log in _logs) _log(log),
          if (widget.history && _more)
            TextButton(
                onPressed: _loading ? null : () => _load(more: true),
                child: const Text('加载更多记录'))
        ]))
      ],
      if (_error != null)
        Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!,
                style: TextStyle(color: theme.colorScheme.error))),
      if (_loading) const LinearProgressIndicator(),
    ]);
  }

  Widget _mobileRow(Map<String, dynamic> q) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${q['name']} · ${planLabel('${q['plan']}')}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        Text('${q['slug']} · 坐席 ${q['usedSeats']}/${q['seatLimit']}'),
        Text(
            '消息 ${quotaNumber(q['usedMessages'])} / ${quotaNumber(qi(q, 'monthlyMessageLimit') + qi(q, 'messageBonus'))}'),
        Text(
            'AI ${quotaNumber(q['usedAi'])} / ${quotaNumber(qi(q, 'monthlyAiLimit') + qi(q, 'aiBonus'))}'),
        Text('到期：${quotaDate(q['serviceEndsAt'] ?? q['trialEndsAt'])}'),
        if (widget.controller.isSuperAdmin)
          TextButton(onPressed: () => _edit(q), child: const Text('分配额度')),
        const Divider()
      ]);
  Widget _log(Map<String, dynamic> log) {
    final b = Map<String, dynamic>.from(log['before'] as Map),
        a = Map<String, dynamic>.from(log['after'] as Map);
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              '${log['name']} · ${log['mode'] == 'ADD' ? '一次性追加额度' : '修改每月额度'}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
              '消息：${quotaNumber(qi(b, 'monthlyMessageLimit') + qi(b, 'messageBonus'))} → ${quotaNumber(qi(a, 'monthlyMessageLimit') + qi(a, 'messageBonus'))}  ·  AI：${quotaNumber(qi(b, 'monthlyAiLimit') + qi(b, 'aiBonus'))} → ${quotaNumber(qi(a, 'monthlyAiLimit') + qi(a, 'aiBonus'))}'),
          Text(
              '坐席：${b['seatLimit']} → ${a['seatLimit']}  ·  ${planLabel('${b['plan']}')} → ${planLabel('${a['plan']}')}'),
          Text(
              '到期：${quotaDate(b['serviceEndsAt'] ?? b['trialEndsAt'])} → ${quotaDate(a['serviceEndsAt'] ?? a['trialEndsAt'])}'),
          Text(
              '状态：${billingStatusLabel('${b['status']}')} → ${billingStatusLabel('${a['status']}')}'),
          Text(
              '${log['reason']}\n操作人：${log['actor']} · ${quotaTime(log['createdAt'])}',
              style: Theme.of(context).textTheme.bodySmall),
          const Divider()
        ]));
  }
}

class ManualQuotaEditor extends StatefulWidget {
  const ManualQuotaEditor(
      {super.key,
      required this.controller,
      required this.tenantId,
      this.initialPlan});
  final PlatformController controller;
  final String tenantId;
  final String? initialPlan;
  @override
  State<ManualQuotaEditor> createState() => _ManualQuotaEditorState();
}

class _ManualQuotaEditorState extends State<ManualQuotaEditor> {
  final _form = GlobalKey<FormState>();
  final _seats = TextEditingController(),
      _messages = TextEditingController(),
      _ai = TextEditingController(),
      _extraMessages = TextEditingController(text: '0'),
      _extraAI = TextEditingController(text: '0'),
      _reason = TextEditingController();
  Map<String, dynamic>? _q;
  bool _loading = true, _saving = false, _long = true;
  String? _error;
  String _mode = 'SET', _plan = 'TRIAL', _status = 'ACTIVE';
  DateTime _start = DateTime.now();
  DateTime? _end;
  String _request = quotaRequestId();
  @override
  void initState() {
    super.initState();
    _load();
    for (final c in [_seats, _messages, _ai, _extraMessages, _extraAI]) {
      c.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [
      _seats,
      _messages,
      _ai,
      _extraMessages,
      _extraAI,
      _reason
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final q = await widget.controller.api.quota(widget.tenantId);
      if (!mounted) return;
      setState(() {
        _q = q;
        _plan = '${q['plan']}';
        _status = '${q['status']}';
        _seats.text = '${q['seatLimit']}';
        _messages.text = '${q['monthlyMessageLimit']}';
        _ai.text = '${q['monthlyAiLimit']}';
        _start = DateTime.tryParse('${q['serviceStartsAt']}')?.toLocal() ??
            DateTime.now();
        _end = DateTime.tryParse('${q['serviceEndsAt'] ?? q['trialEndsAt']}')
            ?.toLocal();
        _long = _end == null;
        _loading = false;
        _error = null;
        _request = quotaRequestId();
      });
      if (widget.initialPlan != null) _defaults(widget.initialPlan!);
    } catch (e) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = e is ApiException ? e.message : '读取额度失败';
        });
    }
  }

  void _defaults(String plan) {
    final defaults = switch (plan) {
      'STARTER' => (3, 5000, 0),
      'GROWTH' => (10, 50000, 5000),
      'ENTERPRISE' => (100, 1000000, 100000),
      _ => (2, 1000, 0)
    };
    setState(() {
      _plan = plan;
      _seats.text = '${defaults.$1}';
      _messages.text = '${defaults.$2}';
      _ai.text = '${defaults.$3}';
    });
  }

  int _number(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;
  String? _integer(String? v, {int min = 0, int max = 1000000000}) {
    final n = int.tryParse((v ?? '').trim());
    return n == null || n < min || n > max ? '请输入 $min 至 $max 的整数' : null;
  }

  Widget _field(String label, TextEditingController c,
          {int min = 0, int max = 1000000000}) =>
      TextFormField(
          controller: c,
          enabled: !_saving,
          keyboardType: TextInputType.number,
          validator: (v) => _integer(v, min: min, max: max),
          decoration: InputDecoration(labelText: label));
  Future<void> _date(bool start) async {
    final initial =
        start ? _start : _end ?? DateTime.now().add(const Duration(days: 30));
    final d = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100));
    if (d != null && mounted)
      setState(() {
        if (start) {
          _start = d;
        } else {
          _end = DateTime(d.year, d.month, d.day, 23, 59, 59);
        }
      });
  }

  Future<void> _save() async {
    if (_saving ||
        !widget.controller.isSuperAdmin ||
        !_form.currentState!.validate()) return;
    if (_mode == 'ADD' && _number(_extraMessages) + _number(_extraAI) == 0) {
      setState(() => _error = '请填写需要追加的消息或AI额度');
      return;
    }
    if (_mode == 'SET' && !_long && (_end == null || !_end!.isAfter(_start))) {
      setState(() => _error = '到期日期必须晚于生效日期');
      return;
    }
    final body = <String, dynamic>{
      'requestId': _request,
      'version': _q!['version'],
      'mode': _mode,
      'reason': _reason.text.trim(),
      if (_mode == 'SET') ...{
        'plan': _plan,
        'status': _status,
        'seatLimit': _number(_seats),
        'monthlyMessageLimit': _number(_messages),
        'monthlyAiLimit': _number(_ai),
        'serviceStartsAt': _start.toUtc().toIso8601String(),
        'serviceEndsAt': _long ? null : _end!.toUtc().toIso8601String()
      },
      if (_mode == 'ADD') ...{
        'extraMessages': _number(_extraMessages),
        'extraAi': _number(_extraAI)
      }
    };
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.api.allocateQuota(widget.tenantId, body);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('额度分配成功')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted)
        setState(() {
          _saving = false;
          _error = e is ApiException ? e.message : '保存失败，请重试';
        });
    }
  }

  Widget _card(Widget child) => Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant)),
      child: child);
  @override
  Widget build(BuildContext context) {
    final q = _q;
    final theme = Theme.of(context);
    final page = PopScope(
        canPop: !_saving,
        child: Scaffold(
            backgroundColor: theme.scaffoldBackgroundColor,
            appBar: AppBar(title: const Text('分配企业额度'), actions: [
              Padding(
                  padding: const EdgeInsets.all(14),
                  child:
                      Text(widget.controller.isSuperAdmin ? '超级管理员' : '仅可查看'))
            ]),
            bottomNavigationBar: q == null
                ? null
                : SafeArea(
                    child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 14),
                        color: theme.colorScheme.surface,
                        child: Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 24,
                            runSpacing: 12,
                            children: [
                              const Text('对企业全部客服账号生效 · 不涉及付款'),
                              Row(mainAxisSize: MainAxisSize.min, children: [
                                OutlinedButton(
                                    onPressed: _saving
                                        ? null
                                        : () => Navigator.pop(context, false),
                                    child: const Text('取消')),
                                const SizedBox(width: 12),
                                FilledButton(
                                    onPressed: _saving ||
                                            !widget.controller.isSuperAdmin
                                        ? null
                                        : _save,
                                    child: Text(_saving ? '正在保存…' : '确认分配'))
                              ])
                            ]))),
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : q == null
                    ? Center(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(_error ?? '无法读取企业额度'),
                        TextButton(onPressed: _load, child: const Text('重试'))
                      ]))
                    : Form(
                        key: _form,
                        child: SingleChildScrollView(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text('套餐与额度 / 分配额度',
                                      style: theme.textTheme.bodySmall),
                                  const SizedBox(height: 12),
                                  const Text('手动分配服务额度，保存后对企业全部客服账号生效。'),
                                  const SizedBox(height: 20),
                                  _card(Wrap(
                                      spacing: 28,
                                      runSpacing: 12,
                                      children: [
                                        Text('${q['name']}',
                                            style: const TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.w700)),
                                        Text('企业标识：${q['slug']}'),
                                        Text('负责人：${q['owner']}'),
                                        Text(
                                            '服务状态：${q['status'] == 'ACTIVE' ? '正常' : '已暂停'}')
                                      ])),
                                  const SizedBox(height: 20),
                                  LayoutBuilder(builder: (context, c) {
                                    final form = _settings();
                                    final preview = _preview(q);
                                    if (c.maxWidth < 900)
                                      return Column(children: [
                                        form,
                                        const SizedBox(height: 16),
                                        preview
                                      ]);
                                    return Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(flex: 6, child: form),
                                          const SizedBox(width: 20),
                                          Expanded(flex: 4, child: preview)
                                        ]);
                                  }),
                                  if (_error != null)
                                    Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Text(_error!,
                                            style: TextStyle(
                                                color:
                                                    theme.colorScheme.error))),
                                  Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 12),
                                      child: TextButton(
                                          onPressed: _saving ? null : _load,
                                          child: const Text('重新读取当前额度'))),
                                ])))));
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 1150) return page;
      return Material(
          child: Row(children: [
        Container(
          width: 216,
          color: const Color(0xff182334),
          padding: const EdgeInsets.fromLTRB(18, 28, 18, 20),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('语聊',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('超级管理员', style: TextStyle(color: Color(0xffa4b0c2))),
            const SizedBox(height: 36),
            for (final item in const [
              (PlatformSection.overview, '平台概览', Icons.dashboard_outlined),
              (PlatformSection.tenants, '企业与账号', Icons.business_outlined),
              (
                PlatformSection.plans,
                '套餐与额度',
                Icons.account_balance_wallet_outlined
              ),
              (PlatformSection.history, '操作记录', Icons.history),
              (PlatformSection.about, '平台设置', Icons.settings_outlined),
            ])
              Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: item.$1 == PlatformSection.plans
                          ? Colors.white
                          : const Color(0xffa4b0c2),
                      backgroundColor: item.$1 == PlatformSection.plans
                          ? const Color(0xff4263eb)
                          : Colors.transparent,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 18),
                    ),
                    onPressed: _saving
                        ? null
                        : () {
                            widget.controller.selectSection(item.$1);
                            Navigator.pop(context, false);
                          },
                    icon: Icon(item.$3, size: 19),
                    label: Text(item.$2),
                  )),
            const Spacer(),
            Text(widget.controller.operatorName,
                style: const TextStyle(color: Colors.white)),
          ]),
        ),
        Expanded(child: page),
      ]));
    });
  }

  Widget _settings() =>
      _card(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('设置额度',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 18),
        Wrap(spacing: 8, children: [
          ChoiceChip(
              label: const Text('修改每月额度'),
              selected: _mode == 'SET',
              onSelected: _saving
                  ? null
                  : (_) => setState(() {
                        _mode = 'SET';
                        _request = quotaRequestId();
                      })),
          ChoiceChip(
              label: const Text('一次性追加额度'),
              selected: _mode == 'ADD',
              onSelected: _saving
                  ? null
                  : (_) => setState(() {
                        _mode = 'ADD';
                        _request = quotaRequestId();
                      }))
        ]),
        const SizedBox(height: 12),
        Text(_mode == 'SET' ? '修改每月额度不清零本月已使用量。' : '追加额度仅在本月有效；下月恢复每月基础额度。'),
        const SizedBox(height: 24),
        if (_mode == 'SET') ...[
          DropdownButtonFormField<String>(
              value: _plan,
              decoration: const InputDecoration(labelText: '服务套餐（可自定义额度）'),
              items: ['TRIAL', 'STARTER', 'GROWTH', 'ENTERPRISE']
                  .map((p) =>
                      DropdownMenuItem(value: p, child: Text(planLabel(p))))
                  .toList(),
              onChanged: _saving ? null : (v) => _defaults(v!)),
          const SizedBox(height: 18),
          LayoutBuilder(builder: (context, c) {
            final fields = [
              _field('坐席上限', _seats, min: 1, max: 1000000),
              _field('每月消息额度', _messages, min: 1),
              _field('每月 AI 回复额度', _ai)
            ];
            if (c.maxWidth >= 540)
              return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < fields.length; i++) ...[
                      if (i > 0) const SizedBox(width: 12),
                      Expanded(child: fields[i])
                    ]
                  ]);
            return Column(children: [
              for (var i = 0; i < fields.length; i++) ...[
                if (i > 0) const SizedBox(height: 18),
                fields[i]
              ]
            ]);
          }),
          const SizedBox(height: 18),
          DropdownButtonFormField<String>(
              value: _status,
              decoration: const InputDecoration(labelText: '套餐服务状态'),
              items: const [
                DropdownMenuItem(value: 'ACTIVE', child: Text('正常服务')),
                DropdownMenuItem(value: 'PAST_DUE', child: Text('已逾期')),
                DropdownMenuItem(value: 'CANCELED', child: Text('已取消'))
              ],
              onChanged: _saving ? null : (v) => setState(() => _status = v!)),
          const SizedBox(height: 24),
          const Text('服务期限', style: TextStyle(fontWeight: FontWeight.w600)),
          Wrap(spacing: 8, children: [
            ChoiceChip(
                label: const Text('指定到期'),
                selected: !_long,
                onSelected:
                    _saving ? null : (_) => setState(() => _long = false)),
            ChoiceChip(
                label: const Text('长期有效'),
                selected: _long,
                onSelected:
                    _saving ? null : (_) => setState(() => _long = true))
          ]),
          OutlinedButton.icon(
              onPressed: _saving ? null : () => _date(true),
              icon: const Icon(Icons.calendar_today, size: 16),
              label: Text('生效日期：${quotaDate(_start.toIso8601String())}')),
          if (!_long)
            OutlinedButton.icon(
                onPressed: _saving ? null : () => _date(false),
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(
                    '到期日期：${_end == null ? '请选择' : quotaDate(_end!.toIso8601String())}')),
        ] else ...[
          _field('本月追加消息额度', _extraMessages),
          const SizedBox(height: 18),
          _field('本月追加 AI 额度', _extraAI)
        ],
        const SizedBox(height: 24),
        TextFormField(
            controller: _reason,
            enabled: !_saving,
            maxLines: 3,
            maxLength: 200,
            validator: (v) =>
                (v ?? '').trim().length < 2 ? '请填写调整原因（至少2个字符）' : null,
            decoration: const InputDecoration(
                labelText: '调整说明', hintText: '填写本次调整原因，写入操作记录')),
      ]));
  Widget _preview(Map<String, dynamic> q) {
    final add = _mode == 'ADD';
    final messages = (add ? qi(q, 'monthlyMessageLimit') : _number(_messages)) +
        qi(q, 'messageBonus') +
        (add ? _number(_extraMessages) : 0);
    final ai = (add ? qi(q, 'monthlyAiLimit') : _number(_ai)) +
        qi(q, 'aiBonus') +
        (add ? _number(_extraAI) : 0);
    final rows = [
      (
        '服务套餐',
        planLabel('${q['plan']}'),
        planLabel(add ? '${q['plan']}' : _plan)
      ),
      (
        '坐席上限',
        quotaNumber(q['seatLimit']),
        quotaNumber(add ? q['seatLimit'] : _number(_seats))
      ),
      (
        '本月消息总额度',
        quotaNumber(qi(q, 'monthlyMessageLimit') + qi(q, 'messageBonus')),
        quotaNumber(messages)
      ),
      (
        '本月 AI 总额度',
        quotaNumber(qi(q, 'monthlyAiLimit') + qi(q, 'aiBonus')),
        quotaNumber(ai)
      ),
      (
        '到期日期',
        quotaDate(q['serviceEndsAt'] ?? q['trialEndsAt']),
        add
            ? quotaDate(q['serviceEndsAt'] ?? q['trialEndsAt'])
            : _long
                ? '长期有效'
                : _end == null
                    ? '请选择'
                    : quotaDate(_end!.toIso8601String())
      )
    ];
    return _card(
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('调整前后对比',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 20),
      const Row(children: [
        Expanded(flex: 2, child: Text('项目')),
        Expanded(child: Text('调整前')),
        Expanded(child: Text('调整后'))
      ]),
      const Divider(),
      for (final row in rows)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 2, child: Text(row.$1)),
              Expanded(child: Text(row.$2)),
              Expanded(
                  child: Text(row.$3,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600)))
            ])),
      const Divider(),
      Text(
          '本月消息已使用：${quotaNumber(q['usedMessages'])}\n调整后剩余：${quotaNumber(max(0, messages - qi(q, 'usedMessages')))}\n本月 AI 已使用：${quotaNumber(q['usedAi'])}\n调整后 AI 剩余：${quotaNumber(max(0, ai - qi(q, 'usedAi')))}',
          style: const TextStyle(height: 2)),
      const SizedBox(height: 20),
      const Text('仅超级管理员可分配\n本次调整将记录操作者、时间与调整原因。',
          style: TextStyle(height: 1.8)),
      if (messages < qi(q, 'usedMessages') || ai < qi(q, 'usedAi'))
        const Text('新额度低于已使用量，保存后将暂停对应发送或AI能力。',
            style: TextStyle(color: Colors.orange)),
    ]));
  }
}
