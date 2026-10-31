import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/util/message_sound_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('tongyu/alerts');
final _enabled = ValueNotifier(true);
String _style = 'sender';
DateTime? _quietUntil;
void setMessageQuietUntil(DateTime? until) {
  _quietUntil = until;
  if (defaultTargetPlatform == TargetPlatform.android) {
    _channel.invokeMethod<void>('quiet',
        {'until': until?.millisecondsSinceEpoch ?? 0}).catchError((_) {});
  }
}

bool pageVisible() => true;
void initializeMessageAlerts() {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  _channel.invokeMapMethod<String, dynamic>('settings').then((value) {
    if (value != null) {
      _style = value['style'] as String? ?? 'sender';
      _enabled.value = value['enabled'] != false;
    }
  }).catchError((_) {});
}

bool get messageSoundEnabled => _enabled.value;
Listenable get messageSoundListenable => _enabled;
void turnMessageSoundOn() {
  if (_enabled.value) return;
  _enabled.value = true;
  _channel.invokeMethod<void>(
      'saveSettings', {'enabled': true, 'style': _style}).catchError((_) {});
}

final _deskAlerts = ValueNotifier(false);
bool get deskAlertsGranted => _deskAlerts.value;
Listenable get deskAlertsListenable => _deskAlerts;

/// 安装包走系统通知渠道，没有浏览器权限这一档。
bool get notificationPermissionMissing => false;

/// 安装包由系统渠道负责，等同已授权；引导卡只在浏览器里出现。
String get notificationPermission => 'granted';

Future<String> requestNotificationPermission() async => 'granted';
void adoptGrantedDeskAlerts() {}
void watchDeskAlerts() {}
void rememberDeskAlerts() {}

void messageAlert(String name, String body, {String senderName = ''}) {
  if (_quietUntil?.isAfter(DateTime.now()) == true) return;
  if (defaultTargetPlatform != TargetPlatform.android || !_enabled.value)
    return;
  _channel.invokeMethod<void>(
      'alert', {'id': name, 'sender': senderName}).catchError((_) {});
}

/// 是否已豁免系统电池优化（即「不受限制」）。非安卓或查询失败时按未豁免处理。
Future<bool> isBatteryOptimizationExempt() async {
  if (defaultTargetPlatform != TargetPlatform.android) return true;
  try {
    final value = await _channel
        .invokeMapMethod<String, dynamic>('batteryOptimizationState');
    return value?['exempt'] == true;
  } catch (_) {
    return false;
  }
}

/// 跳转到系统电池优化设置，引导用户把通语设为不受限制。返回是否成功拉起设置页。
Future<bool> openBatteryOptimizationSettings() async {
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    await _channel.invokeMethod<void>('openBatterySettings');
    return true;
  } catch (_) {
    return false;
  }
}

Widget messageSoundButton({TongYuApi? api}) => Builder(
    builder: (context) => IconButton(
        tooltip: '声音提醒与发送者播报',
        icon: const Icon(Icons.record_voice_over_outlined),
        onPressed: () => showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
                    title: const Text('声音提醒'),
                    content: SizedBox(
                        width: 430,
                        child: SingleChildScrollView(
                            child: messageAlertSettings(api: api))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('完成'))
                    ]))));
Widget messageAlertSettings({TongYuApi? api}) => StatefulBuilder(
    builder: (context, refresh) => ValueListenableBuilder<bool>(
        valueListenable: _enabled,
        builder: (context, enabled, _) =>
            Column(mainAxisSize: MainAxisSize.min, children: [
              MessageSoundCard(
                enabled: enabled,
                choice: _style,
                onEnabled: (v) {
                  _enabled.value = v;
                  _channel.invokeMethod<void>('saveSettings',
                      {'enabled': v, 'style': _style}).catchError((_) {});
                },
                onChoice: (v) {
                  refresh(() => _style = v);
                  _channel.invokeMethod<void>('saveSettings',
                      {'enabled': enabled, 'style': v}).catchError((_) {});
                },
                onTest: () =>
                    _channel.invokeMethod<void>('test').catchError((_) {}),
              ),
              const _BatteryOptimizationCard(),
            ])));

/// 安卓：引导坐席把通语设为电池优化「不受限制」，最大化后台轮询提醒的及时性。
/// 非安卓直接不渲染；iOS / Web 不走本机轮询，没有此设置。
class _BatteryOptimizationCard extends StatefulWidget {
  const _BatteryOptimizationCard();

  @override
  State<_BatteryOptimizationCard> createState() =>
      _BatteryOptimizationCardState();
}

class _BatteryOptimizationCardState extends State<_BatteryOptimizationCard> {
  bool? _exempt;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.android) {
      isBatteryOptimizationExempt().then((value) {
        if (mounted) setState(() => _exempt = value);
      });
    }
  }

  Future<void> _open() async {
    setState(() => _busy = true);
    try {
      await openBatteryOptimizationSettings();
      // 等系统设置页返回后重新查询状态，反映最新结果。
      await Future.delayed(const Duration(milliseconds: 900));
      final exempt = await isBatteryOptimizationExempt();
      if (mounted) setState(() => _exempt = exempt);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final exempt = _exempt == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(.07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: theme.colorScheme.primary.withOpacity(.22)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.battery_charging_full_outlined,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '长时间息屏后收不到提醒？多半是系统把通语后台「冻」了。'
                      '把它设为电池优化「不受限制」，本机轮询提醒才会持续及时。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(height: 1.45),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : FilledButton.tonalIcon(
                        onPressed: _open,
                        icon: Icon(
                          exempt ? Icons.check_circle_outline : Icons.open_in_new_outlined,
                          size: 16,
                        ),
                        label: Text(exempt ? '已设为不受限制' : '去设置：允许后台运行'),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
