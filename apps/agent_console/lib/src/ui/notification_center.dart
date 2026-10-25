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
    var filterUnreadOnly = false;
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, refresh) {
              final displayedItems = filterUnreadOnly
                  ? _items.where((i) => i['readAt'] == null).toList()
                  : _items;

              return AlertDialog(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  actionsPadding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
                  title: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: _unread > 0
                              ? const Color(0xFFFFEBEE)
                              : const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          _unread > 0
                              ? Icons.chat_bubble_rounded
                              : Icons.chat_bubble_outline_rounded,
                          color: _unread > 0
                              ? const Color(0xFFE53935)
                              : const Color(0xFF2563EB),
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          '消息通知中心',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
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
                            '$_unread 条新消息',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFC62828),
                            ),
                          ),
                        ),
                    ],
                  ),
                  content: SizedBox(
                      width: 500,
                      height: 520,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // 快捷筛选与操作栏
                            Row(
                              children: [
                                // 全部 / 仅看未读 胶囊切换
                                Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF1F5F9),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      InkWell(
                                        borderRadius: BorderRadius.circular(6),
                                        onTap: () => refresh(
                                            () => filterUnreadOnly = false),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 5),
                                          decoration: BoxDecoration(
                                            color: !filterUnreadOnly
                                                ? Colors.white
                                                : Colors.transparent,
                                            borderRadius:
                                                BorderRadius.circular(6),
                                            boxShadow: !filterUnreadOnly
                                                ? [
                                                    BoxShadow(
                                                      color: Colors.black
                                                          .withValues(
                                                              alpha: 0.05),
                                                      blurRadius: 2,
                                                      offset:
                                                          const Offset(0, 1),
                                                    )
                                                  ]
                                                : null,
                                          ),
                                          child: Text(
                                            '全部 (${_items.length})',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: !filterUnreadOnly
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                              color: !filterUnreadOnly
                                                  ? const Color(0xFF0F172A)
                                                  : const Color(0xFF64748B),
                                            ),
                                          ),
                                        ),
                                      ),
                                      InkWell(
                                        borderRadius: BorderRadius.circular(6),
                                        onTap: () => refresh(
                                            () => filterUnreadOnly = true),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 5),
                                          decoration: BoxDecoration(
                                            color: filterUnreadOnly
                                                ? Colors.white
                                                : Colors.transparent,
                                            borderRadius:
                                                BorderRadius.circular(6),
                                            boxShadow: filterUnreadOnly
                                                ? [
                                                    BoxShadow(
                                                      color: Colors.black
                                                          .withValues(
                                                              alpha: 0.05),
                                                      blurRadius: 2,
                                                      offset:
                                                          const Offset(0, 1),
                                                    )
                                                  ]
                                                : null,
                                          ),
                                          child: Text(
                                            '未读 ($_unread)',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: filterUnreadOnly
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                              color: filterUnreadOnly
                                                  ? const Color(0xFFE53935)
                                                  : const Color(0xFF64748B),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Spacer(),
                                if (_unread > 0)
                                  TextButton.icon(
                                    style: TextButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8),
                                    ),
                                    icon: const Icon(Icons.done_all,
                                        size: 15, color: Color(0xFF2563EB)),
                                    label: const Text('全部已读',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF2563EB))),
                                    onPressed: () async {
                                      try {
                                        await _read();
                                        refresh(() {});
                                      } catch (_) {
                                        refresh(() => _error = '标记失败，请重试');
                                      }
                                    },
                                  ),
                                PopupMenuButton<String>(
                                  tooltip: '更多设置',
                                  icon: const Icon(Icons.more_horiz_rounded,
                                      size: 18, color: Color(0xFF64748B)),
                                  itemBuilder: (ctx) => [
                                    PopupMenuItem(
                                      value: 'quiet',
                                      child: Row(
                                        children: [
                                          Icon(
                                            _quietUntil?.isAfter(
                                                        DateTime.now()) ==
                                                    true
                                                ? Icons
                                                    .notifications_off_outlined
                                                : Icons.notifications_outlined,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            _quietUntil?.isAfter(
                                                        DateTime.now()) ==
                                                    true
                                                ? '恢复提醒通知'
                                                : '免打扰 1 小时',
                                            style:
                                                const TextStyle(fontSize: 13),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const PopupMenuItem(
                                      value: 'sound',
                                      child: Row(
                                        children: [
                                          Icon(Icons.volume_up_outlined,
                                              size: 16),
                                          SizedBox(width: 8),
                                          Text('声音与播报设置',
                                              style: TextStyle(fontSize: 13)),
                                        ],
                                      ),
                                    ),
                                    const PopupMenuItem(
                                      value: 'push',
                                      child: Row(
                                        children: [
                                          Icon(Icons.bolt,
                                              size: 16,
                                              color: Color(0xFF3263FF)),
                                          SizedBox(width: 8),
                                          // 安卓安装包=本机轮询；iOS/网页 PWA=Web Push。都不做厂商云推送。
                                          Text('开启后台消息提醒',
                                              style: TextStyle(fontSize: 13)),
                                        ],
                                      ),
                                    ),
                                  ],
                                  onSelected: (val) async {
                                    if (val == 'quiet') {
                                      try {
                                        await widget.api
                                            .notificationRequest(
                                                'POST', '/quiet', body: {
                                          'minutes': _quietUntil?.isAfter(
                                                      DateTime.now()) ==
                                                  true
                                              ? 0
                                              : 60
                                        });
                                        await _load();
                                        if (ctx.mounted) refresh(() {});
                                      } catch (_) {
                                        if (ctx.mounted) {
                                          refresh(() =>
                                              _error = '保存免打扰失败，请重试');
                                        }
                                      }
                                    } else if (val == 'sound') {
                                      showDialog<void>(
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
                                              ]));
                                    } else if (val == 'push') {
                                      final status = await enableBackgroundPush(
                                          widget.api);
                                      if (mounted && ctx.mounted) {
                                        setState(() => _pushStatus = status);
                                        refresh(() {});
                                      }
                                    }
                                  },
                                ),
                              ],
                            ),
                            if (_pushStatus != null)
                              Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(_pushStatus!,
                                      style: const TextStyle(
                                          fontSize: 11.5,
                                          color: Color(0xFF5A6E85)))),
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: TextButton(
                                    onPressed: () async {
                                      await _load();
                                      if (ctx.mounted) refresh(() {});
                                    },
                                    child: Text('$_error · 点击重试',
                                        style: const TextStyle(fontSize: 12))),
                              ),
                            const SizedBox(height: 10),
                            Expanded(
                                child: displayedItems.isEmpty
                                    ? Container(
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF8FAFD),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(
                                              color: const Color(0xFFE8EEF5)),
                                        ),
                                        padding: const EdgeInsets.all(24),
                                        child: Center(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Container(
                                                width: 52,
                                                height: 52,
                                                decoration: BoxDecoration(
                                                  color: Colors.white,
                                                  shape: BoxShape.circle,
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: Colors.black
                                                          .withValues(
                                                              alpha: 0.04),
                                                      blurRadius: 8,
                                                      offset:
                                                          const Offset(0, 2),
                                                    ),
                                                  ],
                                                ),
                                                child: const Icon(
                                                  Icons
                                                      .chat_bubble_outline_rounded,
                                                  size: 26,
                                                  color: Color(0xFF94A3B8),
                                                ),
                                              ),
                                              const SizedBox(height: 12),
                                              Text(
                                                filterUnreadOnly
                                                    ? '暂无未读消息'
                                                    : '暂无消息提醒',
                                                style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                  color: Color(0xFF334155),
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              const Text(
                                                '当客户发来咨询或需要人工接待时，会在这里显示',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: Color(0xFF94A3B8),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                    : ListView.separated(
                                        itemCount: displayedItems.length,
                                        separatorBuilder: (_, __) =>
                                            const SizedBox(height: 8),
                                        itemBuilder: (context, index) {
                                          final item = displayedItems[index];
                                          final isUnread =
                                              item['readAt'] == null;
                                          final title =
                                              asString(item['title']);
                                          // 提取发件人名字
                                          final senderName =
                                              title.contains(' 发来了新消息')
                                                  ? title.replaceAll(
                                                      ' 发来了新消息', '')
                                                  : title;

                                          return Material(
                                            color: isUnread
                                                ? const Color(0xFFFFF7F7)
                                                : Colors.white,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              side: BorderSide(
                                                color: isUnread
                                                    ? const Color(0xFFFFCDD2)
                                                    : const Color(0xFFE2E8F0),
                                                width: isUnread ? 1.2 : 1,
                                              ),
                                            ),
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(12),
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
                                                        '打开会话失败，请重试');
                                                  }
                                                }
                                              },
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 12,
                                                        vertical: 11),
                                                child: Row(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.center,
                                                  children: [
                                                    // IM 对话头像
                                                    Stack(
                                                      clipBehavior: Clip.none,
                                                      children: [
                                                        Container(
                                                          width: 42,
                                                          height: 42,
                                                          decoration:
                                                              BoxDecoration(
                                                            gradient:
                                                                LinearGradient(
                                                              begin: Alignment
                                                                  .topLeft,
                                                              end: Alignment
                                                                  .bottomRight,
                                                              colors: isUnread
                                                                  ? const [
                                                                      Color(
                                                                          0xFFFF7043),
                                                                      Color(
                                                                          0xFFE53935)
                                                                    ]
                                                                  : const [
                                                                      Color(
                                                                          0xFF60A5FA),
                                                                      Color(
                                                                          0xFF2563EB)
                                                                    ],
                                                            ),
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(
                                                                        12),
                                                          ),
                                                          child: Center(
                                                            child: Text(
                                                              senderName
                                                                      .isNotEmpty
                                                                  ? senderName
                                                                      .characters
                                                                      .first
                                                                  : '客',
                                                              style:
                                                                  const TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                                fontSize: 16,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                        if (isUnread)
                                                          Positioned(
                                                            top: -2,
                                                            right: -2,
                                                            child: Container(
                                                              width: 10,
                                                              height: 10,
                                                              decoration:
                                                                  BoxDecoration(
                                                                color:
                                                                    const Color(
                                                                        0xFFE53935),
                                                                shape: BoxShape
                                                                    .circle,
                                                                border:
                                                                    Border.all(
                                                                  color:
                                                                      Colors
                                                                          .white,
                                                                  width: 2,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                    const SizedBox(width: 12),
                                                    // 消息发送人与内容预览
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
                                                                  senderName,
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                  style:
                                                                      TextStyle(
                                                                    fontSize:
                                                                        14,
                                                                    fontWeight:
                                                                        isUnread
                                                                            ? FontWeight.w700
                                                                            : FontWeight.w600,
                                                                    color: const Color(
                                                                        0xFF0F172A),
                                                                  ),
                                                                ),
                                                              ),
                                                              const SizedBox(
                                                                  width: 8),
                                                              Text(
                                                                _displayTime(item[
                                                                    'createdAt']),
                                                                style:
                                                                    TextStyle(
                                                                  fontSize: 11,
                                                                  fontWeight:
                                                                      isUnread
                                                                          ? FontWeight.w600
                                                                          : FontWeight.normal,
                                                                  color: isUnread
                                                                      ? const Color(
                                                                          0xFFE53935)
                                                                      : const Color(
                                                                          0xFF94A3B8),
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                          const SizedBox(
                                                              height: 3),
                                                          Row(
                                                            children: [
                                                              Expanded(
                                                                child: Text(
                                                                  '发来了新消息，点击快速接入对话',
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                  style:
                                                                      TextStyle(
                                                                    fontSize:
                                                                        12,
                                                                    color: isUnread
                                                                        ? const Color(
                                                                            0xFF475569)
                                                                        : const Color(
                                                                            0xFF94A3B8),
                                                                  ),
                                                                ),
                                                              ),
                                                              Container(
                                                                padding: const EdgeInsets
                                                                    .symmetric(
                                                                    horizontal:
                                                                        6,
                                                                    vertical:
                                                                        2),
                                                                decoration:
                                                                    BoxDecoration(
                                                                  color: isUnread
                                                                      ? const Color(
                                                                          0xFFFFEBEE)
                                                                      : const Color(
                                                                          0xFFF1F5F9),
                                                                  borderRadius:
                                                                      BorderRadius
                                                                          .circular(
                                                                              4),
                                                                ),
                                                                child: Text(
                                                                  isUnread
                                                                      ? '未读'
                                                                      : '已读',
                                                                  style:
                                                                      TextStyle(
                                                                    fontSize:
                                                                        10,
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w600,
                                                                    color: isUnread
                                                                        ? const Color(
                                                                            0xFFC62828)
                                                                        : const Color(
                                                                            0xFF64748B),
                                                                  ),
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ],
                                                      ),
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
                );
            }));
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
