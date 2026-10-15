import 'dart:async';
import 'package:flutter/material.dart';
import '../api/relaydesk_api.dart';
import '../api/models.dart';
import '../util/message_alert_stub.dart'
    if (dart.library.html) '../util/message_alert_web.dart';
import '../util/push_bridge_stub.dart'
    if (dart.library.html) '../util/push_bridge_web.dart';
import '../util/website.dart';

/// 通知由服务端保存，刷新或更换设备仍保留已读状态。
class NotificationCenter extends StatefulWidget {
  const NotificationCenter(
      {super.key, required this.api, required this.onConversation});
  final RelayDeskApi api;
  final ValueChanged<String> onConversation;
  @override
  State<NotificationCenter> createState() => _NotificationCenterState();
}

class _NotificationCenterState extends State<NotificationCenter> {
  Timer? _timer;
  List<Map<String, dynamic>> _items = [];
  int _unread = 0;
  String? _error, _pushStatus;
  bool _busy = false;
  DateTime? _quietUntil;

  String _displayTime(dynamic value) {
    final date = DateTime.tryParse(asString(value))?.toLocal();
    if (date == null) return '';
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${pad(date.month)}-${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}';
  }

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    _busy = true;
    try {
      final data = await widget.api.notificationRequest('GET', '');
      if (mounted)
        setState(() {
          _quietUntil = DateTime.tryParse(asString(data['quietUntil']));
          setMessageQuietUntil(_quietUntil);
          _items = asMapList(data['items']);
          _unread = asInt(data['unread']);
          _error = null;
        });
    } catch (_) {
      if (mounted) setState(() => _error = '消息暂未加载，请重试');
    } finally {
      _busy = false;
    }
  }

  Future<void> _read({String? id}) async {
    await widget.api.notificationRequest('POST', '/read',
        body: id == null ? {'all': true} : {'id': id});
    await _load();
  }

  Future<void> _open() async {
    await _load();
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, refresh) => AlertDialog(
                  title: const Text('消息中心'),
                  content: SizedBox(
                      width: 480,
                      height: 500,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(spacing: 8, children: [
                              TextButton(
                                  onPressed: () async {
                                    try {
                                      await widget.api.notificationRequest(
                                          'POST', '/quiet', body: {
                                        'minutes': _quietUntil
                                                    ?.isAfter(DateTime.now()) ==
                                                true
                                            ? 0
                                            : 60
                                      });
                                      await _load();
                                      if (ctx.mounted) refresh(() {});
                                    } catch (_) {
                                      if (ctx.mounted)
                                        refresh(() => _error = '保存免打扰失败，请重试');
                                    }
                                  },
                                  child: Text(
                                      _quietUntil?.isAfter(DateTime.now()) ==
                                              true
                                          ? '恢复提醒'
                                          : '免打扰 1 小时')),
                              TextButton.icon(
                                  onPressed: () async {
                                    try {
                                      await _read();
                                      refresh(() {});
                                    } catch (_) {
                                      refresh(() => _error = '标记失败，请重试');
                                    }
                                  },
                                  icon: const Icon(Icons.done_all),
                                  label: const Text('全部已读')),
                              TextButton.icon(
                                  onPressed: () async {
                                    final status =
                                        await enableBackgroundPush(widget.api);
                                    if (mounted && ctx.mounted) {
                                      setState(() => _pushStatus = status);
                                      refresh(() {});
                                    }
                                  },
                                  icon: const Icon(
                                      Icons.notifications_active_outlined),
                                  label: const Text('开启后台提醒')),
                              TextButton(
                                  onPressed: () async {
                                    final status =
                                        await disableBackgroundPush(widget.api);
                                    if (mounted && ctx.mounted) {
                                      setState(() => _pushStatus = status);
                                      refresh(() {});
                                    }
                                  },
                                  child: const Text('关闭后台提醒')),
                            ]),
                            if (_pushStatus != null)
                              Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Text(_pushStatus!)),
                            if (_error != null)
                              TextButton(
                                  onPressed: () async {
                                    await _load();
                                    if (ctx.mounted) refresh(() {});
                                  },
                                  child: Text('$_error · 点击重试')),
                            Expanded(
                                child: _items.isEmpty
                                    ? const Center(
                                        child: Text('暂无通知。客户新消息会显示在这里。'))
                                    : ListView(children: [
                                        for (final item in _items)
                                          ListTile(
                                            leading: Icon(
                                                item['readAt'] == null
                                                    ? Icons
                                                        .mark_email_unread_outlined
                                                    : Icons.drafts_outlined,
                                                color: item['readAt'] == null
                                                    ? Theme.of(ctx)
                                                        .colorScheme
                                                        .primary
                                                    : null),
                                            title:
                                                Text(asString(item['title'])),
                                            subtitle: Text(_displayTime(
                                                item['createdAt'])),
                                            onTap: () async {
                                              try {
                                                await _read(
                                                    id: asString(item['id']));
                                                if (!mounted || !ctx.mounted)
                                                  return;
                                                Navigator.pop(ctx);
                                                widget.onConversation(asString(
                                                    item['conversationId']));
                                              } catch (_) {
                                                if (ctx.mounted)
                                                  refresh(() =>
                                                      _error = '打开通知失败，请重试');
                                              }
                                            },
                                          )
                                      ])),
                            const Divider(),
                            Wrap(children: [
                              TextButton.icon(
                                  onPressed: () => showDialog<void>(
                                      context: ctx,
                                      builder: (c) => AlertDialog(
                                              title: const Text('声音与发送者播报'),
                                              content: SizedBox(
                                                  width: 430,
                                                  child: SingleChildScrollView(
                                                      child:
                                                          messageAlertSettings())),
                                              actions: [
                                                TextButton(
                                                    onPressed: () =>
                                                        Navigator.pop(c),
                                                    child: const Text('完成'))
                                              ])),
                                  icon: const Icon(
                                      Icons.record_voice_over_outlined),
                                  label: const Text('发送者语音播报设置')),
                              if (canOpenWebsite)
                                TextButton.icon(
                                    onPressed: openDownloads,
                                    icon: const Icon(Icons.phone_android),
                                    label: const Text('手机客户端下载'))
                            ]),
                          ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('关闭'))
                  ],
                )));
  }

  @override
  Widget build(BuildContext context) => IconButton(
      tooltip: '消息中心 · $_unread 条未读',
      onPressed: _open,
      icon: Badge(
          isLabelVisible: _unread > 0,
          label: Text(_unread > 99 ? '99+' : '$_unread'),
          child: const Icon(Icons.notifications_none_outlined, size: 20)));
}
