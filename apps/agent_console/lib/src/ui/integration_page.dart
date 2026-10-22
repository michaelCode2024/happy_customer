import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/ui/console_form_dialog.dart';
import 'package:tongyu_agent_console/src/util/channel_preview_stub.dart'
    if (dart.library.html) 'package:tongyu_agent_console/src/util/channel_preview_web.dart';
import 'package:tongyu_agent_console/src/ui/workspace_layout.dart';
import 'package:tongyu_agent_console/src/ui/error_banner.dart';

import 'package:tongyu_agent_console/src/api/api_exception.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';

class IntegrationPage extends StatefulWidget {
  const IntegrationPage({
    super.key,
    required this.api,
    this.canIdentity = false,
  });

  final TongYuApi api;

  /// 企业版才开 visitor-identity；旗舰及以下只展示升级说明，避免指引与接口 403 脱节。
  final bool canIdentity;

  @override
  State<IntegrationPage> createState() => _IntegrationPageState();
}

class _IntegrationPageState extends State<IntegrationPage> {
  int _tab = 0;
  int _selectedChannel = 0;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _inboxes = [];
  List<Map<String, dynamic>> _keys = [];
  List<Map<String, dynamic>> _hooks = [];
  List<String> _events = [];
  String? _selectedInbox;
  Map<String, dynamic>? _snippet;
  String? _snippetError;
  bool _canIdentity = false;

  /// 专业版及以上可走 member-token 进群，不必等企业版 identity。
  bool _canGroups = false;

  @override
  void initState() {
    super.initState();
    _canIdentity = widget.canIdentity;
    _load();
  }

