import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Plays one voice note at a time.
///
/// A console is a shared screen with one pair of speakers, so overlapping
/// playback would be noise rather than multitasking. Starting a note therefore
/// stops whatever was already playing, and the widget that owns the current note
/// is told so it can drop its "playing" state.
///
/// Windows has no just_audio implementation, so [VoicePlayer.supported] is false
/// there and the UI falls back to a plain file chip instead of a control that
/// would silently do nothing.
class VoicePlayer {
  VoicePlayer._();

  static final VoicePlayer instance = VoicePlayer._();

  /// False on platforms just_audio cannot drive, which is only Windows today.
  static bool get supported => !kIsWeb ? _supportedNative : true;

  static bool get _supportedNative =>
      defaultTargetPlatform != TargetPlatform.windows;

  AudioPlayer? _player;
  String? _currentUrl;
  StreamSubscription<PlayerState>? _stateSubscription;

  /// Called when playback stops, whatever the reason: the clip ended, the user
  /// paused it, or another note took over.
  VoidCallback? _onStopped;

  /// The url currently loaded into the player, or null when nothing is playing.
  String? get currentUrl => _currentUrl;

  bool get isPlaying => _player?.playing ?? false;

  /// Starts [url], or does nothing if it is already the one playing.
  ///
  /// [onStopped] is invoked once when the clip finishes or is interrupted, so
  /// the bubble can reset its icon without polling the player.
  Future<void> toggle(String url, {required VoidCallback onStopped}) async {
    if (!supported) {
      return;
    }
    if (_currentUrl == url && (_player?.playing ?? false)) {
      await _player?.pause();
      return;
    }
    if (_currentUrl == url && !(_player?.playing ?? false)) {
      _onStopped = onStopped;
      await _player?.seek(Duration.zero);
      await _player?.play();
      return;
    }
    await stop();
    _onStopped = onStopped;
    final player = _player ??= AudioPlayer();
    _stateSubscription ??= player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        player.pause();
        player.seek(Duration.zero);
        _currentUrl = null;
        final callback = _onStopped;
        _onStopped = null;
        callback?.call();
      }
    });
    _currentUrl = url;
    try {
      await player.setUrl(url);
      await player.play();
    } on Exception {
      // A note that cannot be fetched (expired link, offline) must not leave the
      // bubble stuck in a playing state.
      _currentUrl = null;
      _onStopped = null;
      rethrow;
    }
  }

  /// Stops playback and forgets the current note.
  Future<void> stop() async {
    final player = _player;
    if (player == null) {
      return;
    }
    final callback = _onStopped;
    _onStopped = null;
    _currentUrl = null;
    await player.stop();
    callback?.call();
  }

  /// Releases the platform player. The console holds one of these for its whole
  /// session, so this only runs when the workbench page goes away.
  Future<void> release() async {
    _onStopped = null;
    _currentUrl = null;
    await _stateSubscription?.cancel();
    _stateSubscription = null;
    await _player?.dispose();
    _player = null;
  }
}
