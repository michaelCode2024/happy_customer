import 'dart:async';
import 'package:flutter/material.dart';
import '../api/tongyu_api.dart';
import '../api/models.dart';
import '../util/message_alert_stub.dart'
    if (dart.library.html) '../util/message_alert_web.dart';
import '../util/push_bridge_stub.dart'
    if (dart.library.html) '../util/push_bridge_web.dart';

/// 通知由服务端保存，刷新或更换设备仍保留已读状态。
class NotificationCenter extends StatefulWidget {
  const NotificationCenter(
      {super.key, required this.api, required this.onConversation});
  final TongYuApi api;
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
    // 页面加载后自动尝试开启系统后台消息提醒
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await enableBackgroundPush(widget.api);
      } catch (_) {}
    });
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
                  title: Row(
                    children: [
                      const Icon(Icons.notifications_active_rounded,
                          color: Color(0xFFE53935), size: 22),
                      const SizedBox(width: 8),
                      const Expanded(child: Text('消息提醒中心')),
                      if (_unread > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFEBEE),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: const Color(0xFFFFCDD2)),
                          ),
                          child: Text(
                            '$_unread 条未读',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFC62828),
                            ),
                          ),
                        ),
                    ],
                  ),
                  content: SizedBox(
                      width: 480,
                      height: 520,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(spacing: 8, runSpacing: 6, children: [
                              ActionChip(
                                  avatar: Icon(
                                      _quietUntil?.isAfter(DateTime.now()) == true
                                          ? Icons.notifications_off_outlined
                                          : Icons.notifications_outlined,
                                      size: 16),
                                  label: Text(
                                      _quietUntil?.isAfter(DateTime.now()) == true
                                          ? '恢复提醒'
                                          : '免打扰 1 小时'),
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
                                  }),
                              ActionChip(
                                  avatar: const Icon(Icons.done_all, size: 16),
                                  label: const Text('全部已读'),
                                  onPressed: () async {
                                    try {
                                      await _read();
                                      refresh(() {});
                                    } catch (_) {
                                      refresh(() => _error = '标记失败，请重试');
                                    }
                                  }),
                              ActionChip(
                                  avatar: const Icon(Icons.bolt,
                                      color: Color(0xFF3263FF), size: 16),
                                  label: const Text('开启系统通知'),
                                  onPressed: () async {
                                    final status =
                                        await enableBackgroundPush(widget.api);
                                    if (mounted && ctx.mounted) {
                                      setState(() => _pushStatus = status);
                                      refresh(() {});
                                    }
                                  }),
                              ActionChip(
                                  avatar: const Icon(Icons.volume_up_outlined,
                                      size: 16),
                                  label: const Text('声音与播报设置'),
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
                                              ]))),
                            ]),
                            if (_pushStatus != null)
                              Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(_pushStatus!,
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF5A6E85)))),
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: TextButton(
                                    onPressed: () async {
                                      await _load();
                                      if (ctx.mounted) refresh(() {});
                                    },
                                    child: Text('$_error · 点击重试',
                                        style: const TextStyle(fontSize: 12))),
                              ),
                            const SizedBox(height: 12),
                            Expanded(
                                child: _items.isEmpty
                                    ? Container(
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF8FAFD),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          border: Border.all(
                                              color: const Color(0xFFE8EEF5)),
                                        ),
                                        child: const Center(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                  Icons
                                                      .mark_chat_unread_outlined,
                                                  size: 40,
                                                  color: Color(0xFF9AAEC4)),
                                              SizedBox(height: 10),
                                              Text('暂无新通知',
                                                  style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color:
                                                          Color(0xFF475569))),
                                              SizedBox(height: 4),
                                              Text('客户的新进消息和待办会第一时间提醒您',
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      color:
                                                          Color(0xFF94A3B8))),
                                            ],
                                          ),
                                        ),
                                      )
                                    : ListView.separated(
                                        itemCount: _items.length,
                                        separatorBuilder: (_, __) =>
                                            const SizedBox(height: 6),
                                        itemBuilder: (context, index) {
                                          final item = _items[index];
                                          final isUnread =
                                              item['readAt'] == null;
                                          return Material(
                                            color: isUnread
                                                ? const Color(0xFFFFF5F5)
                                                : const Color(0xFFF8FAFD),
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              onTap: () async {
                                                try {
                                                  await _read(
                                                      id: asString(
                                                          item['id']));
                                                  if (!mounted ||
                                                      !ctx.mounted) {
                                                    return;
                                                  }
                                                  Navigator.pop(ctx);
                                                  widget.onConversation(
                                                      asString(item[
                                                          'conversationId']));
                                                } catch (_) {
                                                  if (ctx.mounted) {
                                                    refresh(() => _error =
                                                        '打开通知失败，请重试');
                                                  }
                                                }
                                              },
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.fromLTRB(
                                                        10, 10, 12, 10),
                                                decoration: BoxDecoration(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          10),
                                                  border: Border(
                                                    left: BorderSide(
                                                      color: isUnread
                                                          ? const Color(
                                                              0xFFE53935)
                                                          : Colors
                                                              .transparent,
                                                      width: 3,
                                                    ),
                                                    top: BorderSide(
                                                      color: isUnread
                                                          ? const Color(
                                                              0xFFFFCDD2)
                                                          : const Color(
                                                              0xFFE8EEF5),
                                                    ),
                                                    right: BorderSide(
                                                      color: isUnread
                                                          ? const Color(
                                                              0xFFFFCDD2)
                                                          : const Color(
                                                              0xFFE8EEF5),
                                                    ),
                                                    bottom: BorderSide(
                                                      color: isUnread
                                                          ? const Color(
                                                              0xFFFFCDD2)
                                                          : const Color(
                                                              0xFFE8EEF5),
                                                    ),
                                                  ),
                                                ),
                                                child: Row(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment
                                                          .start,
                                                  children: [
                                                    Container(
                                                      width: 38,
                                                      height: 38,
                                                      decoration:
                                                          BoxDecoration(
                                                        color: isUnread
                                                            ? const Color(
                                                                0xFFFFEBEE)
                                                            : const Color(
                                                                0xFFF1F5F9),
                                                        shape:
                                                            BoxShape.circle,
                                                      ),
                                                      child: Icon(
                                                        isUnread
                                                            ? Icons
                                                                .mark_email_unread_rounded
                                                            : Icons
                                                                .mail_outline_rounded,
                                                        size: 18,
                                                        color: isUnread
                                                            ? const Color(
                                                                0xFFE53935)
                                                            : const Color(
                                                                0xFF94A3B8),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 10),
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          Row(
                                                            children: [
                                                              Expanded(
                                                                child: Text(
                                                                  asString(item[
                                                                      'title']),
                                                                  style:
                                                                      TextStyle(
                                                                    fontSize:
                                                                        13.5,
                                                                    height:
                                                                        1.35,
                                                                    fontWeight:
                                                                        isUnread
                                                                            ? FontWeight.w700
                                                                            : FontWeight.w500,
                                                                    color: const Color(
                                                                        0xFF0F172A),
                                                                  ),
                                                                ),
                                                              ),
                                                              if (isUnread)
                                                                Container(
                                                                  margin: const EdgeInsets
                                                                      .only(
                                                                      left:
                                                                          6),
                                                                  padding: const EdgeInsets
                                                                      .symmetric(
                                                                      horizontal:
                                                                          6,
                                                                      vertical:
                                                                          2),
                                                                  decoration:
                                                                      BoxDecoration(
                                                                    color: const Color(
                                                                        0xFFE53935),
                                                                    borderRadius:
                                                                        BorderRadius.circular(
                                                                            999),
                                                                  ),
                                                                  child:
                                                                      const Text(
                                                                    '未读',
                                                                    style:
                                                                        TextStyle(
                                                                      fontSize:
                                                                          10,
                                                                      fontWeight:
                                                                          FontWeight.w700,
                                                                      color: Colors
                                                                          .white,
                                                                    ),
                                                                  ),
                                                                ),
                                                            ],
                                                          ),
                                                          const SizedBox(
                                                              height: 4),
                                                          Text(
                                                            _displayTime(item[
                                                                'createdAt']),
                                                            style: const TextStyle(
                                                                fontSize: 11,
                                                                color: Color(
                                                                    0xFF64748B)),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                    const Icon(
                                                      Icons
                                                          .chevron_right_rounded,
                                                      size: 18,
                                                      color:
                                                          Color(0xFF94A3B8),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      )),
                          ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('关闭'))
                  ],
                )));
  }

  @override
  Widget build(BuildContext context) {
    final hasUnread = _unread > 0;
    return Semantics(
      button: true,
      label: hasUnread ? '消息中心，$_unread 条未读' : '消息中心',
      identifier: 'desk.notifications.open',
      child: IconButton(
        key: const ValueKey('desk-notifications-open'),
        tooltip: '消息中心 · $_unread 条未读',
        onPressed: _open,
        // 有未读时用浅红底 + 实心铃铛 + 红色角标，避免灰线图标淹没在顶栏里。
        icon: Badge(
          isLabelVisible: hasUnread,
          backgroundColor: const Color(0xFFE53935),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          label: Text(
            _unread > 99 ? '99+' : '$_unread',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.1,
            ),
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hasUnread
                  ? const Color(0xFFFFEBEE)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: hasUnread
                  ? Border.all(color: const Color(0xFFFFCDD2))
                  : null,
            ),
            child: Icon(
              hasUnread
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_none_rounded,
              size: 22,
              color: hasUnread
                  ? const Color(0xFFE53935)
                  : const Color(0xFF334155),
            ),
          ),
        ),
      ),
    );
  }
}
