import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';

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
    final colors = Theme.of(context).colorScheme;
    final notice = workbench.receptionNotice;
    final waiting = workbench.receptionWaiting;
    // Build the label explicitly so web semantics never drop the digit.
    final waitingLabel =
        '有 ${waiting.toString()} 位客户正在等待接待';
    // 同一时刻只留一条接待提示：有等待人数时用顶栏，右下角卡片让开；
    // 标记解决的反馈条出现时也先藏起卡片，避免挡住会话操作。
    final showTopBanner = waiting > 0;
    final showArrivalCard = notice != null &&
        !showTopBanner &&
        !workbench.suppressReceptionFab;
    final size = MediaQuery.sizeOf(context);
    // 卡片落在偏下区域，避免盖住会话标题栏上的操作。
    final cardBottom = (size.height * 0.08).clamp(12.0, 48.0);

    return Stack(children: [
      Column(children: [
        if (showTopBanner)
          Container(
              key: const ValueKey('reception-waiting-banner'),
              width: double.infinity,
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                  color: const Color(0xFFFFF6E9),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFF0DBB8))),
              child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(waitingLabel,
                              key: ValueKey<String>('reception-waiting-count-$waiting'),
                              semanticsLabel: waitingLabel,
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: colors.onSurface)),
                          const SizedBox(height: 4),
                          Text(
                              notice == null
                                  ? '队列里有可领取或待你确认的会话，请及时响应'
                                  : '最新待接待：${notice.title}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant)),
                        ]),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (notice != null)
                          FilledButton(
                            key: const ValueKey('reception-banner-open-notice'),
                            onPressed: () => onOpen(notice),
                            child: const Text('查看并接待'),
                          ),
                        OutlinedButton(
                            key: const ValueKey('reception-banner-show-queue'),
                            onPressed: onShowQueue,
                            child: const Text('查看待接待 →')),
                      ],
                    ),
                  ])),
        Expanded(child: child),
      ]),
      if (showArrivalCard)
        Positioned(
            right: 12,
            bottom: cardBottom,
            child: SafeArea(
              child: SizedBox(
                  width: (size.width - 24).clamp(0, 340).toDouble(),
                  child: Material(
                      elevation: 3,
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                          key: const ValueKey('reception-arrival-notice'),
                          padding: const EdgeInsets.fromLTRB(18, 10, 12, 18),
                          decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: colors.primary.withOpacity(.35))),
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Icon(Icons.support_agent,
                                      size: 20, color: colors.primary),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                      child: Text('有客户等待接待',
                                          style: TextStyle(
                                              fontWeight: FontWeight.w700))),
                                  IconButton(
                                      tooltip: '关闭接待提醒',
                                      onPressed:
                                          workbench.dismissReceptionNotice,
                                      icon:
                                          const Icon(Icons.close, size: 18)),
                                ]),
                                Text(notice.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 6),
                                Text(workbench.receptionNoticePreview,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: colors.onSurfaceVariant)),
                                const SizedBox(height: 14),
                                SizedBox(
                                    width: double.infinity,
                                    child: FilledButton(
                                        onPressed: () => onOpen(notice),
                                        child: const Text('查看并接待'))),
                                const SizedBox(height: 8),
                                Text(
                                    '查看后点击「${notice.receptionActionLabel}」才会接单',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: colors.onSurfaceVariant)),
                              ])))),
            )),
    ]);
  }

}

/// 待接待底部操作坞：单行文案 + 写备注 / 开始接待，替代高大卡与禁用输入区。
class ReceptionAction extends StatelessWidget {
  const ReceptionAction({
    super.key,
    required this.conversation,
    required this.busy,
    required this.onClaim,
    this.onWriteNote,
  });

  final Conversation conversation;
  final bool busy;
  final VoidCallback onClaim;
  final VoidCallback? onWriteNote;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final waitingAccept = conversation.needsAcceptance;
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
                Text(
                  waitingAccept ? '请确认接单' : '客户正在等待',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  waitingAccept
                      ? '确认后即可回复客户；内部备注可先写'
                      : '开始接待后即可回复；内部备注可先写',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (onWriteNote != null) ...[
            TextButton(
              onPressed: busy ? null : onWriteNote,
              child: const Text('写备注'),
            ),
            const SizedBox(width: 4),
          ],
          FilledButton(
            onPressed: busy ? null : onClaim,
            child: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(conversation.receptionActionLabel),
          ),
        ],
      ),
    );
  }
}
