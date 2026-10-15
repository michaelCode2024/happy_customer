import 'package:relaydesk_agent_console/src/ui/workspace_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/api/models.dart';

/// 每个渠道拥有独立配置，切换前明确处理未保存内容，避免写入错误入口。
class AutomationPage extends StatefulWidget {
  const AutomationPage({super.key, required this.api, this.channels = false});
  final RelayDeskApi api;
  final bool channels;
  @override
  State<AutomationPage> createState() => _AutomationPageState();
}

class _AutomationPageState extends State<AutomationPage> {
  List<Map<String, dynamic>> _inboxes = [], _agents = [], _messages = [];
  Map<String, dynamic> _config = {}, _snippet = {};
  String? _inbox, _error;
  int _revision = 0, _tab = 0;
  bool _loading = true, _saving = false, _dirty = false;
  final Map<String, TextEditingController> _fields = {};
  static const _automationTabs = [
    '关键词回复',
    '打开客服回复',
    '收到消息回复',
    '系统客服回复',
    '智能引语',
    '智能引流',
    '智能菜单',
    '转人工客服',
    '自动回复设置'
  ];
  static const _channelTabs = [
    'H5 / App 渠道设置',
    '渠道客服',
    '快捷方式',
    '图文模板',
    '自定义菜单',
    '用户消息列表'
  ];
  List<String> get _tabs => widget.channels ? _channelTabs : _automationTabs;
  @override
  void initState() {
    super.initState();
    _loadInboxes();
  }

