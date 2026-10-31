import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/util/message_alert_stub.dart'
    if (dart.library.html) 'package:tongyu_agent_console/src/util/message_alert_web.dart';
import 'package:tongyu_agent_console/src/util/push_bridge_stub.dart'
    if (dart.library.html) 'package:tongyu_agent_console/src/util/push_bridge_web.dart';

/// 声音关着，或浏览器还没允许通知，都要提示。
/// 推送订阅还在核对时先不闪。
/// 桌面通知已经打开、浏览器推送还没订上时仍要提示，否则关掉标签就收不到。
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
  bool _pushOff = true;
  bool _pushChecked = false;
  bool _busy = false;

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
  }

  @override
  void dispose() {
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

  Future<void> _refresh() async {
    adoptGrantedDeskAlerts();
    final off = await pushNeedsEnable(widget.api);
    if (!mounted) return;
    setState(() {
      _pushChecked = true;
      _pushOff = off;
    });
  }

  Future<void> _open() async {
    if (_busy) return;
    setState(() => _busy = true);
    turnMessageSoundOn();
    final message = await enableBackgroundPush(widget.api);
    rememberDeskAlerts();
    await _refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    final opened = !showAlertEnableBanner(
      soundOn: messageSoundEnabled,
      permissionMissing: notificationPermissionMissing,
      pushChecked: _pushChecked,
      pushNeedsEnable: _pushOff,
    );
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(opened ? '声音和消息通知已打开' : message)));
  }

  @override
  Widget build(BuildContext context) {
    final soundOn = messageSoundEnabled;
    final deskOn = deskAlertsGranted;
    final missing = notificationPermissionMissing;
    if (!showAlertEnableBanner(
      soundOn: soundOn,
      permissionMissing: missing,
      pushChecked: _pushChecked,
      pushNeedsEnable: _pushOff,
    )) {
      return const SizedBox.shrink();
    }
    final pushGap = soundOn && deskOn && !missing && _pushChecked && _pushOff;
    return Material(
      color: const Color(0xFFFFF4D6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          Expanded(
            child: Text(
              pushGap
                  ? '桌面通知已打开。再允许一次浏览器推送，关掉页面后仍能收到消息'
                  : '请打开声音和消息通知，离开页面也能知道是谁发来了消息',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF7A4E00)),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _busy ? null : _open,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE8A317),
              foregroundColor: const Color(0xFF3D2A00),
              visualDensity: VisualDensity.compact,
            ),
            child: Text(_busy ? '正在打开…' : '立即打开'),
          ),
        ]),
      ),
    );
  }
}
