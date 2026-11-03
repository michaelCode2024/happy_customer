import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/util/notice.dart';

/// 把右下角通知宿主放到整棵页面之上，对话框里的反馈也能找到它。
class DeskNoticeScope extends InheritedWidget {
  const DeskNoticeScope({
    super.key,
    required this.hub,
    required super.child,
  });

  final NoticeHubController hub;

  static NoticeHubController? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<DeskNoticeScope>()?.hub;
  }

  @override
  bool updateShouldNotify(DeskNoticeScope oldWidget) => hub != oldWidget.hub;
}

/// 结果类反馈。有宿主时进右下角胶囊或卡片，没有宿主时退回底部条。
void showDeskNotice(
  BuildContext context,
  String message, {
  NoticeKind kind = NoticeKind.toast,
  String? actionLabel,
  VoidCallback? onAction,
  IconData? icon,
  Color? accent,
  Duration? duration,
}) {
  final trimmed = message.trim();
  if (trimmed.isEmpty) return;
  final hub = DeskNoticeScope.maybeOf(context);
  if (hub == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trimmed)));
    return;
  }
  hub.show(NoticeItem(
    id: 'desk-${DateTime.now().microsecondsSinceEpoch}',
    kind: kind,
    title: trimmed,
    actionLabel: actionLabel,
    onAction: onAction,
    icon: icon,
    accent: accent,
    duration: duration,
  ));
}
