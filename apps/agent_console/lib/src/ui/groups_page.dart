import 'dart:async';
import 'dart:convert';
import '../util/message_alert_stub.dart'
    if (dart.library.html) '../util/message_alert_web.dart';
import 'package:relaydesk_agent_console/src/util/group_window_stub.dart'
    if (dart.library.html) 'package:relaydesk_agent_console/src/util/group_window_web.dart';
import 'package:flutter/material.dart';
import 'package:relaydesk_agent_console/src/ui/create_group_dialog.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:relaydesk_agent_console/src/state/session_controller.dart';

class GroupsPage extends StatefulWidget {
  const GroupsPage({super.key, required this.session});
  final SessionController session;
  @override
  State<GroupsPage> createState() => _GroupsPageState();
}

class _GroupsPageState extends State<GroupsPage> {
  List<Map<String, dynamic>> groups = [], messages = [], members = [];
  String? selected, error;
  String? pendingContent, pendingId;
  bool sending = false, loading = false;
  int generation = 0;
  final threadScroll = ScrollController();
  final draft = TextEditingController(), search = TextEditingController();
  WebSocketChannel? socket;
  StreamSubscription<dynamic>? subscription;
  Timer? reconnect, debounce;
  Map<String, dynamic>? get group {
    for (final g in groups) {
      if (g['id'] == selected) return g;
    }
    return null;
  }

  bool get owner => group?['ownerId'] == widget.session.agent?.id;
  @override
  void initState() {
    super.initState();
    refresh();
    connect();
  }

  void connect() {
    if (!mounted) return;
    final uri = Uri.parse(widget.session.api.server).replace(
        scheme: widget.session.api.server.startsWith('https') ? 'wss' : 'ws',
        path: '/ws/groups',
        queryParameters: {'token': widget.session.api.token});
    socket = WebSocketChannel.connect(uri);
    subscription = socket!.stream.listen(
        (event) {
          try {
            final e = jsonDecode(event as String);
            if (e['type'] == 'group.updated') {
              refresh();
            }
          } catch (_) {}
        },
        onError: (Object e) {},
        onDone: () {
          reconnect = Timer(const Duration(seconds: 3), connect);
          refresh();
        });
  }

  @override
  void dispose() {
    generation++;
    reconnect?.cancel();
    debounce?.cancel();
    subscription?.cancel();
    socket?.sink.close();
    threadScroll.dispose();
    draft.dispose();
    search.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final data = await widget.session.api.groupRequest('GET', '');
      if (!mounted) return;
      setState(
          () => groups = (data['items'] as List).cast<Map<String, dynamic>>());
      if (selected != null) await load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> load() async {
    final id = selected;
    if (id == null) return;
    final gen = ++generation;
    final atBottom = !threadScroll.hasClients || threadScroll.offset < 70;
    try {
      final data = await widget.session.api.groupRequest('GET',
          '/$id/messages?q=${Uri.encodeQueryComponent(search.text.trim())}');
      final detail = await widget.session.api.groupRequest('GET', '/$id');
      if (!mounted || gen != generation) return;
      setState(() {
        messages = (data['items'] as List)
            .cast<Map<String, dynamic>>()
            .reversed
            .toList();
        members = (detail['members'] as List).cast<Map<String, dynamic>>();
        error = null;
      });
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || gen != generation) return;
      if (atBottom &&
          search.text.isEmpty &&
          pageVisible() &&
          messages.isNotEmpty) {
        final boundary = messages
            .map((m) => (m['sequence'] as num).toInt())
            .reduce((a, b) => a > b ? a : b);
        final receipt = await widget.session.api
            .groupRequest('POST', '/$id/read', body: {'sequence': boundary});
        if (mounted) {
          setState(() {
            for (final g in groups) {
              if (g['id'] == id) g['unread'] = receipt['unread'] ?? g['unread'];
            }
          });
        }
      }
    } catch (e) {
      if (mounted && gen == generation) setState(() => error = e.toString());
    }
  }

