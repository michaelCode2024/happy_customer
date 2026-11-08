import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/ui/alert_enable_card.dart';
import 'package:tongyu_agent_console/src/ui/desk_bar.dart';
import 'package:tongyu_agent_console/src/ui/desk_notice.dart';
import 'package:tongyu_agent_console/src/util/message_alert_stub.dart'
    if (dart.library.html) 'package:tongyu_agent_console/src/util/message_alert_web.dart';
import 'package:tongyu_agent_console/src/util/push_bridge_stub.dart'
    if (dart.library.html) 'package:tongyu_agent_console/src/util/push_bridge_web.dart';

/// 声音关着、通知还没允许，或推送还没订上，都要提示。
/// 核对还没完成时先不闪。订上之后收起，避免每次刷新再问。
bool showAlertEnableBanner({
  required bool soundOn,
  required bool permissionMissing,
  required bool pushChecked,
  required bool pushNeedsEnable,
}) {
  if (!soundOn) return true;
  if (permissionMissing) return true;
  if (!pushChecked) return false;
  return pushNeedsEnable;
}

/// 工作台顶上的声音和通知引导。
class AlertEnableBanner extends StatefulWidget {
  const AlertEnableBanner({super.key, required this.api});
  final TongYuApi api;

  @override
  State<AlertEnableBanner> createState() => _AlertEnableBannerState();
}

class _AlertEnableBannerState extends State<AlertEnableBanner>
    with WidgetsBindingObserver {
  static const _dismissKey = 'tongyu.alertBannerDismissedAt';
  bool _pushOff = true;
  bool _pushChecked = false;
  bool _busy = false;
  bool _dismissed = false;
  Timer? _recheck;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    messageSoundListenable.addListener(_rebuild);
    deskAlertsListenable.addListener(_rebuild);
    // 引导卡开启推送后立即重新核对，横幅不能还挂着「再允许一次」。
    pushStateListenable.addListener(_onPushState);
    watchDeskAlerts();
    adoptGrantedDeskAlerts();
    unawaited(_refresh());
    if (kIsWeb) {
      // 工作台一直开着时，24 小时的关闭和推送失效都要重新核对，不能只看打开那一次。
      _recheck = Timer.periodic(const Duration(minutes: 10), (_) {
        final state = WidgetsBinding.instance.lifecycleState;
        if (state != null && state != AppLifecycleState.resumed) return;
        unawaited(_refresh());
      });
    }
  }

  @override
  void dispose() {
    _recheck?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    messageSoundListenable.removeListener(_rebuild);
    deskAlertsListenable.removeListener(_rebuild);
    pushStateListenable.removeListener(_onPushState);
    super.dispose();
  }

  void _onPushState() {
    if (mounted) unawaited(_refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _loadDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_dismissKey) ?? 0;
      final dismissed = last != 0 &&
          DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(last)) <
              const Duration(hours: 24);
      if (mounted && dismissed != _dismissed) setState(() => _dismissed = dismissed);
    } catch (_) {}
  }

  Future<void> _dismiss() async {
    setState(() => _dismissed = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_dismissKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  Future<void> _refresh() async {
    adoptGrantedDeskAlerts();
    await _loadDismissed();
    final off = await pushNeedsEnable(widget.api);
    if (!mounted) return;
    setState(() {
      _pushChecked = true;
      _pushOff = off;
    });
  }

  Future<void> _open() async {
    if (_busy) return;
    // 先发起浏览器授权和订阅。先播声音会用掉这次点击，Chrome 弹窗不会出现。
    final opening = enableBackgroundPush(widget.api);
    setState(() => _busy = true);
    turnMessageSoundOn();
    final message = await opening;
    rememberDeskAlerts();
    await _refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    if (_openedNow()) {
      showDeskNotice(context, '声音和消息通知已打开',
          icon: Icons.check_circle_rounded, accent: const Color(0xFF12B886));
      return;
    }
    if (_browserPromptBlocked(message) && mounted) {
      final granted = await showBrowserNotificationSettings(context);
      if (!mounted) return;
      if (granted) {
        final again = await enableBackgroundPush(widget.api);
        rememberDeskAlerts();
        await _refresh();
        if (!mounted) return;
        showDeskNotice(
            context, _openedNow() ? '声音和消息通知已打开' : again);
        return;
      }
    }
    showDeskNotice(context, message);
  }

  bool _openedNow() => !showAlertEnableBanner(
        soundOn: messageSoundEnabled,
        permissionMissing: notificationPermissionMissing,
        pushChecked: _pushChecked,
        pushNeedsEnable: _pushOff,
      );

  /// 浏览器把授权弹窗吞掉或已经拒绝时，站点设置才是还能打开的路。
  /// 「再点一次」是注册还没备好，下一次点击仍可能弹出系统授权，先不改走设置。
  bool _browserPromptBlocked(String message) {
    if (notificationPermission == 'denied') return true;
    if (message.contains('再点一次')) return false;
    return notificationPermission != 'granted' &&
        (message.contains('未获得') ||
            message.contains('未获允许') ||
            message.contains('被阻止') ||
            message.contains('站点设置'));
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final soundOn = messageSoundEnabled;
    final missing = notificationPermissionMissing;
    if (!showAlertEnableBanner(
      soundOn: soundOn,
      permissionMissing: missing,
      pushChecked: _pushChecked,
      pushNeedsEnable: _pushOff,
    )) {
      return const SizedBox.shrink();
    }
    final finishPush = soundOn && !missing && _pushChecked && _pushOff;
    return DeskBar(
      tone: DeskBarTone.amber,
      message: finishPush
          ? '通知已允许。再点一次完成订阅，关掉页面后仍能收到消息'
          : '请打开声音和消息通知，离开页面也能知道是谁发来了消息',
      actionLabel: finishPush ? '完成订阅' : '立即打开',
      onAction: _open,
      onClose: _dismiss,
      busy: _busy,
    );
  }
}
