import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/theme.dart';
import 'package:tongyu_agent_console/src/util/message_alert_stub.dart'
    if (dart.library.html) 'package:tongyu_agent_console/src/util/message_alert_web.dart';
import 'package:tongyu_agent_console/src/util/push_bridge_stub.dart'
    if (dart.library.html) 'package:tongyu_agent_console/src/util/push_bridge_web.dart';

/// 引导卡当前该说什么。
///
/// - [enable]：还没问过权限，点一下就能请求授权；
/// - [openSettings]：浏览器已经拒绝，JS 无法再弹授权框，只能引导去设置；
/// - [finishPush]：通知已允许，但后台推送没订上，关掉标签就收不到。
enum AlertCardStage { enable, openSettings, finishPush }

/// 决定是否弹卡、弹哪一版。
///
/// 核对推送状态期间（[pushChecked] 为 false）先不弹，避免工作台刚打开时闪一下。
AlertCardStage? alertCardStage({
  required String permission,
  required bool pushChecked,
  required bool pushOff,
}) {
  if (permission == 'unsupported') return null;
  if (permission == 'denied') return AlertCardStage.openSettings;
  if (permission == 'default') return AlertCardStage.enable;
  if (!pushChecked) return null;
  return pushOff ? AlertCardStage.finishPush : null;
}

class _CardCopy {
  const _CardCopy(this.title, this.body, this.action);
  final String title;
  final String body;
  final String action;
}

const Map<AlertCardStage, _CardCopy> _copies = {
  AlertCardStage.enable: _CardCopy(
    '开启桌面通知',
    '允许浏览器通知后，离开页面也能第一时间收到客户消息提醒。',
    '立即开启',
  ),
  AlertCardStage.openSettings: _CardCopy(
    '开启桌面通知',
    '前往系统设置开启桌面通知，第一时间获取任务状态提醒。',
    '前往系统设置',
  ),
  AlertCardStage.finishPush: _CardCopy(
    '再允许一次浏览器推送',
    '桌面通知已打开。再允许一次浏览器推送，关掉页面后仍能收到消息。',
    '继续开启',
  ),
};

/// 居中引导卡：白底圆角、粗标题、右上关闭、灰正文、右下黑底按钮。
class AlertEnableCard extends StatefulWidget {
  const AlertEnableCard({
    super.key,
    required this.stage,
    required this.onAction,
    required this.onClose,
  });

  final AlertCardStage stage;

  /// 返回 null 表示处理完成并关闭卡片；返回文字则保留卡片并提示该文案。
  final Future<String?> Function() onAction;
  final VoidCallback onClose;

  @override
  State<AlertEnableCard> createState() => _AlertEnableCardState();
}

