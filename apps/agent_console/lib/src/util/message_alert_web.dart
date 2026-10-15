import 'package:relaydesk_agent_console/src/util/message_sound_card.dart';
import 'dart:async';
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
final _soundEnabled = ValueNotifier<bool>(
    html.window.localStorage['tongyu.messageSound'] != 'off');
const _soundChoices = {
  'tone': '经典提示音',
  'message': '语音：你有新的消息来了',
  'customer': '语音：有客户消息，请及时查看',
  'sender': '语音：播报发送者名称',
};
String _soundChoice = _soundChoices
        .containsKey(html.window.localStorage['tongyu.messageSoundStyle'])
    ? html.window.localStorage['tongyu.messageSoundStyle']!
    : 'sender';
String _pendingSender = '';
DateTime? _quietUntil;
void setMessageQuietUntil(DateTime? until) {
  _quietUntil = until;
}

int _speechGeneration = 0;
bool _initialized = false;
bool _ready = false;
bool _priming = false;
bool _playRequested = false;
bool _pendingSound = false;
DateTime _last = DateTime(2000);

void _attachAudio() {
  if (_audio.parent != null) return;
  _audio.id = 'tongyu-message-sound';
  _audio.hidden = true;
  _audio.preload = 'auto';
  html.document.body?.append(_audio);
  _audio.onEnded.listen((_) => _audio.dataset['playback'] = 'ended');
}

/// 浏览器只允许在真实点击或按键中启动音频；进入工作台后首次操作先静音解锁。
void initializeMessageAlerts() {
  if (_initialized) return;
  _initialized = true;
  _attachAudio();
  html.document.onClick.listen((_) => unawaited(_unlockAudio()));
  html.document.onKeyDown.listen((_) => unawaited(_unlockAudio()));
}

Future<void> _unlockAudio() async {
  if (_ready || _priming || _playRequested || !_soundEnabled.value) return;
  if (_pendingSound) {
    await _playSound();
    return;
  }
  _priming = true;
  _audio.volume = 0;
  try {
    await _audio.play();
    _audio.pause();
    _audio.currentTime = 0;
    _ready = true;
    _audio.dataset['unlocked'] = 'true';
    _audio.dataset['playback'] = 'ready';
  } catch (_) {
    _audio.dataset['playback'] = 'blocked';
  } finally {
    _audio.volume = 0.65;
    _priming = false;
    if (_pendingSound && _soundEnabled.value) unawaited(_playSound());
  }
}

// 语音由浏览器/操作系统提供，优先本机中文声音；不播报客户消息正文。
// 连续消息替换旧播报，避免后台累积一长串语音；不可用时回退现有铃声。
Future<void> _playSound() async {
  if (_soundChoice == 'tone') return _playTone();
  final synthesis = html.window.speechSynthesis;
  if (synthesis == null) return _playTone();
  final pendingGeneration = _speechGeneration;
  // 首次点击先解锁备用铃声，语音异步失败后仍能播放，不丢失用户手势授权。
  if (!_ready && !_priming) {
    _priming = true;
    _audio.volume = 0;
    try {
      await _audio.play();
      _audio.pause();
      _audio.currentTime = 0;
    } catch (_) {
      // 自动消息可能发生在首次点击前，后续页面交互仍可重试。
    } finally {
      _audio.volume = 0.65;
      _priming = false;
    }
  }
  if (pendingGeneration != _speechGeneration) return;
  final generation = ++_speechGeneration;
  _ready = false;
  _playRequested = true;
  synthesis.cancel();
  _audio.pause();
  final name = _pendingSender.trim().replaceAll(RegExp(r'[\r\n\t]'), ' ');
  final shortName = String.fromCharCodes(name.runes.take(30));
  final text = switch (_soundChoice) {
    'customer' => '有客户消息，请及时查看',
    'sender' when shortName.isNotEmpty => '$shortName 给你发来了新消息',
    _ => '你有新的消息来了',
  };
  final utterance = html.SpeechSynthesisUtterance(text)
    ..lang = 'zh-CN'
    ..rate = 1
    ..volume = 0.65;
  final voices =
      synthesis.getVoices().where((v) => v.lang?.startsWith('zh') == true);
  final localVoices = voices.where((v) => v.localService == true);
  if (localVoices.isNotEmpty) {
    utterance.voice = localVoices.first;
  } else if (voices.isNotEmpty) {
    utterance.voice = voices.first;
  }
  final completed = Completer<void>();
  void finish() {
    if (!completed.isCompleted) completed.complete();
  }

  utterance.onStart.listen((_) {
    if (generation != _speechGeneration) return;
    _ready = true;
    _pendingSound = false;
    _audio.dataset['playback'] = 'speaking';
    _audio.dataset['speechText'] = text;
  });
  utterance.onEnd.listen((_) {
    if (generation == _speechGeneration) _audio.dataset['playback'] = 'ended';
    finish();
  });
  utterance.onError.listen((_) {
    if (generation == _speechGeneration && _soundEnabled.value) {
      unawaited(_playTone());
    }
    finish();
  });
  try {
    synthesis.speak(utterance);
    await completed.future.timeout(const Duration(seconds: 12));
  } catch (_) {
    if (generation == _speechGeneration && _soundEnabled.value) {
      synthesis.cancel();
      await _playTone();
    }
  } finally {
    if (generation == _speechGeneration) _playRequested = false;
  }
}

