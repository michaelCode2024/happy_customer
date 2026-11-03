import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/ui/desk_bar.dart';

/// 跨页面保留接待入口；仅显式点击查看才导航，不抢走客服当前的会话。
class ReceptionGuidance extends StatelessWidget {
  const ReceptionGuidance(
      {super.key,
      required this.workbench,
      required this.onShowQueue,
      required this.onOpen,
      required this.child});

  final WorkbenchController workbench;
  final VoidCallback onShowQueue;
  final ValueChanged<Conversation> onOpen;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final notice = workbench.receptionNotice;
    final waiting = workbench.receptionWaiting;
    // Build the label explicitly so web semantics never drop the digit.
    final waitingLabel = '有 ${waiting.toString()} 位客户正在等待接待';
    // 有等待人数时并进顶栏横幅；新客户到达的即时提醒走右下角通知。
    final showTopBanner = waiting > 0;

    return Column(children: [
        if (showTopBanner)
          DeskBar(
            key: const ValueKey('reception-waiting-banner'),
            tone: DeskBarTone.amber,
            message: waitingLabel,
            messageKey: ValueKey<String>('reception-waiting-count-$waiting'),
            detail: notice == null
                ? '队列里有可领取或待你确认的会话，请及时响应'
                : '最新待接待：${notice.title}',
            actionLabel: '查看并接待',
            actionKey: ValueKey(notice != null
                ? 'reception-banner-open-notice'
                : 'reception-banner-show-queue'),
            onAction: notice != null ? () => onOpen(notice) : onShowQueue,
          ),
        Expanded(child: child),
      ]);
  }
}

/// 待接待底部操作坞：单行文案 + 写备注 / 开始接待，替代高大卡与禁用输入区。
///
/// 已派给本人、但还没确认接单时，这里显示接单倒计时：服务端超时会把会话收回
/// 并重新分配，客服看不到剩余时间就只能干等着「开始接待」突然消失。
class ReceptionAction extends StatefulWidget {
  const ReceptionAction({
    super.key,
    required this.conversation,
    required this.busy,
    required this.onClaim,
    this.onWriteNote,
    this.onExpired,
  });

  final Conversation conversation;
  final bool busy;
  final VoidCallback onClaim;
  final VoidCallback? onWriteNote;

  /// 倒计时归零时回调一次，由外层同步真实归属（会话可能已被系统收回）。
  final VoidCallback? onExpired;

  @override
  State<ReceptionAction> createState() => _ReceptionActionState();
}

class _ReceptionActionState extends State<ReceptionAction> {
  Timer? _ticker;
  Duration _left = Duration.zero;
  bool _expiredFired = false;

  bool get _waitingAccept => widget.conversation.needsAcceptance;

  @override
  void initState() {
    super.initState();
    _syncCountdown();
  }

  @override
  void didUpdateWidget(covariant ReceptionAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.conversation;
    final now = widget.conversation;
    if (before.id != now.id ||
        before.assignmentExpiresAt != now.assignmentExpiresAt ||
        before.acceptedAt != now.acceptedAt) {
      _expiredFired = false;
      _syncCountdown();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncCountdown() {
    _ticker?.cancel();
    _ticker = null;
    if (!_waitingAccept) {
      _left = Duration.zero;
      return;
    }
    _tick();
    if (_left > Duration.zero) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    }
  }

  void _tick() {
    final expires = widget.conversation.assignmentExpiresAt;
    if (expires == null) {
      if (mounted) setState(() => _left = Duration.zero);
      return;
    }
    final left = expires.difference(DateTime.now());
    if (!mounted) return;
    setState(() => _left = left.isNegative ? Duration.zero : left);
    if (left > Duration.zero) return;
    _ticker?.cancel();
    _ticker = null;
    if (_expiredFired) return;
    _expiredFired = true;
    // 超时那一秒先让界面自己说清楚，再让外层重新拉一次真实归属。
    final notify = widget.onExpired;
    if (notify != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) notify();
      });
    }
  }

  String _leftLabel(Duration left) {
    final seconds = left.inSeconds;
    if (seconds >= 60) {
      final minutes = seconds ~/ 60;
      final rest = seconds % 60;
      return rest == 0 ? '$minutes 分钟' : '$minutes 分 $rest 秒';
    }
    return '$seconds 秒';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final waitingAccept = _waitingAccept;
    final expired = waitingAccept && _left == Duration.zero;
    final urgent = waitingAccept && !expired && _left.inSeconds <= 10;
    final (title, hint) = switch ((waitingAccept, expired)) {
      (false, _) => ('客户正在等待', '开始接待后即可回复；内部备注可先写'),
      (true, true) => ('接单已超时', '会话正在重新分配，列表会自动刷新'),
      (true, false) => (
          '请确认接单',
          '还剩 ${_leftLabel(_left)}，超时会自动转给其他客服'
        ),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            colors.primaryContainer.withOpacity(0.22),
            colors.surface,
          ],
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (waitingAccept && !expired) ...[
                      Icon(Icons.timer_outlined,
                          size: 14,
                          color: urgent ? colors.error : colors.primary),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                          height: 1.3,
                          color: expired ? colors.error : null,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: urgent || expired
                        ? colors.error
                        : colors.onSurfaceVariant,
                    fontWeight: urgent ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
          if (widget.onWriteNote != null) ...[
            TextButton(
              onPressed: widget.busy ? null : widget.onWriteNote,
              child: const Text('写备注'),
            ),
            const SizedBox(width: 4),
          ],
          FilledButton(
            onPressed: widget.busy || expired ? null : widget.onClaim,
            child: widget.busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(expired
                    ? '已超时'
                    : widget.conversation.receptionActionLabel),
          ),
        ],
      ),
    );
  }
}
