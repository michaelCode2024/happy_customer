import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'package:flutter/material.dart';

/// Flutter 3.24 的 dart:html Document 未声明 hasFocus，走 JS 互操作；失败则只看可见性。
bool pageVisible() {
  if (html.document.visibilityState != 'visible') return false;
  try {
    return js_util.callMethod(html.document, 'hasFocus', []) as bool? ?? true;
  } catch (_) {
    return true;
  }
}

final _audio = html.AudioElement(
    'data:audio/wav;base64,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');
DateTime _last = DateTime(2000);
void messageAlert(String name, String body) {
  if (DateTime.now().difference(_last).inMilliseconds < 1500) return;
  _last = DateTime.now();
  if (html.window.localStorage['tongyu.messageSound'] != 'off') {
    _audio.currentTime = 0;
    _audio.play().catchError((_) {});
  }
  if (!pageVisible() &&
      html.Notification.supported &&
      html.Notification.permission == 'granted' &&
      html.window.localStorage['tongyu.desktopAlerts'] == 'on') {
    html.Notification('通语 · 新消息',
        body: '有客户消息待处理，请打开工作台查看。', tag: 'tongyu-message');
  }
}

Widget messageAlertSettings() => const _AlertSettings();

class _AlertSettings extends StatefulWidget {
  const _AlertSettings();
  @override
  State<_AlertSettings> createState() => _AlertSettingsState();
}

class _AlertSettingsState extends State<_AlertSettings> {
  String? _status;
  @override
  Widget build(BuildContext context) => Column(children: [
        SwitchListTile(
            title: const Text('新消息提示音'),
            subtitle: const Text('首次与页面交互后可播放，短时间连续消息合并提醒'),
            value: html.window.localStorage['tongyu.messageSound'] != 'off',
            onChanged: (v) {
              setState(() => html.window.localStorage['tongyu.messageSound'] =
                  v ? 'on' : 'off');
              if (v) messageAlert('', '');
            }),
        SwitchListTile(
            title: const Text('桌面通知'),
            subtitle: Text(_status ?? '离开当前页面时提醒；不展示客户消息内容'),
            value: html.window.localStorage['tongyu.desktopAlerts'] == 'on' &&
                html.Notification.permission == 'granted',
            onChanged: (v) async {
              if (!v) {
                setState(() =>
                    html.window.localStorage['tongyu.desktopAlerts'] = 'off');
                return;
              }
              if (!html.Notification.supported) {
                setState(() => _status = '当前浏览器不支持桌面通知');
                return;
              }
              final permission = await html.Notification.requestPermission();
              if (!mounted) return;
              setState(() {
                html.window.localStorage['tongyu.desktopAlerts'] =
                    permission == 'granted' ? 'on' : 'off';
                _status = permission == 'granted'
                    ? '已开启桌面通知'
                    : '浏览器未允许通知；提示音和未读角标仍可使用';
              });
            }),
        TextButton(
            onPressed: () => messageAlert('', ''), child: const Text('测试提示音')),
      ]);
}
