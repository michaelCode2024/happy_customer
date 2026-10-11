import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:relaydesk_agent_console/src/api/api_exception.dart';
import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';

class IntegrationPage extends StatefulWidget {
  const IntegrationPage({super.key, required this.api});

  final RelayDeskApi api;

  @override
  State<IntegrationPage> createState() => _IntegrationPageState();
}

class _IntegrationPageState extends State<IntegrationPage> {
  int _tab = 0;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _inboxes = [];
  List<Map<String, dynamic>> _keys = [];
  List<Map<String, dynamic>> _hooks = [];
  List<String> _events = [];
  String? _selectedInbox;
  Map<String, dynamic>? _snippet;
  String? _snippetError;

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
      final inboxes = await widget.api.integrationInboxes();
      final keys = await widget.api.integrationKeys();
      final hooks = await widget.api.integrationWebhooks();
      if (!mounted) return;
      final selected = inboxes.any((e) => asString(e['id']) == _selectedInbox)
          ? _selectedInbox
          : (inboxes.isEmpty ? null : asString(inboxes.first['id']));
      final snippet =
          selected == null ? null : await widget.api.inboxSnippet(selected);
      if (!mounted) return;
      setState(() {
        _inboxes = inboxes;
        _keys = keys;
        _hooks = asMapList(hooks['items']);
        _events = (hooks['availableEvents'] as List<dynamic>? ?? [])
            .whereType<String>()
            .toList();
        _selectedInbox = selected;
        _snippet = snippet;
        _snippetError = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _notice(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) _notice('已复制');
  }

  Future<void> _selectInbox(String id) async {
    setState(() {
      _selectedInbox = id;
      _snippet = null;
      _snippetError = null;
    });
    try {
      final snippet = await widget.api.inboxSnippet(id);
      if (mounted && _selectedInbox == id) setState(() => _snippet = snippet);
    } on ApiException catch (e) {
      if (mounted && _selectedInbox == id) {
        setState(() => _snippetError = e.message);
      }
    }
  }

  Future<void> _createKey() async {
    var name = '';
    var write = false;
    final selection = await showDialog<(String, bool)>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
                title: const Text('创建服务端密钥'),
                content: SizedBox(
                    width: 380,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          autofocus: true,
                          onChanged: (value) =>
                              update(() => name = value.trim()),
                          decoration: const InputDecoration(labelText: '密钥名称')),
                      const SizedBox(height: 12),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: write,
                        onChanged: (value) =>
                            update(() => write = value ?? false),
                        title: const Text('允许写入'),
                        subtitle: const Text('创建会话、发送消息及更新会话'),
                      ),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: name.isEmpty
                          ? null
                          : () => Navigator.pop(context, (name, write)),
                      child: const Text('创建'))
                ],
              )),
    );
    if (selection == null || !mounted) return;
    try {
      final result = await widget.api.createIntegrationKey(
          selection.$1, ['read', if (selection.$2) 'write']);
      if (!mounted) return;
      await _showSecret('服务端密钥', asString(result['key']));
      await _load();
    } on ApiException catch (e) {
      if (mounted) _notice(e.message);
    }
  }

  Future<void> _showSecret(String title, String secret) => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SizedBox(
              width: 420,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('仅此一次显示，请保存在服务端。关闭后无法再次查看。'),
                    const SizedBox(height: 16),
                    SelectableText(secret,
                        style: const TextStyle(fontFamily: 'monospace')),
                  ])),
          actions: [
            TextButton.icon(
                onPressed: () => _copy(secret),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('复制')),
            FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('完成'))
          ],
        ),
      );

  Future<void> _createHook() async {
    var url = '';
    final selected = <String>{};
    final result = await showDialog<(String, List<String>)>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: const Text('新增事件回调'),
                  content: SizedBox(
                      width: 420,
                      child: SingleChildScrollView(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        TextField(
                            onChanged: (value) => url = value.trim(),
                            decoration: const InputDecoration(
                                labelText: 'HTTPS 回调地址',
                                hintText: 'https://example.com/webhook')),
                        const SizedBox(height: 12),
                        for (final event in _events)
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(event),
                            value: selected.contains(event),
                            onChanged: (value) => update(() {
                              if (value == true) {
                                selected.add(event);
                              } else {
                                selected.remove(event);
                              }
                            }),
                          ),
                      ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () =>
                            Navigator.pop(context, (url, selected.toList())),
                        child: const Text('创建'))
                  ],
                )));
    if (result == null || !mounted) return;
    if (!result.$1.startsWith('https://') || result.$2.isEmpty) {
      _notice('请填写 HTTPS 地址并选择至少一个事件');
      return;
    }
    try {
      final created =
          await widget.api.createIntegrationWebhook(result.$1, result.$2);
      if (!mounted) return;
      await _showSecret('回调签名密钥', asString(created['secret']));
      await _load();
    } on ApiException catch (e) {
      if (mounted) _notice(e.message);
    }
  }

  Future<void> _confirmDelete(
      String title, Future<void> Function() action) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(title),
              content: const Text('此操作会立即生效，确认继续？'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('确认'))
              ],
            ));
    if (ok != true) return;
    try {
      await action();
      await _load();
    } on ApiException catch (e) {
      if (mounted) _notice(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('开发接入'), actions: [
        IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh))
      ]),
      body: Column(children: [
        Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SegmentedButton<int>(
                      showSelectedIcon: false,
                      selected: {_tab},
                      onSelectionChanged: (value) =>
                          setState(() => _tab = value.first),
                      segments: const [
                        ButtonSegment(
                            value: 0,
                            label: Text('接入入口'),
                            icon: Icon(Icons.apps_outlined)),
                        ButtonSegment(
                            value: 1,
                            label: Text('服务端密钥'),
                            icon: Icon(Icons.key_outlined)),
                        ButtonSegment(
                            value: 2,
                            label: Text('事件回调'),
                            icon: Icon(Icons.webhook_outlined))
                      ],
                    )))),
        const Divider(height: 16),
        Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(_error!),
                        TextButton(onPressed: _load, child: const Text('重试'))
                      ]))
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
                        children: [
                            Center(
                                child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 900),
                                    child: switch (_tab) {
                                      0 => _inboxTab(theme),
                                      1 => _keyTab(theme),
                                      _ => _hookTab(theme),
                                    })),
                          ])),
      ]),
    );
  }

  Widget _inboxTab(ThemeData theme) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('接入入口',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (_inboxes.isEmpty)
          const Text('暂无客服入口，请联系平台管理员开通企业入口。')
        else ...[
          DropdownButtonFormField<String>(
              value: _selectedInbox,
              decoration: const InputDecoration(labelText: '选择客服入口'),
              items: [
                for (final item in _inboxes)
                  DropdownMenuItem(
                      value: asString(item['id']),
                      child: Text(asString(item['name'])))
              ],
              onChanged: (id) {
                if (id != null) _selectInbox(id);
              }),
          const SizedBox(height: 20),
          if (_snippetError != null)
            Text(_snippetError!,
                style: TextStyle(color: theme.colorScheme.error))
          else if (_snippet == null)
            const LinearProgressIndicator()
          else ...[
            _copyRow('入口公钥', asString(_snippet!['inboxKey'])),
            _copyRow('网页安装代码', asString(_snippet!['script'])),
            _copyRow('H5 / iframe 地址', asString(_snippet!['iframe'])),
            if (asString(_snippet!['iframeHtml']).isNotEmpty)
              _copyRow('业务系统 iframe 片段', asString(_snippet!['iframeHtml'])),
            if (asString(_snippet!['openApiBase']).isNotEmpty)
              _copyRow('开放 API 根路径', asString(_snippet!['openApiBase'])),
          ],
        ],
      ]);

  Widget _keyTab(ThemeData theme) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('服务端密钥', style: theme.textTheme.titleMedium)),
          FilledButton.icon(
              onPressed: _createKey,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('创建密钥'))
        ]),
        const SizedBox(height: 12),
        if (_keys.isEmpty)
          const Text('暂无密钥')
        else
          for (final key in _keys)
            ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(asString(key['name'])),
                subtitle: Text(
                    '${asString(key['keyPrefix'])} · ${asString(key['status']) == 'ACTIVE' ? '使用中' : '已撤销'} · ${(key['scopes'] as List<dynamic>? ?? []).map((scope) => scope == 'read' ? '读取' : scope == 'write' ? '写入' : '管理').join('、')} · ${asInt(key['requestCount'])} 次调用'),
                trailing: asString(key['status']) == 'ACTIVE'
                    ? IconButton(
                        tooltip: '撤销密钥',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _confirmDelete(
                            '撤销密钥',
                            () => widget.api
                                .revokeIntegrationKey(asString(key['id']))))
                    : null),
      ]);

  Widget _hookTab(ThemeData theme) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('事件回调', style: theme.textTheme.titleMedium)),
          FilledButton.icon(
              onPressed: _createHook,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新增回调'))
        ]),
        const SizedBox(height: 12),
        if (_hooks.isEmpty)
          const Text('暂无回调地址')
        else
          for (final hook in _hooks)
            ListTile(
                contentPadding: EdgeInsets.zero,
                isThreeLine: true,
                title: Text(asString(hook['url']),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    '${asString(hook['status']) == 'ACTIVE' ? '运行中' : '已停用'} · ${(hook['events'] as List<dynamic>? ?? []).join('、')}\n失败 ${asInt(hook['failedDeliveries'])} 次',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                trailing: PopupMenuButton<String>(
                  tooltip: '回调操作',
                  onSelected: (action) async {
                    final id = asString(hook['id']);
                    if (action == 'history') {
                      await _deliveries(id);
                    } else if (action == 'delete') {
                      await _confirmDelete('删除回调',
                          () => widget.api.deleteIntegrationWebhook(id));
                    } else {
                      try {
                        await widget.api.testIntegrationWebhook(id);
                        if (mounted) _notice('测试事件已入队');
                      } on ApiException catch (e) {
                        if (mounted) _notice(e.message);
                      }
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'test', child: Text('发送测试事件')),
                    PopupMenuItem(value: 'history', child: Text('查看投递记录')),
                    PopupMenuItem(value: 'delete', child: Text('删除回调')),
                  ],
                )),
      ]);

  Widget _copyRow(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
                child: SelectableText(value,
                    maxLines: 3,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12))),
            IconButton(
                tooltip: '复制$label',
                icon: const Icon(Icons.copy_outlined),
                onPressed: () => _copy(value))
          ]),
          const Divider(),
        ],
      ));

  Future<void> _deliveries(String id) async {
    try {
      final items = await widget.api.webhookDeliveries(id);
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('投递记录'),
                content: SizedBox(
                    width: 520,
                    height: 360,
                    child: items.isEmpty
                        ? const Center(child: Text('暂无投递记录'))
                        : ListView(children: [
                            for (final item in items)
                              ListTile(
                                title: Text(asString(item['eventType'])),
                                subtitle: Text(
                                    '${asString(item['status'])} · 重试 ${asInt(item['attempts'])} 次'),
                                trailing: Text(item['responseStatus'] == null
                                    ? '—'
                                    : '${item['responseStatus']}'),
                              )
                          ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'))
                ],
              ));
    } on ApiException catch (e) {
      if (mounted) _notice(e.message);
    }
  }
}