  Future<void> older() async {
    if (selected == null || messages.isEmpty) return;
    try {
      final data = await widget.session.api.groupRequest(
          'GET', '/$selected/messages?before=${messages.first['sequence']}');
      if (!mounted) return;
      final combined = {
        for (final m in [
          ...(data['items'] as List).cast<Map<String, dynamic>>(),
          ...messages
        ])
          m['id']: m
      };
      setState(() => messages = combined.values.toList()
        ..sort(
            (a, b) => (a['sequence'] as int).compareTo(b['sequence'] as int)));
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> send() async {
    if (sending || selected == null || draft.text.trim().isEmpty) return;
    final content = draft.text;
    if (pendingContent != content) {
      pendingContent = content;
      pendingId = const Uuid().v4();
    }
    setState(() => sending = true);
    try {
      await widget.session.api.groupRequest('POST', '/$selected/messages',
          body: {'content': content, 'clientId': pendingId});
      if (mounted) {
        draft.clear();
        pendingContent = null;
        pendingId = null;
        await refresh();
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> create() async {
    final id = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CreateGroupDialog(
            inboxes: widget.session.inboxes,
            onCreate: (payload) async {
              final result = await widget.session.api
                  .groupRequest('POST', '', body: payload);
              return result['id'] as String;
            }));
    if (id != null && mounted) {
      setState(() {
        selected = id;
        messages = [];
        members = [];
        draft.clear();
        search.clear();
        pendingContent = null;
        pendingId = null;
      });
      await refresh();
    }
  }

  Future<void> invite() async {
    try {
      final result = await widget.session.api
          .groupRequest('POST', '/$selected/invite', body: {});
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: const Text('邀请客户加入群聊'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('链接24小时有效，重新生成会撤销旧链接。持有链接的客户可填写称呼加入。'),
                    const SizedBox(height: 12),
                    SelectableText(result['url'] as String)
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('关闭')),
                    FilledButton(
                        onPressed: () async {
                          await Clipboard.setData(
                              ClipboardData(text: result['url'] as String));
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(content: Text('邀请链接已复制')));
                          }
                        },
                        child: const Text('复制链接'))
                  ]));
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> manage() async {
    try {
      final agents = await widget.session.api.agents();
      final detail = await widget.session.api.groupRequest('GET', '/$selected');
      if (!mounted) return;
      var current = (detail['members'] as List).cast<Map<String, dynamic>>();
      bool busy = false;
      String? failure;
      await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => StatefulBuilder(builder: (ctx, update) {
                Future<void> change(String method, String path,
                    Map<String, dynamic>? body) async {
                  update(() => busy = true);
                  try {
                    await widget.session.api
                        .groupRequest(method, path, body: body);
                    final result = await widget.session.api
                        .groupRequest('GET', '/$selected');
                    if (ctx.mounted)
                      update(() {
                        current = (result['members'] as List)
                            .cast<Map<String, dynamic>>();
                        failure = null;
                      });
                  } catch (e) {
                    if (ctx.mounted) update(() => failure = e.toString());
                  } finally {
                    if (ctx.mounted) update(() => busy = false);
                  }
                }

                return AlertDialog(
                    title: Text('群成员（${current.length}）'),
                    content: SizedBox(
                        width: 440,
                        height: 340,
                        child: ListView(children: [
                          if (failure != null)
                            Text(failure!,
                                style: const TextStyle(color: Colors.red)),
                          for (final m in current)
                            ListTile(
                                title: Text('${m['name']}'),
                                subtitle:
                                    Text(m['kind'] == 'agent' ? '企业成员' : '客户'),
                                trailing: owner && m['id'] != group?['ownerId']
                                    ? IconButton(
                                        tooltip: '移出群聊',
                                        icon: const Icon(
                                            Icons.person_remove_outlined),
                                        onPressed: busy
                                            ? null
                                            : () => change(
                                                'DELETE',
                                                '/$selected/members/${m['kind']}/${m['id']}',
                                                null))
                                    : null),
                          if (owner) const Divider(),
                          if (owner)
                            for (final a in agents.where((a) => !current.any(
                                (m) =>
                                    m['kind'] == 'agent' && m['id'] == a.id)))
                              ListTile(
                                  title: Text(a.displayName),
                                  trailing: IconButton(
                                      tooltip: '添加同事',
                                      icon: const Icon(Icons.person_add_alt),
                                      onPressed: busy
                                          ? null
                                          : () => change(
                                              'POST',
                                              '/$selected/members',
                                              {'agentId': a.id})))
                        ])),
                    actions: [
                      TextButton(
                          onPressed: busy ? null : () => Navigator.pop(ctx),
                          child: const Text('关闭'))
                    ]);
              }));
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> edit() async {
    final g = group;
    if (g == null) return;
    final name = TextEditingController(text: g['name'] as String),
        announcement = TextEditingController(text: g['announcement'] as String);
    bool archived = g['archived'] == true, busy = false;
    String? failure;
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                    title: const Text('群设置'),
                    content: SizedBox(
                        width: 400,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          if (failure != null)
                            Text(failure!,
                                style: const TextStyle(color: Colors.red)),
                          TextField(
                              controller: name,
                              maxLength: 120,
                              decoration:
                                  const InputDecoration(labelText: '群名称')),
                          TextField(
                              controller: announcement,
                              maxLength: 2000,
                              minLines: 2,
                              maxLines: 4,
                              decoration:
                                  const InputDecoration(labelText: '群公告')),
                          SwitchListTile(
                              value: archived,
                              onChanged: busy
                                  ? null
                                  : (v) => update(() => archived = v),
                              title: const Text('归档群聊'),
                              subtitle: const Text('归档后保留历史，停止发送及客户加入'))
                        ])),
                    actions: [
                      TextButton(
                          onPressed: busy ? null : () => Navigator.pop(ctx),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  update(() => busy = true);
                                  try {
                                    await widget.session.api.groupRequest(
                                        'PATCH', '/$selected',
                                        body: {
                                          'name': name.text.trim(),
                                          'announcement': announcement.text,
                                          'archived': archived
                                        });
                                    if (ctx.mounted) {
                                      Navigator.pop(ctx);
                                    }
                                    await refresh();
                                  } catch (e) {
                                    if (ctx.mounted) {
                                      update(() => failure = e.toString());
                                    }
                                  } finally {
                                    if (ctx.mounted) update(() => busy = false);
                                  }
                                },
                          child: const Text('保存'))
                    ])));
    name.dispose();
    announcement.dispose();
  }

  Future<void> nickname() async {
    final me =
        members.where((m) => m['id'] == widget.session.agent?.id).firstOrNull;
    final name = TextEditingController(text: me?['name'] as String? ?? '');
    String? failure;
    bool busy = false;
    final id = selected;
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                    title: const Text('我的群昵称'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: name,
                          maxLength: 120,
                          autofocus: true,
                          decoration: const InputDecoration(
                              labelText: '昵称',
                              helperText: '仅修改此群的称呼，新消息使用新昵称')),
                      if (failure != null)
                        Text(failure!,
                            style: const TextStyle(color: Colors.red)),
                    ]),
                    actions: [
                      TextButton(
                          onPressed: busy ? null : () => Navigator.pop(ctx),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  update(() => busy = true);
                                  try {
                                    await widget.session.api.groupRequest(
                                        'PATCH', '/$id/me',
                                        body: {'name': name.text.trim()});
                                    if (ctx.mounted) {
                                      Navigator.pop(ctx);
                                    }
                                    await refresh();
                                  } catch (e) {
                                    if (ctx.mounted)
                                      update(() => failure = e.toString());
                                  } finally {
                                    if (ctx.mounted) update(() => busy = false);
                                  }
                                },
                          child: const Text('保存'))
                    ])));
    name.dispose();
  }

  Future<void> recall(Map<String, dynamic> message) async {
    try {
      await widget.session.api.groupRequest(
          'POST', '/$selected/messages/${message['id']}/recall',
          body: {});
      await load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> dissolve() async {
    final id = selected;
    String? failure;
    bool busy = false;
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, update) => AlertDialog(
                    title: const Text('解散群聊？'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('所有成员将停止发送和通话，邀请链接立即失效。历史消息保留，解散后不能恢复。'),
                      if (failure != null)
                        Text(failure!,
                            style: const TextStyle(color: Colors.red)),
                    ]),
                    actions: [
                      TextButton(
                          onPressed: busy ? null : () => Navigator.pop(ctx),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  update(() => busy = true);
                                  try {
                                    await widget.session.api.groupRequest(
                                        'POST', '/$id/dissolve',
                                        body: {});
                                    if (ctx.mounted) {
                                      Navigator.pop(ctx);
                                    }
                                    await refresh();
                                  } catch (e) {
                                    if (ctx.mounted)
                                      update(() => failure = e.toString());
                                  } finally {
                                    if (ctx.mounted) update(() => busy = false);
                                  }
                                },
                          child: const Text('确认解散'))
                    ])));
  }

  void callWindow([String? groupId]) {
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => Dialog(
            insetPadding: const EdgeInsets.all(12),
            child: SizedBox(
                width: 900,
                height: 720,
                child: Column(children: [
                  Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      child: Row(children: [
                        const Expanded(
                            child: Text('群聊与音视频通话',
                                style: TextStyle(fontWeight: FontWeight.w600))),
                        IconButton(
                            tooltip: '关闭通话面板',
                            onPressed: () => Navigator.pop(ctx),
                            icon: const Icon(Icons.close))
                      ])),
                  Expanded(
                      child: groupCallPanel(groupId ?? selected!,
                          widget.session.api.token, widget.session.agent!.id))
                ]))));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 760;
      final list = Column(children: [
        Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              const Expanded(
                  child: Text('群聊',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 18))),
              IconButton(
                  tooltip: '刷新群聊',
                  onPressed: refresh,
                  icon: const Icon(Icons.refresh)),
              FilledButton.icon(
                  onPressed: create,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('建群'))
            ])),
        Expanded(
            child: groups.isEmpty
                ? const Center(child: Text('创建内部协作群或客户服务群'))
                : ListView(children: [
                    for (final g in groups)
                      ListTile(
                          selected: g['id'] == selected,
                          selectedTileColor:
                              Theme.of(context).colorScheme.primaryContainer,
                          leading: CircleAvatar(
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer,
                              child: Icon(Icons.groups_outlined,
                                  color:
                                      Theme.of(context).colorScheme.primary)),
                          title: Text('${g['name']}'),
                          subtitle: Text(
                              '${g['kind'] == 'INTERNAL' ? '内部协作' : '客户服务'} · ${g['memberCount']}人${g['dissolved'] == true ? ' · 已解散' : g['archived'] == true ? ' · 已归档' : ''}'),
                          trailing: (g['unread'] as num) > 0
                              ? Badge(
                                  backgroundColor:
                                      Theme.of(context).colorScheme.primary,
                                  label: Text('${g['unread']}'))
                              : null,
                          onTap: () {
                            setState(() {
                              selected = g['id'] as String;
                              messages = [];
                              search.clear();
                              draft.clear();
                            });
                            load();
                          })
                  ]))
      ]);
      final thread = Column(children: [
        Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              if (narrow)
                IconButton(
                    onPressed: () => setState(() => selected = null),
                    icon: const Icon(Icons.arrow_back)),
              Expanded(
                  child: Text('${group?['name'] ?? '群聊'}',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600))),
              IconButton(
                  tooltip: '语音与视频通话',
                  onPressed:
                      group?['archived'] == true ? null : () => callWindow(),
                  icon: const Icon(Icons.call_outlined)),
              PopupMenuButton<String>(
                  tooltip: '更多群聊操作',
                  onSelected: (action) {
                    switch (action) {
                      case 'nickname':
                        nickname();
                        break;
                      case 'invite':
                        invite();
                        break;
                      case 'edit':
                        edit();
                        break;
                      case 'dissolve':
                        dissolve();
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                        if (group?['dissolved'] != true)
                          const PopupMenuItem(
                              value: 'nickname', child: Text('我的群昵称')),
                        if (owner &&
                            group?['kind'] == 'SERVICE' &&
                            group?['archived'] != true)
                          const PopupMenuItem(
                              value: 'invite', child: Text('邀请客户')),
                        if (owner && group?['dissolved'] != true)
                          const PopupMenuItem(
                              value: 'edit', child: Text('群设置')),
                        if (owner && group?['dissolved'] != true)
                          const PopupMenuItem(
                              value: 'dissolve',
                              child: Text('解散群聊',
                                  style: TextStyle(color: Colors.red))),
                      ])
            ])),
        Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                      onPressed: manage,
                      icon: const Icon(Icons.group_outlined, size: 18),
                      label: const Text('群成员')),
                  if (owner &&
                      group?['kind'] == 'SERVICE' &&
                      group?['archived'] != true)
                    FilledButton.tonalIcon(
                        onPressed: invite,
                        icon: const Icon(Icons.link, size: 18),
                        label: const Text('邀请客户')),
                ]))),
        if ((group?['announcement'] ?? '') != '')
          Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(10)),
              child: Row(children: [
                Icon(Icons.campaign_outlined,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text('群公告：${group?['announcement']}')),
              ])),
        if (error != null)
          Padding(
              padding: const EdgeInsets.all(12),
              child: Text(error!, style: const TextStyle(color: Colors.red))),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
                controller: search,
                decoration: const InputDecoration(
                    hintText: '搜索群消息', prefixIcon: Icon(Icons.search)),
                onChanged: (_) {
                  debounce?.cancel();
                  debounce = Timer(const Duration(milliseconds: 300), load);
                },
                onSubmitted: (_) {
                  debounce?.cancel();
                  load();
                })),
        if (messages.length >= 100 && search.text.isEmpty)
          TextButton(onPressed: older, child: const Text('加载更早消息')),
        Expanded(
            child: ListView(
                reverse: true,
                controller: threadScroll,
                padding: const EdgeInsets.all(16),
                children: messages.reversed
                    .map((m) => Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Column(
                            crossAxisAlignment:
                                m['actorId'] == widget.session.agent?.id
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                            children: [
                              Text(
                                  '${m['name']} · ${m['kind'] == 'widget' ? '客户' : '同事'}',
                                  style:
                                      Theme.of(context).textTheme.labelSmall),
                              const SizedBox(height: 4),
                              Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                      color: m['actorId'] ==
                                              widget.session.agent?.id
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primaryContainer
                                          : Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(12)),
                                  child: SelectableText(m['recalled'] == true
                                      ? '该消息已被撤回'
                                      : '${m['content']}')),
                              if (m['actorId'] == widget.session.agent?.id &&
                                  m['recalled'] != true)
                                TextButton(
                                    onPressed: () => recall(m),
                                    child: const Text('撤回',
                                        style: TextStyle(fontSize: 12)))
                            ])))
                    .toList())),
        if (group?['archived'] == true)
          Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                  group?['dissolved'] == true ? '群已解散，仅可查看历史' : '群已归档，仅可查看历史'))
        else
          Padding(
              padding: const EdgeInsets.all(12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                    child: TextField(
                        controller: draft,
                        minLines: 1,
                        maxLines: 4,
                        maxLength: 4000,
                        decoration: const InputDecoration(
                            hintText: '发送群消息…', counterText: ''))),
                const SizedBox(width: 8),
                FilledButton(
                    onPressed: sending ? null : send,
                    child: Text(sending ? '发送中' : '发送'))
              ]))
      ]);
      if (narrow) return selected == null ? list : thread;
      return Row(children: [
        SizedBox(width: 300, child: list),
        const VerticalDivider(width: 1),
        Expanded(
            child: selected == null
                ? const Center(child: Text('选择群聊，开始协作'))
                : thread),
        if (box.maxWidth >= 1040 && selected != null) ...[
          const VerticalDivider(width: 1),
          SizedBox(width: 260, child: _memberSidebar(context)),
        ],
      ]);
    });
  }

  Widget _memberSidebar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
        color: theme.colorScheme.surface,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(children: [
                const Icon(Icons.groups_outlined),
                const SizedBox(width: 8),
                Expanded(
                    child: Text('群成员（${members.length}）',
                        style: theme.textTheme.titleSmall)),
                IconButton(
                    tooltip: '管理群成员',
                    onPressed: manage,
                    icon: const Icon(Icons.more_horiz)),
              ])),
          const Divider(),
          Expanded(
              child: ListView(children: [
            for (final m in members)
              ListTile(
                  leading: CircleAvatar(
                      radius: 18,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      child: Icon(
                          m['kind'] == 'agent'
                              ? Icons.person_outline
                              : Icons.person,
                          color: theme.colorScheme.primary,
                          size: 20)),
                  title: Text('${m['name'] ?? ''}'),
                  trailing: Text(
                      m['kind'] == 'agent' && m['id'] == group?['ownerId']
                          ? '群主'
                          : m['kind'] == 'agent'
                              ? '成员'
                              : '客户',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant))),
          ])),
          if ((group?['announcement'] ?? '') != '')
            Padding(
                padding: const EdgeInsets.all(16),
                child: Card(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('群公告', style: theme.textTheme.titleSmall),
                              const SizedBox(height: 8),
                              Text('${group?['announcement']}'),
                            ])))),
        ]));
  }
}