  @override
  void didUpdateWidget(covariant AutomationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channels != widget.channels) {
      // 模块有不同的子菜单，不能复用上一个模块的选中索引。
      _tab = 0;
    }
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadInboxes() async {
    try {
      final items = await widget.api.integrationInboxes();
      if (!mounted) return;
      _inboxes = items;
      if (items.isEmpty) {
        setState(() {
          _loading = false;
          _error = '请先在「同事账号 → 客服入口」创建入口';
        });
        return;
      }
      await _load(asString(items.first['id']));
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
                    title: const Text('有尚未保存的修改'),
                    content: const Text('切换入口后会放弃这些修改。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('继续编辑')),
                      FilledButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('放弃并切换'))
                    ])) ??
        false;
  }

  Future<void> _load(String id) async {
    if (_saving || !await _confirmDiscard()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.api.adminGet('inboxes/$id/automation');
      final snippet = await widget.api.inboxSnippet(id);
      final agents = asMapList((await widget.api.adminGet('agents'))['items']);
      if (!mounted) return;
      for (final c in _fields.values) {
        c.dispose();
      }
      _fields.clear();
      setState(() {
        _inbox = id;
        _config = Map.of(asMap(result['config']));
        _revision = (result['revision'] as num?)?.toInt() ?? 0;
        _snippet = snippet;
        _agents = agents;
        _dirty = false;
        _loading = false;
      });
      if (widget.channels && _tab == 5) await _loadMessages();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _save() async {
    if (_saving || _inbox == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await widget.api.adminWrite(
          'PUT',
          'inboxes/$_inbox/automation',
          {'config': _config, 'revision': _revision});
      if (!mounted) return;
      setState(() {
        _revision = (result['revision'] as num).toInt();
        _dirty = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已保存，新的访客会话立即使用此配置')));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _loadMessages() async {
    try {
      final result = await widget.api.adminGet('inboxes/$_inbox/conversations');
      if (mounted) setState(() => _messages = asMapList(result['items']));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _change(String key, dynamic value) {
    setState(() {
      _config[key] = value;
      _dirty = true;
    });
  }

  Widget _field(String key, String label,
      {String? hint, int lines = 3, bool list = false}) {
    final controller = _fields.putIfAbsent(
        key,
        () => TextEditingController(
            text: list
                ? ((_config[key] as List?) ?? []).join('\n')
                : asString(_config[key])));
    return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: TextField(
            controller: controller,
            minLines: lines,
            maxLines: lines + 2,
            decoration: InputDecoration(
                labelText: label,
                helperText: hint,
                alignLabelWithHint: true,
                border: const OutlineInputBorder()),
            onChanged: (s) => _change(
                key,
                list
                    ? s
                        .split('\n')
                        .map((s) => s.trim())
                        .where((s) => s.isNotEmpty)
                        .toList()
                    : s)));
  }

  Widget _description(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: Colors.blueGrey)));
  List<Map<String, dynamic>> _items(String key) => asMapList(_config[key])
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
  Widget _replyPage(String key, String label, String help) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_description(help), _field(key, label, hint: '留空表示不启用该场景')]);
  Widget _editor() {
    if (widget.channels) {
      switch (_tab) {
        case 0:
          return _channelSettings();
        case 1:
          return _channelAgents();
        case 2:
          return _itemList('quickLinks', '快捷方式',
              help: '显示在输入框上方，可发送预设问题、打开页面或联系人工。');
        case 3:
          return _itemList('cards', '图文模板',
              cards: true, help: '在新会话展示带图片和说明的服务卡片，支持回复、跳转和转人工。');
        case 4:
          return _itemList('menuItems', '自定义菜单',
              help: '所有菜单由服务端校验动作，共用于网页、H5 和 App。');
        default:
          return _messageList();
      }
    }
    switch (_tab) {
      case 0:
        return _keywordList();
      case 1:
        return _replyPage('openReply', '欢迎语', '访客打开聊天窗口、尚未发送消息时展示。不会反复产生历史消息。');
      case 2:
        return _replyPage(
            'receivedReply', '收到消息后的回复', '未匹配关键词时自动回复；默认在人工接管后停止，回复间隔可在设置中调整。');
      case 3:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _description(
              '系统客服处理无人在线和普通兜底两个场景。优先顺序：转人工 → 关键词 → 离线回复 → 收到消息回复 → 系统兜底。'),
          _field('offlineReply', '无人在线时的回复'),
          _field('systemReply', '系统兜底回复')
        ]);
      case 4:
        return Column(children: [
          _description('欢迎页显示常见问题，访客点击后直接发起咨询，并使用同一套关键词规则。'),
          _field('guideText', '引导标题', lines: 1),
          _field('guideQuestions', '常见问题', list: true, hint: '每行一个问题，最多 12 个')
        ]);
      case 5:
        return _itemList('diversionLinks', '智能引流',
            help: '为不同服务提供入口。跳转只支持 http/https 地址，避免不安全链接。');
      case 6:
        return _itemList('menuItems', '智能菜单',
            help: '与渠道的自定义菜单共用同一份数据，支持回复、链接和转人工。');
      case 7:
        return Column(children: [
          _description('触发后停止机器人回复，并保留原有客服分配结果；未分配会话进入客服待接队列。'),
          _field('handoffKeywords', '转人工关键词', list: true, hint: '每行一个关键词，包含匹配'),
          _field('handoffMessage', '转人工提示')
        ]);
      default:
        return Column(children: [
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用自动回复'),
              subtitle: const Text('关闭后关键词和自动兜底停止，自定义菜单仍可使用'),
              value: _config['enabled'] == true,
              onChanged: (v) => _change('enabled', v)),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('人工接管后停止自动回复'),
              subtitle: const Text('推荐开启，避免客服和机器人同时回复'),
              value: _config['respectAgent'] != false,
              onChanged: (v) => _change('respectAgent', v)),
          const SizedBox(height: 20),
          TextFormField(
              key: ValueKey('cooldown-$_inbox'),
              initialValue: '${_config['cooldownSeconds'] ?? 10}',
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: '自动回复间隔（秒）',
                  helperText: '0–3600 秒；转人工不受此限制',
                  border: OutlineInputBorder()),
              onChanged: (v) =>
                  _change('cooldownSeconds', int.tryParse(v) ?? -1))
        ]);
    }
  }

  Widget _keywordList() {
    final rules = _items('keywordRules');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _description('优先级高的规则先匹配；相同优先级按列表顺序。匹配不区分英文大小写。'),
      Wrap(spacing: 12, children: [
        FilledButton.icon(
            onPressed: () => _editRule(),
            icon: const Icon(Icons.add),
            label: const Text('新增关键词规则')),
        OutlinedButton.icon(
            onPressed: () => _previewRules(),
            icon: const Icon(Icons.play_arrow),
            label: const Text('匹配预览'))
      ]),
      const SizedBox(height: 20),
      if (rules.isEmpty)
        const Padding(
            padding: EdgeInsets.all(32), child: Text('还没有规则，添加后可自动回答常见问题。')),
      for (final rule in rules)
        Card(
            child: ListTile(
                leading: Switch(
                    value: rule['enabled'] == true,
                    onChanged: (v) {
                      rule['enabled'] = v;
                      _change('keywordRules', rules);
                    }),
                title: Text(asString(rule['title'])),
                subtitle: Text(
                    '${(rule['keywords'] as List? ?? []).join('、')} · ${rule['matchMode'] == 'EXACT' ? '完全匹配' : '包含匹配'} · 优先级 ${rule['priority']}\n${rule['reply']}'),
                isThreeLine: true,
                onTap: () => _editRule(rule),
                trailing: IconButton(
                    tooltip: '删除规则',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      rules.removeWhere((r) => r['id'] == rule['id']);
                      _change('keywordRules', rules);
                    })))
    ]);
  }

  Future<void> _editRule([Map<String, dynamic>? existing]) async {
    final title = TextEditingController(text: asString(existing?['title']));
    final words = TextEditingController(
        text: ((existing?['keywords'] as List?) ?? []).join('\n'));
    final reply = TextEditingController(text: asString(existing?['reply']));
    final priority =
        TextEditingController(text: '${existing?['priority'] ?? 0}');
    var mode = asString(existing?['matchMode']);
    if (mode.isEmpty) mode = 'CONTAINS';
    String? error;
    final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, set) => AlertDialog(
                    title: Text(existing == null ? '新增关键词规则' : '编辑关键词规则'),
                    content: SizedBox(
                        width: 500,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              TextField(
                                  controller: title,
                                  decoration:
                                      const InputDecoration(labelText: '规则名称')),
                              TextField(
                                  controller: words,
                                  minLines: 2,
                                  maxLines: 4,
                                  decoration: const InputDecoration(
                                      labelText: '关键词，每行一个')),
                              DropdownButtonFormField<String>(
                                  value: mode,
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'CONTAINS', child: Text('包含匹配')),
                                    DropdownMenuItem(
                                        value: 'EXACT', child: Text('完全匹配'))
                                  ],
                                  onChanged: (v) => set(() => mode = v!),
                                  decoration:
                                      const InputDecoration(labelText: '匹配方式')),
                              TextField(
                                  controller: reply,
                                  minLines: 3,
                                  maxLines: 6,
                                  decoration:
                                      const InputDecoration(labelText: '回复内容')),
                              TextField(
                                  controller: priority,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                      labelText: '优先级，越大越优先')),
                              if (error != null)
                                Text(error!,
                                    style: const TextStyle(color: Colors.red))
                            ]))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () {
                            if (title.text.trim().isEmpty ||
                                words.text.trim().isEmpty ||
                                reply.text.trim().isEmpty ||
                                int.tryParse(priority.text) == null) {
                              set(() => error = '请填写名称、关键词、回复和整数优先级');
                              return;
                            }
                            Navigator.pop(ctx, <String, dynamic>{
                              'id': existing?['id'] ??
                                  'rule-${DateTime.now().microsecondsSinceEpoch}',
                              'title': title.text.trim(),
                              'keywords': words.text
                                  .split('\n')
                                  .map((s) => s.trim())
                                  .where((s) => s.isNotEmpty)
                                  .toList(),
                              'matchMode': mode,
                              'reply': reply.text.trim(),
                              'priority': int.parse(priority.text),
                              'enabled': existing?['enabled'] ?? true
                            });
                          },
                          child: const Text('确定'))
                    ])));
    if (result != null && mounted) {
      final rules = _items('keywordRules');
      final i = rules.indexWhere((r) => r['id'] == result['id']);
      if (i < 0) {
        rules.add(result);
      } else {
        rules[i] = result;
      }
      _change('keywordRules', rules);
    }
    // Dialog 路由退出动画仍可能访问控制器，在下一帧之后再释放。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    title.dispose();
    words.dispose();
    reply.dispose();
    priority.dispose();
  }

  Future<void> _previewRules() async {
    final text = TextEditingController();
    String output = '输入一条访客消息，查看当前草稿的关键词匹配结果。';
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, set) => AlertDialog(
                    title: const Text('关键词匹配预览'),
                    content: SizedBox(
                        width: 480,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          TextField(
                              controller: text,
                              decoration:
                                  const InputDecoration(labelText: '访客消息')),
                          const SizedBox(height: 20),
                          Text(output)
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('关闭')),
                      FilledButton(
                          onPressed: () {
                            final rules = _items('keywordRules')
                              ..sort((a, b) => (b['priority'] as num)
                                  .compareTo(a['priority'] as num));
                            final value = text.text.trim().toLowerCase();
                            Map<String, dynamic>? hit;
                            for (final r in rules) {
                              if (r['enabled'] != true) continue;
                              final words =
                                  (r['keywords'] as List).cast<String>();
                              if (words.any((k) => r['matchMode'] == 'EXACT'
                                  ? value == k.trim().toLowerCase()
                                  : value.contains(k.trim().toLowerCase()))) {
                                hit = r;
                                break;
                              }
                            }
                            set(() => output = hit == null
                                ? '没有命中关键词。实际发送时还会检查人工状态、回复间隔与兜底配置。'
                                : '命中「${hit['title']}」\n${hit['reply']}');
                          },
                          child: const Text('预览'))
                    ])));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    text.dispose();
  }

  Widget _itemList(String key, String label,
      {bool cards = false, String help = ''}) {
    final items = _items(key);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _description(help),
      FilledButton.icon(
          onPressed: () => _editItem(key, cards: cards),
          icon: const Icon(Icons.add),
          label: Text('新增$label')),
      const SizedBox(height: 20),
      if (items.isEmpty)
        const Padding(padding: EdgeInsets.all(32), child: Text('还没有配置内容')),
      for (final item in items)
        Card(
            child: ListTile(
                leading: Icon(item['action'] == 'HANDOFF'
                    ? Icons.support_agent
                    : item['action'] == 'LINK'
                        ? Icons.open_in_new
                        : Icons.chat_bubble_outline),
                title: Text(asString(item['title'])),
                subtitle: Text(
                    '${item['action'] == 'HANDOFF' ? '转人工' : item['action'] == 'LINK' ? '跳转链接' : '自动回复'} · ${item['value'] ?? ''}${cards ? '\n${item['description'] ?? ''}' : ''}'),
                onTap: () => _editItem(key, cards: cards, existing: item),
                trailing: IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      items.removeWhere((r) => r['id'] == item['id']);
                      _change(key, items);
                    })))
    ]);
  }

  Future<void> _editItem(String key,
      {bool cards = false, Map<String, dynamic>? existing}) async {
    final title = TextEditingController(text: asString(existing?['title'])),
        value = TextEditingController(text: asString(existing?['value'])),
        description =
            TextEditingController(text: asString(existing?['description'])),
        image = TextEditingController(text: asString(existing?['imageUrl']));
    var action = asString(existing?['action']);
    if (action.isEmpty) action = 'REPLY';
    String? error;
    final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, set) => AlertDialog(
                    title: Text(existing == null ? '新增服务入口' : '编辑服务入口'),
                    content: SizedBox(
                        width: 500,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              TextField(
                                  controller: title,
                                  decoration:
                                      const InputDecoration(labelText: '标题')),
                              if (cards) ...[
                                TextField(
                                    controller: description,
                                    minLines: 2,
                                    maxLines: 4,
                                    decoration: const InputDecoration(
                                        labelText: '卡片说明')),
                                TextField(
                                    controller: image,
                                    decoration: const InputDecoration(
                                        labelText: '图片地址（http/https，可选）'))
                              ],
                              DropdownButtonFormField<String>(
                                  value: action,
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'REPLY', child: Text('回复内容')),
                                    DropdownMenuItem(
                                        value: 'LINK', child: Text('打开链接')),
                                    DropdownMenuItem(
                                        value: 'HANDOFF', child: Text('转人工客服'))
                                  ],
                                  onChanged: (v) => set(() => action = v!),
                                  decoration:
                                      const InputDecoration(labelText: '点击动作')),
                              if (action != 'HANDOFF')
                                TextField(
                                    controller: value,
                                    minLines: 2,
                                    maxLines: 4,
                                    decoration: InputDecoration(
                                        labelText: action == 'LINK'
                                            ? '链接地址'
                                            : '回复内容')),
                              if (error != null)
                                Text(error!,
                                    style: const TextStyle(color: Colors.red))
                            ]))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () {
                            final uri = Uri.tryParse(value.text.trim());
                            final img = Uri.tryParse(image.text.trim());
                            if (title.text.trim().isEmpty ||
                                (action != 'HANDOFF' &&
                                    value.text.trim().isEmpty) ||
                                (action == 'LINK' &&
                                    (uri == null ||
                                        !['http', 'https']
                                            .contains(uri.scheme) ||
                                        uri.host.isEmpty)) ||
                                (image.text.isNotEmpty &&
                                    (img == null ||
                                        !['http', 'https']
                                            .contains(img.scheme) ||
                                        img.host.isEmpty))) {
                              set(() =>
                                  error = '请填写标题和内容，链接与图片必须使用 http/https 地址');
                              return;
                            }
                            Navigator.pop(ctx, <String, dynamic>{
                              'id': existing?['id'] ??
                                  '$key-${DateTime.now().microsecondsSinceEpoch}',
                              'title': title.text.trim(),
                              'description': description.text.trim(),
                              'imageUrl': image.text.trim(),
                              'action': action,
                              'value': value.text.trim()
                            });
                          },
                          child: const Text('确定'))
                    ])));
    if (result != null && mounted) {
      final items = _items(key);
      final i = items.indexWhere((r) => r['id'] == result['id']);
      if (i < 0) {
        items.add(result);
      } else {
        items[i] = result;
      }
      _change(key, items);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    title.dispose();
    value.dispose();
    description.dispose();
    image.dispose();
  }

  Widget _channelSettings() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _description('网页嵌入、H5 链接和 App WebView 共用一个客服入口，配置和历史消息保持一致。'),
        _field('channelTitle', '聊天窗口名称', lines: 1),
        _field('channelSubtitle', '服务说明', lines: 1),
        for (final pair in [
          ('H5 访问地址', 'iframe'),
          ('App WebView 地址', 'appUrl'),
          ('网页嵌入代码', 'script')
        ])
          Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Expanded(
                                  child: Text(pair.$1,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall)),
                              IconButton(
                                  tooltip: '复制',
                                  icon: const Icon(Icons.copy),
                                  onPressed: () async {
                                    await Clipboard.setData(ClipboardData(
                                        text: asString(_snippet[pair.$2])));
                                    if (mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(const SnackBar(
                                              content: Text('已复制')));
                                    }
                                  })
                            ]),
                            SelectableText(asString(_snippet[pair.$2]))
                          ])))),
        _description(
            'App 使用上述 H5 地址加载 WebView。登录用户身份由业务后端签发短期身份凭证；企业 API 密钥仅放在服务器端，详细对接说明在「应用接入」。')
      ]);
  Widget _channelAgents() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _description('选择可以接待此渠道的客服，立即保存成员关联；机器人转人工时沿用该入口的分配规则。'),
        for (final agent in _agents)
          CheckboxListTile(
              value: ((agent['inboxIds'] as List?) ?? []).contains(_inbox),
              title: Text(asString(agent['displayName'])),
              subtitle: Text(
                  '${agent['email']} · ${agent['presence'] == 'ONLINE' ? '在线' : '离线'}'),
              onChanged: _saving
                  ? null
                  : (v) async {
                      final ids =
                          List<String>.from((agent['inboxIds'] as List?) ?? []);
                      if (v == true) {
                        ids.add(_inbox!);
                      } else {
                        ids.remove(_inbox);
                      }
                      setState(() => _saving = true);
                      try {
                        await widget.api.adminWrite('PUT',
                            'agents/${agent['id']}/inboxes', {'inboxIds': ids});
                        if (mounted) setState(() => agent['inboxIds'] = ids);
                      } catch (e) {
                        if (mounted) setState(() => _error = '$e');
                      } finally {
                        if (mounted) setState(() => _saving = false);
                      }
                    })
      ]);
  Future<void> _viewMessages(Map<String, dynamic> conversation) async {
    await showDialog<void>(
        context: context,
        builder: (ctx) => _ChannelMessagesDialog(
            api: widget.api,
            inboxId: _inbox!,
            conversationId: asString(conversation['id']),
            visitorName: asString(conversation['visitorName'])));
  }

  Widget _messageList() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: _description(
                  '当前入口最近的 100 个会话，包括已结束会话。点击会话查看历史，接待与回复请进入消息工作台。')),
          IconButton(
              tooltip: '刷新会话',
              onPressed: _loadMessages,
              icon: const Icon(Icons.refresh))
        ]),
        if (_messages.isEmpty)
          const Padding(padding: EdgeInsets.all(32), child: Text('此渠道还没有访客会话')),
        for (final m in _messages)
          Card(
              child: ListTile(
                  leading: const Icon(Icons.person_outline),
                  onTap: () => _viewMessages(m),
                  trailing: const Icon(Icons.chevron_right),
                  title: Text(asString(m['visitorName']).isEmpty
                      ? '访客'
                      : asString(m['visitorName'])),
                  subtitle: Text(
                      '${m['lastMessagePreview'] ?? ''}\n${m['source']} · ${asString(m['assigneeName']).isEmpty ? '待分配' : asString(m['assigneeName'])} · ${m['status'] == 'RESOLVED' ? '已结束' : '进行中'}'),
                  isThreeLine: true))
      ]);
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 780;
        return Scaffold(
            appBar: WorkspaceAppBar(
                title: widget.channels ? '渠道管理' : '自动回复',
                description: '按客服入口配置接待规则与 AI 应答边界',
                icon: Icons.auto_awesome_outlined,
                actions: [
                  TextButton.icon(
                      onPressed: _loading || _saving ? null : _save,
                      icon: Icon(_dirty ? Icons.save_outlined : Icons.check),
                      label: Text(_saving
                          ? '保存中…'
                          : _dirty
                              ? '保存修改'
                              : '已保存')),
                  IconButton(
                      tooltip: '刷新配置',
                      onPressed: _loading || _saving || _inbox == null
                          ? null
                          : () => _load(_inbox!),
                      icon: const Icon(Icons.refresh))
                ]),
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : Column(children: [
                    Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 12),
                        child: DropdownButtonFormField<String>(
                            value: _inbox,
                            isExpanded: true,
                            decoration: const InputDecoration(
                                labelText: '客服入口',
                                border: OutlineInputBorder(),
                                isDense: true),
                            items: [
                              for (final i in _inboxes)
                                DropdownMenuItem(
                                    value: asString(i['id']),
                                    child: Text(asString(i['name'])))
                            ],
                            onChanged: _saving
                                ? null
                                : (v) {
                                    if (v != null) _load(v);
                                  })),
                    if (_error != null)
                      Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 8),
                          child: Text(_error!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error))),
                    if (!widget.channels && _config['enabled'] != true)
                      const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 24),
                          child: Row(children: [
                            Icon(Icons.info_outline,
                                size: 18, color: Colors.blueGrey),
                            SizedBox(width: 8),
                            Expanded(
                                child: Text('自动回复尚未开启，配置完成后在「自动回复设置」启用。',
                                    style: TextStyle(color: Colors.blueGrey)))
                          ])),
                    const SizedBox(height: 12),
                    Expanded(
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          if (wide)
                            SizedBox(
                                width: 184,
                                child: ListView(children: [
                                  for (var i = 0; i < _tabs.length; i++)
                                    ListTile(
                                        selected: _tab == i,
                                        selectedTileColor: Theme.of(context)
                                            .colorScheme
                                            .primaryContainer,
                                        title: Text(_tabs[i]),
                                        onTap: () {
                                          setState(() => _tab = i);
                                          if (widget.channels && i == 5) {
                                            _loadMessages();
                                          }
                                        })
                                ])),
                          Expanded(
                              child: Column(children: [
                            if (!wide)
                              SizedBox(
                                  height: 48,
                                  child: ListView(
                                      scrollDirection: Axis.horizontal,
                                      children: [
                                        for (var i = 0; i < _tabs.length; i++)
                                          Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 4),
                                              child: ChoiceChip(
                                                  label: Text(_tabs[i]),
                                                  selected: _tab == i,
                                                  onSelected: (_) {
                                                    setState(() => _tab = i);
                                                    if (widget.channels &&
                                                        i == 5) _loadMessages();
                                                  }))
                                      ])),
                            Expanded(
                                child: SingleChildScrollView(
                                    padding: const EdgeInsets.all(24),
                                    child: Align(
                                        alignment: Alignment.topLeft,
                                        child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                                maxWidth: 1080),
                                            child: Container(
                                                width: double.infinity,
                                                padding:
                                                    const EdgeInsets.all(24),
                                                decoration: BoxDecoration(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .surface,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            8),
                                                    border: Border.all(
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .outlineVariant)),
                                                child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(_tabs[_tab],
                                                          style:
                                                              Theme.of(context)
                                                                  .textTheme
                                                                  .titleLarge),
                                                      const SizedBox(
                                                          height: 24),
                                                      _editor()
                                                    ]))))))
                          ]))
                        ]))
                  ]));
      });
}

