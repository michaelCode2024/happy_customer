import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:tongyu_agent_console/src/util/in_app_push.dart';

/// 站内推送提醒浮层：新消息从**右上角**滑入，堆叠在页面最上层。
///
/// 只在工作台内使用。它监听 [InAppPushManager]，把每条提醒渲染成一张
/// 手机通知风格的卡片：
/// - 从右上角斜向滑入（位移 + 淡入 + 轻微放大）；
/// - 6 秒后自动收起，鼠标悬停时暂停计时，方便看清；
/// - 点卡片打开对应会话并收起，点右上角 × 立即收起；
/// - 同屏最多 [InAppPushManager.maxVisible] 张，旧的自然被挤出。
class InAppPushOverlay extends StatelessWidget {
  const InAppPushOverlay({
    super.key,
    required this.manager,
    required this.onOpen,
  });

  final InAppPushManager manager;

  /// 点击卡片时回调，参数是会话 id；由工作台切到会话区并打开该会话。
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) {
        final items = manager.items;
        if (items.isEmpty) return const SizedBox.shrink();
        final width = MediaQuery.sizeOf(context).width;
        final cardWidth = math.min(360.0, width - 24);
        return Stack(
          children: [
            Positioned(
              top: 12,
              right: 12,
              child: SizedBox(
                width: cardWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final item in items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _PushCard(
                          key: ValueKey<String>(item.messageId),
                          item: item,
                          onOpen: () => onOpen(item.conversationId),
                          onDismiss: () => manager.remove(item.messageId),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PushCard extends StatefulWidget {
  const _PushCard({
    super.key,
    required this.item,
    required this.onOpen,
    required this.onDismiss,
  });

  final InAppMessagePush item;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  State<_PushCard> createState() => _PushCardState();
}

class _PushCardState extends State<_PushCard>
    with SingleTickerProviderStateMixin {
  static const Duration _autoDismiss = Duration(seconds: 6);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  Timer? _timer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer(_autoDismiss, _dismiss);
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    _timer?.cancel();
    try {
      // 用 orCancel：卡片可能在退场途中被上层移除（如超出堆叠上限），
      // 此时 Ticker 会被取消，直接结束即可，不要抛未处理异常。
      await _controller.reverse().orCancel;
    } catch (_) {
      return;
    }
    if (mounted) widget.onDismiss();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sender =
        widget.item.sender.trim().isEmpty ? '客户' : widget.item.sender.trim();
    final preview = widget.item.preview.trim().isEmpty
        ? '发来一条消息'
        : widget.item.preview.trim();
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.14, -0.12),
        end: Offset.zero,
      ).animate(_curve),
      child: FadeTransition(
        opacity: _curve,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1).animate(_curve),
          alignment: Alignment.topRight,
          child: MouseRegion(
            onEnter: (_) => _timer?.cancel(),
            onExit: (_) => _startTimer(),
            child: Material(
              color: scheme.surface,
              elevation: 10,
              shadowColor: Colors.black.withAlpha(40),
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () {
                  _timer?.cancel();
                  widget.onOpen();
                  unawaited(_dismiss());
                },
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: scheme.primary.withAlpha(38)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 11, 4, 11),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _Avatar(label: sender, color: scheme.primary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    Expanded(
                                      child: Text(
                                        sender,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w700,
                                          color: scheme.onSurface,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      '新消息',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: scheme.primary,
                                      ),
                                    ),
                                  ]),
                                  const SizedBox(height: 3),
                                  Text(
                                    preview,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      height: 1.35,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '关闭',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                  width: 28, height: 28),
                              iconSize: 16,
                              color: scheme.onSurfaceVariant,
                              onPressed: _dismiss,
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        top: 0,
                        bottom: 0,
                        left: 0,
                        child: Container(width: 3, color: scheme.primary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final first = label.isEmpty
        ? '客'
        : String.fromCharCode(label.runes.first);
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        first,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
