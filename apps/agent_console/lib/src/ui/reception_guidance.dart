import 'package:flutter/material.dart';
import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/state/workbench_controller.dart';

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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final notice = workbench.receptionNotice;
    return Stack(children: [
      Column(children: [
        if (workbench.receptionWaiting > 0)
          Container(
              key: const ValueKey('reception-waiting-banner'),
              width: double.infinity,
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                  color:
                      dark ? const Color(0xFF392C1B) : const Color(0xFFFFF6E9),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: dark
                          ? const Color(0xFF68502D)
                          : const Color(0xFFF0DBB8))),
              child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('有 ${workbench.receptionWaiting} 位客户正在等待接待',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: colors.onSurface)),
                          const SizedBox(height: 4),
                          Text('包含待领取和派给你的待确认会话，请及时回应',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant)),
                        ]),
                    OutlinedButton(
                        onPressed: onShowQueue, child: const Text('查看待接待 →')),
                  ])),
        Expanded(child: child),
      ]),
      if (notice != null)
        Positioned(
            right: 12,
            bottom: 12,
            child: SizedBox(
                width: (MediaQuery.sizeOf(context).width - 24)
                    .clamp(0, 340)
                    .toDouble(),
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
                                    onPressed: workbench.dismissReceptionNotice,
                                    icon: const Icon(Icons.close, size: 18)),
                              ]),
                              Text(notice.title,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
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
                              Text('查看后点击「${notice.receptionActionLabel}」才会接单',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: colors.onSurfaceVariant)),
                            ]))))),
    ]);
  }
}

/// 在原有输入区上方直接提供接单操作，内部备注及未发送草稿继续保留。
class ReceptionAction extends StatelessWidget {
  const ReceptionAction(
      {super.key,
      required this.conversation,
      required this.busy,
      required this.onClaim});
  final Conversation conversation;
  final bool busy;
  final VoidCallback onClaim;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
            color: colors.primaryContainer.withOpacity(.25),
            border: Border(top: BorderSide(color: colors.outlineVariant))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(conversation.needsAcceptance ? '这位客户已分配给你，等待确认接单' : '这位客户正在等你回应',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 5),
          Text(
              conversation.needsAcceptance
                  ? '确认后即可回复客户，请及时接单。'
                  : '点击开始接待，将会话分配给自己，即可回复客户。',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
          const SizedBox(height: 10),
          FilledButton.icon(
              onPressed: busy ? null : onClaim,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.support_agent, size: 18),
              label: Text(
                  busy ? '正在接待…' : '${conversation.receptionActionLabel}并回复')),
        ]));
  }
}
