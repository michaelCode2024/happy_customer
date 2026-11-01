import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/theme.dart';
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
                    SelectableText(secret, style: RelayTheme.codeText()),
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
                    // 不再用一张大卡把整页内容裹起来：内容直接落在画布上，
                    // 靠区块小标题和留白分层，值块用白底浮起。这样整页只有
                    // 一种「表面」，读起来是文档而不是表单堆。
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 48),
                        children: [
                            Align(
                              alignment: Alignment.topLeft,
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 860),
                                child: switch (_tab) {
                                  0 => _inboxTab(theme),
                                  1 => _keyTab(theme),
                                  3 => _guide(theme),
                                  _ => _hookTab(theme)
                                },
                              ),
                            ),
                          ])),
      ]),
    );
  }

  Widget _guide(ThemeData theme) {
    final scheme = theme.colorScheme;
    Widget step(String text) => Padding(
          padding: const EdgeInsets.only(top: 22, bottom: 8),
          child: Text(text,
              style:
                  RelayTheme.uiText(fontSize: 13, fontWeight: FontWeight.w600)),
        );
    Widget body(String text) => Text(text,
        style: RelayTheme.uiText(
            fontSize: 12, height: 1.8, color: scheme.onSurfaceVariant));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionLabel('接入指南'),
      body('请先在「企业管理」里建好客服入口并分配成员，再复制安装代码。成员上线后即可接待；无人在线时消息会进待接待。'),
      step('1. 安装匿名聊天（所有套餐）'),
      body('打开「接入入口」，复制网页安装代码或 iframe。inboxKey 可放在前端；匿名客户不需要业务账号。'),
      step('2. 关联你系统里的已登录客户'),
      if (_canIdentity) ...[
        body(
            '企业版可用。在「服务端密钥」创建写入权限 APIKey，保存在你的后端。后端从登录会话读取客户 ID，申请 5 分钟身份票据；不要让浏览器自行指定客户 ID。'),
        const SizedBox(height: 12),
        _valueCard('后端申请客户身份票据',
            '''POST ${widget.api.server}/api/v1/open/visitor-identity
X-TongYu-Key: <仅保存在你的后端的 APIKey>
Content-Type: application/json

{"inboxKey":"<客服入口公钥>","externalId":"<当前登录客户ID>","displayName":"<客户昵称>"}'''),
        _valueCard(
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
        step('3. 用你的用户进服务群'),
        body(
            '客服建好「客户服务群」后，你的后端可用 APIKey 按 externalId 批量加人，再签发 identityToken 打开群页：'),
        const SizedBox(height: 12),
        _valueCard('按用户 ID 加入服务群',
            '''POST ${widget.api.server}/api/v1/open/groups/<groupId>/members
X-TongYu-Key: <APIKey>
{"members":[{"externalId":"<客户ID>","displayName":"<昵称>"}]}'''),
        _valueCard('打开已入群用户的群页',
            '''${widget.api.server}/groups.html?groupId=<groupId>&identityToken=<identityToken>'''),
      ] else if (_canGroups) ...[
        // 旗舰/专业版：群聊与 open members 已开，但没有 identityToken；用 member-token 对齐开放 API。
        body(
            '当前套餐已支持服务群与开放 API 加人，但不含「登录客户身份票据」。私聊组件仍用匿名接入；要把你们系统的用户 ID 进服务群，请走下方 member-token（企业版才可签发 identityToken）。'),
        const SizedBox(height: 12),
        _valueCard('按用户 ID 加入服务群',
            '''POST ${widget.api.server}/api/v1/open/groups/<groupId>/members
X-TongYu-Key: <仅保存在你的后端的 APIKey>
{"members":[{"externalId":"<客户ID>","displayName":"<昵称>"}]}'''),
        _valueCard('签发群会话并打开群页', '''// 你的后端校验本站登录后调用：
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
            color: scheme.surface,
            borderRadius: BorderRadius.circular(RelayTheme.radiusMd),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Text(
            '当前套餐未开通群聊与登录客户身份。匿名聊天与事件回调仍可用；需要宿主用户进群或身份票据时，请联系平台升级套餐。',
            style: RelayTheme.uiText(
                fontSize: 12, height: 1.8, color: scheme.onSurfaceVariant),
          ),
        ),
      step('各种凭证分别用在哪里'),
      body('企业标识 + 用户名 + 密码：团队成员登录后台。\n'
          'inboxKey：前端安装组件时标识客服入口。\n'
          'APIKey：你的服务器调用开放 API，不能放入网页或 App。\n'
          '${_canIdentity ? 'identityToken：短期客户身份票据（企业版）。\n' : ''}'
          '${_canGroups && !_canIdentity ? 'member-token：已入群用户的群聊会话（专业版及以上）。\n' : ''}'
          '访客 Token：组件自动管理。'),
      step('消息没有收到时'),
      body('先看「客户消息 → 全部 / 待接待」，确认成员已分配到该入口、账号启用并在线。断线后会自动重同步。APIKey 不能替坐席登录。'),
    ]);
  }

  Widget _inboxTab(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionLabel('客服入口'),
      if (_inboxes.isEmpty)
        _emptyHint('暂无客服入口，请到「企业管理 → 客服入口」创建。')
      else ...[
        DropdownButtonFormField<String>(
            value: _selectedInbox,
            isExpanded: true,
            decoration: const InputDecoration(hintText: '选择客服入口'),
            items: [
              for (final item in _inboxes)
                DropdownMenuItem(
                    value: asString(item['id']),
                    child: Text(asString(item['name'])))
            ],
            onChanged: (id) {
              if (id != null) _selectInbox(id);
            }),
        const SizedBox(height: 12),
        if (_snippetError != null)
          Text(_snippetError!, style: TextStyle(color: scheme.error))
        else if (_snippet == null)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: LinearProgressIndicator())
        else ...[
          _valueCard('入口公钥', asString(_snippet!['inboxKey'])),
          const SizedBox(height: 22),
          _channelSection(theme),
          const SizedBox(height: 22),
          _contentSection(theme),
          const SizedBox(height: 18),
          // iframe 是网站内嵌的另一种方式，不应混入 H5 和 App 的接入说明。
          if (_selectedChannel == 0 &&
              asString(_snippet!['iframeHtml']).isNotEmpty)
            _valueCard('网站内嵌 iframe 片段（可选）', asString(_snippet!['iframeHtml'])),
          if (asString(_snippet!['openApiBase']).isNotEmpty)
            _valueCard('开放 API 根路径', asString(_snippet!['openApiBase'])),
        ],
      ],
    ]);
  }

  Widget _keyTab(ThemeData theme) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionLabel('服务端密钥',
            trailing: FilledButton.icon(
                onPressed: _createKey,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('创建密钥'))),
        if (_keys.isEmpty)
          _emptyHint('暂无密钥')
        else
          _listCard([
            for (final key in _keys)
              ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  title: Text(asString(key['name']),
                      style: RelayTheme.uiText(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                      '${asString(key['keyPrefix'])} · ${asString(key['status']) == 'ACTIVE' ? '使用中' : '已撤销'} · ${(key['scopes'] as List<dynamic>? ?? []).map((scope) => scope == 'read' ? '读取' : scope == 'write' ? '写入' : '管理').join('、')} · ${asInt(key['requestCount'])} 次调用',
                      style: RelayTheme.codeText(
                          fontSize: 11.5,
                          color: theme.colorScheme.onSurfaceVariant)),
                  trailing: asString(key['status']) == 'ACTIVE'
                      ? IconButton(
                          tooltip: '撤销密钥',
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () => _confirmDelete(
                              '撤销密钥',
                              () => widget.api
                                  .revokeIntegrationKey(asString(key['id']))))
                      : null),
          ]),
      ]);

  List<_Channel> _channels() {
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
    return [
      _Channel('网站组件', '将聊天窗口嵌入你的网站', Icons.language_rounded, script, h5),
      _Channel('H5 链接', '发送链接，即可发起在线咨询', Icons.link_rounded, h5, h5),
      _Channel('App WebView', '在 App 中打开客服页面', Icons.phone_android_rounded, app,
          app),
    ];
  }

  Widget _channelSection(ThemeData theme) {
    final scheme = theme.colorScheme;
    final channels = _channels();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionLabel('接入方式'),
      Text('选中渠道后，下方展示对应的接入内容。',
          style: RelayTheme.uiText(
              fontSize: 11.5, height: 1.5, color: scheme.onSurfaceVariant)),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, box) {
        final columns = box.maxWidth >= 720
            ? 3
            : box.maxWidth >= 460
                ? 2
                : 1;
        final width = (box.maxWidth - 10 * (columns - 1)) / columns;
        return Wrap(spacing: 10, runSpacing: 10, children: [
          for (var i = 0; i < channels.length; i++)
            SizedBox(width: width, child: _channelTile(theme, channels[i], i)),
        ]);
      }),
    ]);
  }

  /// 渠道卡：未选中只有一条发丝描边，选中才给出主色描边 + 主色标题。
  /// 三张卡等高，勾换成右上角的小对号，不再单独占一行撑高卡片。
  Widget _channelTile(ThemeData theme, _Channel channel, int index) {
    final scheme = theme.colorScheme;
    final selected = index == _selectedChannel;
    final radius = BorderRadius.circular(RelayTheme.radiusLg);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 1.5 : 1),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: () => setState(() => _selectedChannel = index),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(15, 13, 15, 15),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 78),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(channel.icon,
                          size: 19,
                          color: selected
                              ? scheme.primary
                              : scheme.onSurfaceVariant),
                      const Spacer(),
                      if (selected)
                        Icon(Icons.check_rounded,
                            size: 15, color: scheme.primary)
                    ]),
                    const SizedBox(height: 10),
                    Text(channel.title,
                        style: RelayTheme.uiText(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color:
                                selected ? scheme.primary : scheme.onSurface)),
                    const SizedBox(height: 3),
                    Text(channel.description,
                        style: RelayTheme.uiText(
                            fontSize: 11.5,
                            height: 1.5,
                            color: scheme.onSurfaceVariant)),
                    if (channel.content.isEmpty) ...[
                      const SizedBox(height: 6),
                      Text('暂无接入内容',
                          style: RelayTheme.uiText(
                              fontSize: 11, color: scheme.outline)),
                    ],
                  ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _contentSection(ThemeData theme) {
    final scheme = theme.colorScheme;
    final current = _channels()[_selectedChannel];
    final isScript = _selectedChannel == 0;
    final description = isScript
        ? '将以下代码添加到网站页面，由组件管理访客会话。'
        : _selectedChannel == 1
            ? '复制链接用于 H5 页面跳转或分享，客户打开后即可咨询。'
            : '在 App 的 WebView 中加载以下链接，source=APP 用于标识 App 会话来源。';
    final actions = <Widget>[
      OutlinedButton.icon(
          onPressed:
              current.content.isEmpty ? null : () => _copy(current.content),
          icon: const Icon(Icons.copy_rounded, size: 15),
          label: Text(isScript ? '复制安装代码' : '复制链接')),
      FilledButton.icon(
          onPressed: current.preview.isEmpty
              ? null
              : () {
                  if (!openChannelPreview(current.preview))
                    _notice('请在网页版打开渠道预览');
                },
          icon: const Icon(Icons.open_in_new, size: 15),
          label: const Text('预览效果')),
    ];
    final heading = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${current.title} · ${isScript ? '安装代码' : '访问链接'}',
              style: RelayTheme.uiText(
                  fontSize: 13.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          Text(description,
              style: RelayTheme.uiText(
                  fontSize: 11.5, height: 1.5, color: scheme.onSurfaceVariant)),
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionLabel('接入内容'),
      LayoutBuilder(builder: (context, box) {
        if (box.maxWidth < 540) {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading,
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: heading),
          const SizedBox(width: 16),
          Wrap(spacing: 8, children: actions),
        ]);
      }),
      const SizedBox(height: 12),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(RelayTheme.radiusMd),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: SelectableText(
            current.content.isEmpty ? '当前入口暂未提供该渠道的接入内容。' : current.content,
            style: RelayTheme.codeText(
                fontSize: 12, height: 1.75, color: scheme.onSurface)),
      ),
      const SizedBox(height: 10),
      Text('入口标识可以用于前端接入，服务端密钥仅供你的服务器使用。',
          style: RelayTheme.uiText(
              fontSize: 11, height: 1.5, color: scheme.onSurfaceVariant)),
    ]);
  }

  Widget _hookTab(ThemeData theme) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionLabel('事件回调',
            trailing: FilledButton.icon(
                onPressed: _createHook,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新增回调'))),
        if (_hooks.isEmpty)
          _emptyHint('暂无回调地址')
        else
          _listCard([
            for (final hook in _hooks)
              ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  isThreeLine: true,
                  title: Text(asString(hook['url']),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RelayTheme.codeText(
                          fontSize: 12.5, color: theme.colorScheme.onSurface)),
                  subtitle: Text(
                      '${asString(hook['status']) == 'ACTIVE' ? '运行中' : '已停用'} · ${(hook['events'] as List<dynamic>? ?? []).join('、')}\n失败 ${asInt(hook['failedDeliveries'])} 次',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: RelayTheme.uiText(
                          fontSize: 11.5,
                          height: 1.5,
                          color: theme.colorScheme.onSurfaceVariant)),
                  trailing: PopupMenuButton<String>(
                    tooltip: '回调操作',
                    icon: const Icon(Icons.more_horiz, size: 18),
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
          ]),
      ]);

  /// 值块：标签 + 等宽值 + 内联复制，三者收在同一个表面里。
  ///
  /// 旧版把标签、值、复制按钮拆成三行三段，读起来像文档目录；现在把它们
  /// 压成一块白卡，复制按钮落在标签行右端，值的左边缘始终对齐。
  Widget _valueCard(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(RelayTheme.radiusMd),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(label,
                  style: RelayTheme.uiText(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant))),
          _copyAction(value),
        ]),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: SelectableText(value,
              style: RelayTheme.codeText(
                  fontSize: 12.5, height: 1.6, color: scheme.onSurface)),
        ),
      ]),
    );
  }

  Widget _copyAction(String value) => TextButton.icon(
        onPressed: () => _copy(value),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 26),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: const Icon(Icons.copy_rounded, size: 13),
        label: Text('复制', style: RelayTheme.uiText(fontSize: 11.5)),
      );

  /// 区块小标题：小字号 + 字距，靠位置和留白分层，不靠加粗和色块。
  Widget _sectionLabel(String text, {Widget? trailing}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Expanded(
            child: Text(text,
                style: RelayTheme.uiText(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant)
                    .copyWith(letterSpacing: 1))),
        if (trailing != null) trailing,
      ]),
    );
  }

  /// 列表行统一收进一张白卡，用极淡的分隔线切分，避免每行各占一块。
  Widget _listCard(List<Widget> rows) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(RelayTheme.radiusMd),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0)
            Divider(
                height: 1,
                thickness: 1,
                color: scheme.outlineVariant.withOpacity(0.6)),
          rows[i],
        ]
      ]),
    );
  }

  Widget _emptyHint(String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(RelayTheme.radiusMd),
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Text(text,
            style: RelayTheme.uiText(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

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

/// 一个接入渠道的展示信息：标题、说明、图标，以及要复制的内容和要预览的地址。
class _Channel {
  const _Channel(
      this.title, this.description, this.icon, this.content, this.preview);

  final String title;
  final String description;
  final IconData icon;
  final String content;
  final String preview;
}