Future<void> _playTone() async {
  _attachAudio();
  _playRequested = true;
  _audio.volume = 0.65;
  _audio.currentTime = 0;
  try {
    await _audio.play();
    _ready = true;
    _pendingSound = false;
    _audio.dataset['unlocked'] = 'true';
    _audio.dataset['playback'] = 'playing';
    _audio.dataset['playCount'] =
        '${(int.tryParse(_audio.dataset['playCount'] ?? '') ?? 0) + 1}';
  } catch (_) {
    _ready = false;
    _pendingSound = true;
    _audio.dataset['playback'] = 'blocked';
  } finally {
    _playRequested = false;
  }
}

void _setSoundEnabled(bool enabled) {
  html.window.localStorage['tongyu.messageSound'] = enabled ? 'on' : 'off';
  _soundEnabled.value = enabled;
  if (!enabled) {
    _pendingSound = false;
    _speechGeneration++;
    _playRequested = false;
    html.window.speechSynthesis?.cancel();
    _audio.pause();
  } else {
    unawaited(_playSound());
  }
}

void messageAlert(String name, String body, {String senderName = ''}) {
  unawaited(_dispatchMessageAlert(name, body, senderName: senderName));
}

Future<void> _dispatchMessageAlert(String name, String body,
    {String senderName = ''}) async {
  if (_quietUntil?.isAfter(DateTime.now()) == true) return;
  initializeMessageAlerts();
  if (name.isNotEmpty) {
    if (js_util.hasProperty(html.window, 'tongyuClaimMessageAlert')) {
      try {
        final claimed = await js_util.promiseToFuture<bool>(
            js_util.callMethod(html.window, 'tongyuClaimMessageAlert', [name]));
        if (!claimed) return;
      } catch (_) {/* 老页面缺少桥接时沿用原去重。 */}
    }
    if (html.window.localStorage['tongyu.lastMessageAlert'] == name) return;
    html.window.localStorage['tongyu.lastMessageAlert'] = name;
  }
  // 消息突发合并提醒，试听不受消息节流影响。
  if (name.isNotEmpty && DateTime.now().difference(_last).inMilliseconds < 1500)
    return;
  _last = DateTime.now();
  if (_soundEnabled.value) {
    _pendingSender = senderName;
    _pendingSound = true;
    if (!_priming) unawaited(_playSound());
  }
  if (!pageVisible() &&
      html.Notification.supported &&
      html.Notification.permission == 'granted' &&
      html.window.localStorage['tongyu.desktopAlerts'] == 'on') {
    html.Notification('通语 · 新消息',
        body: '有客户消息待处理，请打开工作台查看。', tag: 'tongyu-message');
  }
}

Widget messageSoundButton() => ValueListenableBuilder<bool>(
      valueListenable: _soundEnabled,
      builder: (context, enabled, _) => IconButton(
        tooltip: enabled
            ? '声音提醒：${_soundChoices[_soundChoice]}（点击设置）'
            : '声音提醒已关闭（点击设置）',
        icon: Icon(
            enabled ? Icons.volume_up_outlined : Icons.volume_off_outlined,
            size: 20),
        onPressed: () => showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
                  title: const Text('消息与声音提醒'),
                  content: SizedBox(
                      width: 430,
                      child:
                          SingleChildScrollView(child: messageAlertSettings())),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('完成'))
                  ],
                )),
      ),
    );

Widget messageAlertSettings() => const _AlertSettings();

class _AlertSettings extends StatefulWidget {
  const _AlertSettings();
  @override
  State<_AlertSettings> createState() => _AlertSettingsState();
}

class _AlertSettingsState extends State<_AlertSettings> {
  String? _status;
  String? _soundStatus;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
      valueListenable: _soundEnabled,
      builder: (context, enabled, _) => Column(children: [
            MessageSoundCard(
              enabled: enabled,
              choice: _soundChoice,
              onEnabled: _setSoundEnabled,
              onChoice: (value) {
                _speechGeneration++;
                _playRequested = false;
                _pendingSound = false;
                html.window.speechSynthesis?.cancel();
                _audio.pause();
                setState(() {
                  _soundChoice = value;
                  _soundStatus = null;
                  html.window.localStorage['tongyu.messageSoundStyle'] = value;
                });
              },
              onTest: () async {
                _pendingSender = '张先生';
                await _playSound();
                if (mounted)
                  setState(() => _soundStatus =
                      _ready ? '试听已触发，请确认是否听到声音' : '浏览器暂未允许声音，请点击页面后重试');
              },
              status: _soundStatus,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
                title: const Text('桌面通知'),
                subtitle: Text(_status ?? '离开当前页面时提醒；不展示客户消息内容'),
                value:
                    html.window.localStorage['tongyu.desktopAlerts'] == 'on' &&
                        html.Notification.permission == 'granted',
                onChanged: (v) async {
                  if (!v) {
                    setState(() => html
                        .window.localStorage['tongyu.desktopAlerts'] = 'off');
                    return;
                  }
                  if (!html.Notification.supported) {
                    setState(() => _status = '当前浏览器不支持桌面通知');
                    return;
                  }
                  final permission = await html.Notification.requestPermission()
                      .timeout(const Duration(seconds: 8),
                          onTimeout: () => 'default');
                  if (!mounted) return;
                  setState(() {
                    html.window.localStorage['tongyu.desktopAlerts'] =
                        permission == 'granted' ? 'on' : 'off';
                    _status = permission == 'granted'
                        ? '已开启桌面通知'
                        : '浏览器未允许通知；提示音和未读角标仍可使用';
                  });
                }),
          ]));
}