  @override
  void didUpdateWidget(covariant IntegrationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.canIdentity != widget.canIdentity) {
      _canIdentity = widget.canIdentity;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entitlements = await widget.api.entitlements();
      final features = Map<String, dynamic>.from(
          entitlements['features'] as Map? ?? const {});
      final inboxes = await widget.api.integrationInboxes();
      final keys = await widget.api.integrationKeys();
      final hooks = await widget.api.integrationWebhooks();
      if (!mounted) return;
      _canIdentity = features['identity'] == true || widget.canIdentity;
      _canGroups = features['groups'] == true;
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
    await copyToClipboard(context, value, '内容');
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

  Future<void> _createHook([Map<String, dynamic>? hook]) async {
    var url = asString(hook?['url']);
    final selected = <String>{
      ...((hook?['events'] as List<dynamic>?) ?? []).map((e) => '$e')
    };
    var busy = false;
    String? error;
    String? secret;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, update) => ConsoleFormDialog(
                title: hook == null ? '新增事件回调' : '编辑事件回调',
                description: '实时同步消息、已读与送达。正式接入推荐使用 HTTPS。',
                busy: busy,
                error: error,
                submitLabel: hook == null ? '创建' : '保存',
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextFormField(
                      initialValue: url,
                      onChanged: (value) => url = value.trim(),
                      decoration: const InputDecoration(
                          labelText: '回调地址',
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
                            })),
                ]),
                onSubmit: () async {
                  final parsed = Uri.tryParse(url);
                  if (parsed == null ||
                      !['http', 'https'].contains(parsed.scheme) ||
                      parsed.host.isEmpty ||
                      selected.isEmpty) {
                    update(() => error = '请填写有效的 HTTP/HTTPS 地址并选择至少一个事件');
                    return;
                  }
                  update(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    if (hook == null) {
                      final created = await widget.api
                          .createIntegrationWebhook(url, selected.toList());
                      secret = asString(created['secret']);
                    } else {
                      await widget.api.adminWrite(
                          'PATCH',
                          'webhooks/${asString(hook['id'])}',
                          {'url': url, 'events': selected.toList()});
                    }
                    if (dialogContext.mounted)
                      Navigator.pop(dialogContext, true);
                  } on ApiException catch (e) {
                    if (dialogContext.mounted)
                      update(() {
                        busy = false;
                        error = e.message;
                      });
                  } catch (_) {
                    if (dialogContext.mounted)
                      update(() {
                        busy = false;
                        error = '暂时无法保存，请稍后重试';
                      });
                  }
                },
              )),
    );
    if (saved != true || !mounted) return;
    if (secret != null) {
      await _showSecret('回调签名密钥', secret!);
    } else {
      _notice('回调配置已保存');
    }
    await _load();
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
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        WorkspacePageHeader(
            title: '接入管理',
            description: '连接你的网站、H5 与 App，让客户随时找到你',
            icon: Icons.link_rounded,
            actions: [
              OutlinedButton.icon(
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('刷新'))
            ]),
        WorkspaceTabs(
            labels: const ['接入渠道', '接入指南', '服务端密钥', '事件回调'],
            selectedIndex: const [0, 3, 1, 2].indexOf(_tab),
            onSelected: (index) =>
                setState(() => _tab = const [0, 3, 1, 2][index])),
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
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                        children: [
                          WorkspaceCard(
                            padding:
                                const EdgeInsets.fromLTRB(18, 16, 18, 18),
                            child: switch (_tab) {
                              0 => _inboxTab(theme),
                              1 => _keyTab(theme),
                              3 => _guide(theme),
                              _ => _hookTab(theme)
                            },
                          ),
                        ])),
      ]),
    );
  }

  Widget _guide(ThemeData theme) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('接入指南', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        const Text('请先在「企业管理」里建好客服入口并分配成员，再复制安装代码。成员上线后即可接待；无人在线时消息会进待接待。'),
        const SizedBox(height: 24),
        Text('1. 安装匿名聊天（所有套餐）', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('打开「接入入口」，复制网页安装代码或 iframe。inboxKey 可放在前端；匿名客户不需要业务账号。'),
        const SizedBox(height: 24),
        Text('2. 关联你系统里的已登录客户', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_canIdentity) ...[
          const Text(
              '企业版可用。在「服务端密钥」创建写入权限 APIKey，保存在你的后端。后端从登录会话读取客户 ID，申请 5 分钟身份票据；不要让浏览器自行指定客户 ID。'),
          const SizedBox(height: 12),
          _copyRow('后端申请客户身份票据',
              '''POST ${widget.api.server}/api/v1/open/visitor-identity
X-TongYu-Key: <仅保存在你的后端的 APIKey>
Content-Type: application/json

{"inboxKey":"<客服入口公钥>","externalId":"<当前登录客户ID>","displayName":"<客户昵称>"}'''),
          _copyRow(
              '你的前端加载组件', '''// /api/customer-chat-identity 由你的后端实现，并校验当前客户登录状态。
const identity = await fetch('/api/customer-chat-identity').then(r => r.json());
window.TongYuSettings = {
  endpoint: '${widget.api.server}',
  inboxKey: identity.inboxKey,
  identityToken: identity.identityToken
};
const script = document.createElement('script');
script.src = '${widget.api.server}/widget.js';
document.head.appendChild(script);'''),
          const SizedBox(height: 12),
          Text('3. 用你的用户进服务群', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
              '客服建好「客户服务群」后，你的后端可用 APIKey 按 externalId 批量加人，再签发 identityToken 打开群页：'),
          const SizedBox(height: 12),
          _copyRow('按用户 ID 加入服务群',
              '''POST ${widget.api.server}/api/v1/open/groups/<groupId>/members
X-TongYu-Key: <APIKey>
{"members":[{"externalId":"<客户ID>","displayName":"<昵称>"}]}'''),
          _copyRow('打开已入群用户的群页',
              '''${widget.api.server}/groups.html?groupId=<groupId>&identityToken=<identityToken>'''),
        ] else if (_canGroups) ...[
          // 旗舰/专业版：群聊与 open members 已开，但没有 identityToken；用 member-token 对齐开放 API。
          const Text(
              '当前套餐已支持服务群与开放 API 加人，但不含「登录客户身份票据」。私聊组件仍用匿名接入；要把你们系统的用户 ID 进服务群，请走下方 member-token（企业版才可签发 identityToken）。'),
          const SizedBox(height: 12),
          _copyRow('按用户 ID 加入服务群',
              '''POST ${widget.api.server}/api/v1/open/groups/<groupId>/members
X-TongYu-Key: <仅保存在你的后端的 APIKey>
{"members":[{"externalId":"<客户ID>","displayName":"<昵称>"}]}'''),
          _copyRow('签发群会话并打开群页', '''// 你的后端校验本站登录后调用：
// POST /api/v1/open/groups/<groupId>/member-token
// {"externalId":"<客户ID>"} → { token, visitorId, groupId }
const groupId = '<groupId>';
const session = await fetch('/api/customer-group-session', {
  method: 'POST', body: JSON.stringify({ groupId })
}).then(r => r.json());
sessionStorage.setItem(
  'tongyu-group-' + groupId,
  JSON.stringify({
    token: session.token,
    groupId,
    actorId: session.visitorId,
    actorKind: 'widget'
  })
);
location.href = '${widget.api.server}/groups.html?groupId=' + encodeURIComponent(groupId);'''),
        ] else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer.withOpacity(0.45),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: const Text(
              '当前套餐未开通群聊与登录客户身份。匿名聊天与事件回调仍可用；需要宿主用户进群或身份票据时，请联系平台升级套餐。',
            ),
          ),
        const SizedBox(height: 24),
        Text('各种凭证分别用在哪里', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text('企业标识 + 用户名 + 密码：团队成员登录后台。\n'
            'inboxKey：前端安装组件时标识客服入口。\n'
            'APIKey：你的服务器调用开放 API，不能放入网页或 App。\n'
            '${_canIdentity ? 'identityToken：短期客户身份票据（企业版）。\n' : ''}'
            '${_canGroups && !_canIdentity ? 'member-token：已入群用户的群聊会话（专业版及以上）。\n' : ''}'
            '访客 Token：组件自动管理。'),
        const SizedBox(height: 24),
        Text('消息没有收到时', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text(
            '先看「客户消息 → 全部 / 待接待」，确认成员已分配到该入口、账号启用并在线。断线后会自动重同步。APIKey 不能替坐席登录。'),
      ]);

  Widget _inboxTab(ThemeData theme) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('客服入口',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (_inboxes.isEmpty)
          const Text('暂无客服入口，请到「企业管理 → 客服入口」创建。')
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
            _channelGrid(theme),
            // iframe 是网站内嵌的另一种方式，不应混入 H5 和 App 的接入说明。
            if (_selectedChannel == 0 &&
                asString(_snippet!['iframeHtml']).isNotEmpty)
              _copyRow('网站内嵌 iframe 片段（可选）', asString(_snippet!['iframeHtml'])),
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

  Widget _channelGrid(ThemeData theme) {
    final script = asString(_snippet!['script']);
    final h5 = asString(_snippet!['iframe']);
    // 兼容旧接口未返回 appUrl 的情况，仍保留 App 会话来源。
    final h5Uri = Uri.tryParse(h5);
    final app = asString(_snippet!['appUrl']).isNotEmpty
        ? asString(_snippet!['appUrl'])
        : h5.isEmpty || h5Uri == null
            ? ''
            : h5Uri.replace(queryParameters: {
                ...h5Uri.queryParameters,
                'source': 'APP',
              }).toString();
    final channels = [
      ('网站组件', '将聊天窗口嵌入你的网站', Icons.language_outlined, script, h5),
      ('H5 链接', '发送链接，即可发起在线咨询', Icons.link_rounded, h5, h5),
      ('App WebView', '在 App 中打开客服页面', Icons.phone_android_outlined, app, app),
    ];
    final current = channels[_selectedChannel], scheme = theme.colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 20),
      Text('选择接入方式', style: theme.textTheme.titleSmall),
      const SizedBox(height: 6),
      Text('选择渠道后，查看对应的接入内容并预览效果。',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant)),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (context, box) {
        final columns = box.maxWidth >= 780
            ? 3
            : box.maxWidth >= 480
                ? 2
                : 1;
        return Wrap(spacing: 12, runSpacing: 12, children: [
          for (var i = 0; i < channels.length; i++)
            SizedBox(
                width: (box.maxWidth - 12 * (columns - 1)) / columns,
                child: Semantics(
                    button: true,
                    selected: i == _selectedChannel,
                    child: Material(
                        color: i == _selectedChannel
                            ? scheme.primaryContainer.withOpacity(0.45)
                            : scheme.surface,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide(
                                color: i == _selectedChannel
                                    ? scheme.primary
                                    : scheme.outlineVariant)),
                        child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => setState(() => _selectedChannel = i),
                            child: Padding(
                                padding: const EdgeInsets.all(18),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(children: [
                                        Icon(channels[i].$3,
                                            color: scheme.primary, size: 26),
                                        const Spacer(),
                                        if (i == _selectedChannel)
                                          Icon(Icons.check_circle,
                                              color: scheme.primary, size: 18)
                                      ]),
                                      const SizedBox(height: 14),
                                      Text(channels[i].$1,
                                          style: theme.textTheme.titleSmall),
                                      const SizedBox(height: 6),
                                      Text(channels[i].$2,
                                          style: theme.textTheme.bodySmall),
                                      const SizedBox(height: 12),
                                      Text(
                                          channels[i].$4.isEmpty
                                              ? '暂无接入内容'
                                              : '接入内容已就绪',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: channels[i].$4.isEmpty
                                                  ? scheme.outline
                                                  : const Color(0xFF31977C))),
                                    ]))))))
        ]);
      }),
      const SizedBox(height: 24),
      Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(16)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 24,
                runSpacing: 12,
                children: [
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '${current.$1} · ${_selectedChannel == 0 ? '安装代码' : '访问链接'}',
                            style: theme.textTheme.titleSmall),
                        const SizedBox(height: 6),
                        Text(
                            _selectedChannel == 0
                                ? '将以下代码添加到网站页面，由组件管理访客会话。'
                                : _selectedChannel == 1
                                    ? '复制链接用于 H5 页面跳转或分享，客户打开后即可咨询。'
                                    : '在 App 的 WebView 中加载以下链接，source=APP 用于标识 App 会话来源。',
                            style: theme.textTheme.bodySmall),
                      ]),
                  Wrap(spacing: 8, children: [
                    OutlinedButton.icon(
                        onPressed:
                            current.$4.isEmpty ? null : () => _copy(current.$4),
                        icon: const Icon(Icons.copy_outlined, size: 16),
                        label: Text(_selectedChannel == 0 ? '复制安装代码' : '复制链接')),
                    FilledButton.icon(
                        onPressed: current.$5.isEmpty
                            ? null
                            : () {
                                if (!openChannelPreview(current.$5))
                                  _notice('请在网页版打开渠道预览');
                              },
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('预览效果')),
                  ]),
                ]),
            const SizedBox(height: 16),
            Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10)),
                child: SelectableText(
                    current.$4.isEmpty ? '当前入口暂未提供该渠道的接入内容。' : current.$4,
                    style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.7,
                        color: scheme.onSurface))),
            const SizedBox(height: 12),
            Text('入口标识可以用于前端接入，服务端密钥仅供你的服务器使用。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ])),
    ]);
  }

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
                    if (action == 'edit') {
                      await _createHook(hook);
                    } else if (action == 'toggle') {
                      try {
                        await widget.api.adminWrite('PATCH', 'webhooks/$id', {
                          'status': asString(hook['status']) == 'ACTIVE'
                              ? 'DISABLED'
                              : 'ACTIVE'
                        });
                        if (mounted) await _load();
                      } on ApiException catch (e) {
                        if (mounted) _notice(e.message);
                      }
                    } else if (action == 'history') {
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
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'edit', child: Text('编辑回调')),
                    PopupMenuItem(
                        value: 'toggle',
                        child: Text(asString(hook['status']) == 'ACTIVE'
                            ? '停用回调'
                            : '启用回调')),
                    const PopupMenuItem(value: 'test', child: Text('发送测试事件')),
                    const PopupMenuItem(
                        value: 'history', child: Text('查看投递记录')),
                    const PopupMenuItem(value: 'delete', child: Text('删除回调')),
                  ],
                )),
      ]);

  Widget _copyRow(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600))),
            TextButton.icon(
                onPressed: () => _copy(value),
                icon: const Icon(Icons.copy_rounded, size: 14),
                label: const Text('复制', style: TextStyle(fontSize: 11.5))),
          ]),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: SelectableText(value,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 11.5, height: 1.55)),
          ),
        ],
      ));
  }

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
                                subtitle:
                                    Text('${switch (asString(item['status'])) {
                                  'SUCCEEDED' => '投递成功',
                                  'FAILED' => '投递失败',
                                  'PENDING' => '等待投递',
                                  'PROCESSING' => '正在投递',
                                  _ => asString(item['status'])
                                }} · 已投递 ${asInt(item['attempts'])} 次'),
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
