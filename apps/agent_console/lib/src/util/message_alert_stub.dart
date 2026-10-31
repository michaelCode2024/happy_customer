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
            ])));
