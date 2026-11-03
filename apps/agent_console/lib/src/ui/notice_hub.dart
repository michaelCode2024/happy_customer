import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/theme.dart';
import 'package:tongyu_agent_console/src/util/notice.dart';

/// 右下角统一通知宿主：监听 [NoticeHubController]，把每条通知渲染成
/// 统一规格的卡片或胶囊。
///
/// - 贴在窗口右下角，窄屏抬到导航栏上方；
/// - 卡片固定 320px、左侧主题色竖条，胶囊宽度自适应；
/// - 新的一条靠下，最多 [NoticeHubController.maxVisible] 张；
/// - 到点自动收起，鼠标悬停暂停计时。
class NoticeHub extends StatelessWidget {
  const NoticeHub({super.key, required this.controller, this.onOpen});

  final NoticeHubController controller;

  /// 点击卡片或动作按钮时回调，参数是 [NoticeItem.openId]。
  final ValueChanged<String>? onOpen;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final items = controller.items;
        if (items.isEmpty) return const SizedBox.shrink();
        final width = MediaQuery.sizeOf(context).width;
        final cardWidth = math.min(320.0, width - 24);
        final narrow = width < 900;
        final bottom = 12.0 +
            MediaQuery.paddingOf(context).bottom +
            (narrow ? 64.0 : 0.0);
        return Stack(
          children: [
            Positioned(
              right: 12,
              bottom: bottom,
              child: SizedBox(
                width: cardWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final item in items)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: _NoticeTile(
                          key: ValueKey<String>(item.id),
                          item: item,
                          onOpen: onOpen ?? controller.onOpen,
                          onDismiss: () => controller.dismiss(item.id),
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

class _NoticeTile extends StatefulWidget {
  const _NoticeTile({
    super.key,
    required this.item,
    required this.onOpen,
    required this.onDismiss,
  });

  final NoticeItem item;
  final ValueChanged<String>? onOpen;
  final VoidCallback onDismiss;

  @override
  State<_NoticeTile> createState() => _NoticeTileState();
}

class _NoticeTileState extends State<_NoticeTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  Timer? _timer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _restartTimer();
  }

  @override
  void didUpdateWidget(covariant _NoticeTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 聚合计数变化：以新文案重新入场并重置计时，别让卡片悄无声息地变字。
    if (widget.item.count != oldWidget.item.count) {
      _closing = false;
      _controller.forward(from: 0);
      _restartTimer();
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer(widget.item.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (_closing) return;
    _closing = true;
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

  void _open() {
    _timer?.cancel();
    final onAction = widget.item.onAction;
    if (onAction != null) {
      onAction();
    } else {
      final id = widget.item.openId;
      if (id != null && id.isNotEmpty) widget.onOpen?.call(id);
    }
    unawaited(_dismiss());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.14, 0.12),
        end: Offset.zero,
      ).animate(_curve),
      child: FadeTransition(
        opacity: _curve,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1).animate(_curve),
          alignment: Alignment.bottomRight,
          child: MouseRegion(
            onEnter: (_) => _timer?.cancel(),
            onExit: (_) => _restartTimer(),
            child: widget.item.kind == NoticeKind.card
                ? _buildCard()
                : _buildToast(),
          ),
        ),
      ),
    );
  }

  Widget _buildCard() {
    final scheme = Theme.of(context).colorScheme;
    final item = widget.item;
    final accent = item.accent ?? scheme.primary;
    final openable = item.onAction != null ||
        (item.openId?.isNotEmpty ?? false) ||
        item.actionLabel != null;
    final body = item.body?.trim() ?? '';
    return Material(
      color: scheme.surface,
      elevation: 8,
      shadowColor: Colors.black.withAlpha(40),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: openable ? _open : null,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withAlpha(38)),
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 4, 9),
                child: Row(
                  children: [
                    _NoticeGlyph(item: item, accent: accent),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: RelayTheme.uiText(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.onSurface,
                                  ),
                                ),
                              ),
                              if (item.count > 1) ...[
                                const SizedBox(width: 6),
                                _CountBadge(item: item, accent: accent),
                              ],
                            ],
                          ),
                          if (body.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              body,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: RelayTheme.uiText(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (item.actionLabel != null) ...[
                      const SizedBox(width: 6),
                      _PillAction(
                          item: item, accent: accent, onTap: _open),
                    ],
                    if (item.dismissible)
                      IconButton(
                        tooltip: '关闭',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                            width: 26, height: 26),
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
                child: Container(width: 3, color: accent),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToast() {
    final scheme = Theme.of(context).colorScheme;
    final item = widget.item;
    final accent = item.accent ?? scheme.primary;
    return Material(
      color: scheme.surface,
      elevation: 4,
      shadowColor: Colors.black.withAlpha(30),
      shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
      child: InkWell(
        onTap: item.dismissible ? () => unawaited(_dismiss()) : null,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 7, 6, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(item.icon ?? Icons.info_outline, size: 15, color: accent),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RelayTheme.uiText(
                    fontSize: 12.5,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              if (item.actionLabel != null) ...[
                const SizedBox(width: 2),
                TextButton(
                  onPressed: _open,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: accent,
                  ),
                  child: Text(item.actionLabel!),
                ),
              ],
              if (item.dismissible)
                IconButton(
                  tooltip: '关闭',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                      width: 24, height: 24),
                  iconSize: 15,
                  color: scheme.onSurfaceVariant,
                  onPressed: _dismiss,
                  icon: const Icon(Icons.close_rounded),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeGlyph extends StatelessWidget {
  const _NoticeGlyph({required this.item, required this.accent});

  final NoticeItem item;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final label = item.avatarLabel?.trim();
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: accent.withAlpha(26),
        borderRadius: BorderRadius.circular(9),
      ),
      child: label != null && label.isNotEmpty
          ? Text(
              String.fromCharCode(label.runes.first),
              style: RelayTheme.uiText(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            )
          : Icon(item.icon ?? Icons.notifications_none_rounded,
              size: 16, color: accent),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.item, required this.accent});

  final NoticeItem item;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: accent.withAlpha(22),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${item.count} ${item.countUnit}',
        style: RelayTheme.uiText(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: accent,
        ),
      ),
    );
  }
}

class _PillAction extends StatelessWidget {
  const _PillAction({
    required this.item,
    required this.accent,
    required this.onTap,
  });

  final NoticeItem item;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: accent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Text(
            item.actionLabel!,
            style: RelayTheme.uiText(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