class _AlertEnableCardState extends State<AlertEnableCard> {
  bool _busy = false;
  String? _status;

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final message = await widget.onAction();
      if (!mounted) return;
      if (message == null) {
        widget.onClose();
      } else {
        setState(() => _status = message);
      }
    } catch (error) {
      if (!mounted) return;
      final text = error.toString().replaceFirst('Exception: ', '').trim();
      setState(() => _status = text.isEmpty ? '操作未完成，请稍后重试' : text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = _copies[widget.stage]!;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 460,
        constraints: const BoxConstraints(maxWidth: 460),
        padding: const EdgeInsets.fromLTRB(26, 22, 16, 22),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFEFF1F4)),
          boxShadow: const [
            BoxShadow(
                color: Color(0x1F0C1D40),
                blurRadius: 40,
                offset: Offset(0, 14)),
            BoxShadow(
                color: Color(0x0A0C1D40), blurRadius: 6, offset: Offset(0, 2)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    copy.title,
                    style: RelayTheme.uiText(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF0B0B0F),
                      height: 1.35,
                    ),
                  ),
                ),
                _CloseButton(onTap: widget.onClose),
              ],
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                copy.body,
                style: RelayTheme.uiText(
                  fontSize: 14.5,
                  color: const Color(0xFF8A9099),
                  height: 1.75,
                ),
              ),
            ),
            if (_status != null) ...[
              const SizedBox(height: 10),
              Text(
                _status!,
                style: RelayTheme.uiText(
                  fontSize: 12.5,
                  color: const Color(0xFFE5484D),
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: _CardAction(
                  label: copy.action,
                  busy: _busy,
                  onTap: _run,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkResponse(
        onTap: onTap,
        radius: 20,
        child: const Padding(
          padding: EdgeInsets.all(4),
          child: Icon(Icons.close_rounded, size: 20, color: Color(0xFF17181A)),
        ),
      );
}

class _CardAction extends StatelessWidget {
  const _CardAction(
      {required this.label, required this.busy, required this.onTap});
  final String label;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFF101114),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
            child: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Text(
                    label,
                    style: RelayTheme.uiText(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
          ),
        ),
      );
}

/// 工作台上的引导卡宿主：只在浏览器里、且确实需要动作时弹一次。
///
/// 关掉后 24 小时内不再自动弹，避免每次刷新都盖住工作台；
/// 顶部黄色横幅仍然保留，作为持续提醒。
class AlertEnableCardHost extends StatefulWidget {
  const AlertEnableCardHost({super.key, required this.api});
  final TongYuApi api;

  @override
  State<AlertEnableCardHost> createState() => _AlertEnableCardHostState();
}

class _AlertEnableCardHostState extends State<AlertEnableCardHost> {
  static const _promptKey = 'tongyu.alertCardPromptAt';
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybePrompt());
    });
  }

  Future<void> _maybePrompt() async {
    if (_shown || !mounted || !kIsWeb) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    if (await _promptedRecently()) return;
    if (!mounted) return;

    final permission = notificationPermission;
    AlertCardStage? stage;
    if (permission == 'default') {
      stage = AlertCardStage.enable;
    } else if (permission == 'denied') {
      stage = AlertCardStage.openSettings;
    } else if (permission == 'granted') {
      var pushOff = false;
      try {
        pushOff = await pushNeedsEnable(widget.api);
      } catch (_) {
        return;
      }
      if (!mounted) return;
      stage = alertCardStage(
          permission: permission, pushChecked: true, pushOff: pushOff);
    }
    if (stage == null) return;

    // 等首帧和工作台骨架渲染完，避免卡片盖住加载态。
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    _shown = true;
    await _present(stage);
  }

  Future<void> _present(AlertCardStage stage) async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '开启桌面通知',
      barrierColor: const Color(0x330C1D40),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, __) => Center(
        child: AlertEnableCard(
          stage: stage,
          onAction: () => _runAction(ctx, stage),
          onClose: () => Navigator.of(ctx).pop(),
        ),
      ),
      transitionBuilder: (ctx, animation, _, child) {
        final curved =
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
    // 无论点按钮还是点 ×，都记一次；否则下次刷新又会弹。
    await _rememberPrompt();
  }

  Future<String?> _runAction(BuildContext ctx, AlertCardStage stage) async {
    if (stage == AlertCardStage.openSettings) {
      final granted = await _showSettingsHelp(ctx);
      if (!granted) return '还没有检测到通知权限，请按步骤开启后重试';
    }
    if (stage == AlertCardStage.enable) {
      final permission = await requestNotificationPermission();
      if (permission != 'granted') {
        return '浏览器未允许通知，请在站点设置中允许后重试';
      }
    }
    turnMessageSoundOn();
    rememberDeskAlerts();
    final message = await enableBackgroundPush(widget.api);
    // 不靠返回文案判断成败：回读一次订阅状态，失败时把原因留在卡片上。
    var stillOff = true;
    try {
      stillOff = await pushNeedsEnable(widget.api);
    } catch (_) {}
    notifyPushStateChanged();
    if (stillOff) return message;
    if (!mounted) return null;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    return null;
  }

  Future<bool> _showSettingsHelp(BuildContext ctx) async {
    final granted = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('在浏览器中允许通知'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < _settingsSteps.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                            radius: 11,
                            child: Text('${i + 1}',
                                style: const TextStyle(fontSize: 11))),
                        const SizedBox(width: 10),
                        Expanded(child: Text(_settingsSteps[i])),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false), child: const Text('稍后')),
          FilledButton(
            onPressed: () => Navigator.pop(c, notificationPermission == 'granted'),
            child: const Text('重新检查'),
          ),
        ],
      ),
    );
    return granted == true;
  }

  List<String> get _settingsSteps {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return const [
          '打开手机「设置」→「通知」→ 找到浏览器或已添加到主屏幕的通语',
          '打开「允许通知」，并勾选声音与横幅',
          '回到这里点「重新检查」',
        ];
      case TargetPlatform.android:
        return const [
          '点地址栏左侧的锁图标 →「权限」→ 通知 → 允许',
          '若浏览器整体被禁，打开手机「设置」→「应用」→ 浏览器 →「通知」中允许',
          '回到这里点「重新检查」',
        ];
      default:
        return const [
          '点地址栏左侧的锁或滑块图标 →「网站设置」→「通知」→ 选择「允许」',
          'macOS 还需在「系统设置」→「通知」中允许浏览器通知',
          'Windows 请确认「专注助手 / 勿扰」没有拦截通知',
          '改完回到这里点「重新检查」',
        ];
    }
  }

  Future<bool> _promptedRecently() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_promptKey) ?? 0;
      if (last == 0) return false;
      return DateTime.now()
              .difference(DateTime.fromMillisecondsSinceEpoch(last)) <
          const Duration(hours: 24);
    } catch (_) {
      return false;
    }
  }

  Future<void> _rememberPrompt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_promptKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