class _ChannelMessagesDialog extends StatefulWidget {
  const _ChannelMessagesDialog(
      {required this.api,
      required this.inboxId,
      required this.conversationId,
      required this.visitorName});
  final RelayDeskApi api;
  final String inboxId, conversationId, visitorName;
  @override
  State<_ChannelMessagesDialog> createState() => _ChannelMessagesDialogState();
}

class _ChannelMessagesDialogState extends State<_ChannelMessagesDialog> {
  final List<ChatMessage> _messages = [];
  bool _loading = false, _more = true;
  int _cursor = 0;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.api.channelMessages(
          widget.inboxId, widget.conversationId,
          after: _cursor);
      if (!mounted) return;
      setState(() {
        final ids = _messages.map((m) => m.id).toSet();
        _messages.addAll(page.items.where((m) => !ids.contains(m.id)));
        _cursor = page.lastSequence;
        _more = page.hasMore;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(
              '${widget.visitorName.trim().isEmpty ? '访客' : widget.visitorName}的消息'),
          content: SizedBox(
              width: 650,
              height: 500,
              child: Column(children: [
                if (_error != null)
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                Expanded(
                    child: ListView(children: [
                  for (final m in _messages)
                    ListTile(
                        title: Text(m.deletedAt != null
                            ? '消息已撤回'
                            : m.content.isNotEmpty
                                ? m.content
                                : '[${m.messageType}]'),
                        subtitle: Text(
                            '${m.senderType == 'VISITOR' ? '访客' : m.senderName.isEmpty ? '客服助手' : m.senderName}${m.isPrivate ? ' · 内部备注' : ''} · ${m.createdAt}')),
                  if (_loading)
                    const Padding(
                        padding: EdgeInsets.all(20),
                        child: Center(child: CircularProgressIndicator())),
                  if (!_loading && _messages.isEmpty && _error == null)
                    const Text('还没有消息')
                ])),
                if (!_loading && (_more || _error != null))
                  TextButton(
                      onPressed: _load,
                      child: Text(_error == null ? '加载更多消息' : '重试'))
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'))
          ]);
}
