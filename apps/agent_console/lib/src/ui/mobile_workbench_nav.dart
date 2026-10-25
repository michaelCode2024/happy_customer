import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tongyu_agent_console/src/realtime/console_socket.dart';
import 'package:tongyu_agent_console/src/state/session_controller.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/theme.dart';
import 'package:tongyu_agent_console/src/ui/notification_center.dart';
import 'package:tongyu_agent_console/src/util/message_alert_stub.dart'
    if (dart.library.html) 'package:tongyu_agent_console/src/util/message_alert_web.dart';

/// 移动端专属顶部应用栏（MobileTopAppBar）：
/// 提供客服身份头像与在线状态指示、租户工作空间、连接状态与通知/声音控制。
class MobileTopAppBar extends StatelessWidget implements PreferredSizeWidget {
  const MobileTopAppBar({
    super.key,
    required this.session,
    required this.workbench,
    required this.title,
    required this.onNotificationConversation,
    this.onShowQueue,
    this.onTapAvatar,
  });

  final SessionController session;
  final WorkbenchController workbench;
  final String title;
  final ValueChanged<String> onNotificationConversation;
  final VoidCallback? onShowQueue;
  final VoidCallback? onTapAvatar;

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final agent = session.agent;

    return Container(
      height: preferredSize.height + MediaQuery.paddingOf(context).top,
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top,
        left: 12,
        right: 8,
      ),
      decoration: BoxDecoration(
        color: isDark ? theme.colorScheme.surface : Colors.white,
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? theme.colorScheme.outlineVariant.withAlpha(50)
                : const Color(0xFFE8EEF5),
            width: 0.8,
          ),
        ),
      ),
      child: Row(
        children: [
          // 坐席头像与在线状态
          InkWell(
            onTap: onTapAvatar,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.all(4.0),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF3263FF), Color(0xFF5B8CFF)],
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: RelayTheme.blue.withAlpha(50),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      (agent?.displayName.isNotEmpty ?? false)
                          ? agent!.displayName.characters.first
                          : '座',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: workbench.socketState == SocketState.open
                            ? const Color(0xFF10B981)
                            : const Color(0xFFEF4444),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isDark ? theme.colorScheme.surface : Colors.white,
                          width: 1.8,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 标题与租户空间
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: isDark ? theme.colorScheme.onSurface : RelayTheme.ink,
                      ),
                    ),
                    if (workbench.queued > 0) ...[
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: onShowQueue,
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF4E5),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: const Color(0xFFFFD8A8),
                              width: 0.6,
                            ),
                          ),
                          child: Text(
                            '${workbench.queued} 待领',
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFD97706),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  session.tenant?.name ?? '工作空间',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? theme.colorScheme.outline : RelayTheme.muted,
                  ),
                ),
              ],
            ),
          ),
          // 声音开关
          messageSoundButton(),
          // 通知中心
          NotificationCenter(
            api: session.api,
            onConversation: onNotificationConversation,
          ),
        ],
      ),
    );
  }
}

/// 移动端专属底部导航栏（MobileBottomNavBar）：
/// 契合手机单手操作的经典 4 栏布局，支持红点/未读数字角标和原生触感反馈。
class MobileBottomNavBar extends StatelessWidget {
  const MobileBottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.unreadCount,
    this.showKnowledge = true,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final int unreadCount;
  final bool showKnowledge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bottomPadding = MediaQuery.paddingOf(context).bottom;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? theme.colorScheme.surface : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark
                ? theme.colorScheme.outlineVariant.withAlpha(50)
                : const Color(0xFFE8EEF5),
            width: 0.8,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(isDark ? 50 : 12),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      padding: EdgeInsets.only(
        top: 6,
        bottom: bottomPadding > 0 ? bottomPadding : 6,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildNavItem(
            index: 0,
            label: '消息',
            icon: Icons.chat_bubble_outline_rounded,
            activeIcon: Icons.chat_bubble_rounded,
            badgeCount: unreadCount,
          ),
          _buildNavItem(
            index: 1,
            label: '工作台',
            icon: Icons.dashboard_outlined,
            activeIcon: Icons.dashboard_rounded,
          ),
          if (showKnowledge)
            _buildNavItem(
              index: 2,
              label: '知识库',
              icon: Icons.menu_book_outlined,
              activeIcon: Icons.menu_book_rounded,
            ),
          _buildNavItem(
            index: showKnowledge ? 3 : 2,
            label: '设置',
            icon: Icons.settings_outlined,
            activeIcon: Icons.settings_rounded,
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem({
    required int index,
    required String label,
    required IconData icon,
    required IconData activeIcon,
    int? badgeCount,
  }) {
    final selected = currentIndex == index;

    return Expanded(
      child: InkWell(
        onTap: () {
          if (!selected) {
            HapticFeedback.lightImpact();
            onTap(index);
          }
        },
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 3),
                    decoration: BoxDecoration(
                      color: selected
                          ? RelayTheme.blueSoft
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      selected ? activeIcon : icon,
                      size: 22,
                      color: selected
                          ? RelayTheme.blue
                          : const Color(0xFF8E9CAE),
                    ),
                  ),
                  if (badgeCount != null && badgeCount > 0)
                    Positioned(
                      top: -2,
                      right: 2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4.5, vertical: 1),
                        constraints:
                            const BoxConstraints(minWidth: 16, minHeight: 16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF3B30),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white, width: 1.2),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          badgeCount > 99 ? '99+' : '$badgeCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected
                      ? RelayTheme.blue
                      : const Color(0xFF8E9CAE),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
