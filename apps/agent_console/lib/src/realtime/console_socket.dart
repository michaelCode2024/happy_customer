import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:relaydesk_agent_console/src/api/models.dart';

/// Connection state of the console socket, as shown in the status bar.
enum SocketState { connecting, open, closed }

/// The realtime channel to the server.
///
/// This is deliberately a convenience layer, not a source of truth: everything
/// the console displays can be rebuilt from REST. That is what makes it safe to
/// drop and re-open the socket on every network change, and it is why the
/// reconnect callback tells the workbench to resync rather than trying to replay
/// whatever was missed frame by frame.
class ConsoleSocket {
  ConsoleSocket({required this.uriProvider});

  /// Built fresh per attempt, so a re-login mid-session uses the new token.
  final Uri Function() uriProvider;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _retry;
  int _attempt = 0;
  bool _stopped = false;
  bool _everOpened = false;

  final StreamController<RealtimeEvent> _events =
      StreamController<RealtimeEvent>.broadcast();
  final StreamController<SocketState> _states =
      StreamController<SocketState>.broadcast();
  final StreamController<void> _reconnects = StreamController<void>.broadcast();

  static const Duration _heartbeatInterval = Duration(seconds: 25);
  static const List<Duration> _backoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
  ];

  /// Every event the server pushes, after the greeting frame.
  Stream<RealtimeEvent> get events => _events.stream;

  /// Connection changes, for the status indicator.
  Stream<SocketState> get states => _states.stream;

  /// Fires after a reconnect that follows an earlier successful connection, so
  /// the workbench knows to pull whatever it missed while disconnected.
  Stream<void> get reconnects => _reconnects.stream;

  bool get isOpen => _channel != null;

  /// Opens the socket. Safe to call repeatedly; an open socket is left alone.
  void connect() {
    if (_channel != null) {
      return;
    }
    _stopped = false;
    _attempt = 0;
    _open();
  }

  void disconnect() {
    _stopped = true;
    _clearTimers();
    final channel = _channel;
    _channel = null;
    _subscription?.cancel();
    _subscription = null;
    channel?.sink.close();
    _emitState(SocketState.closed);
  }

  /// Releases everything. The instance cannot be reused afterwards.
  Future<void> dispose() async {
    disconnect();
    await _events.close();
    await _states.close();
    await _reconnects.close();
  }

  /// Joins one conversation's stream. The console already receives everything
  /// for its inboxes, so this only widens the firehose to a single thread.
  void subscribe(String conversationId) {
    _send(<String, String>{
      'type': 'subscribe',
      'conversationId': conversationId,
    });
  }

  void unsubscribe(String conversationId) {
    _send(<String, String>{
      'type': 'unsubscribe',
      'conversationId': conversationId,
    });
  }

  void sendTyping(String conversationId) {
    _send(<String, String>{'type': 'typing', 'conversationId': conversationId});
  }

  void sendRead(String conversationId) {
    _send(<String, String>{'type': 'read', 'conversationId': conversationId});
  }

  void _send(Map<String, String> frame) {
    _channel?.sink.add(jsonEncode(frame));
  }

  void _open() {
    _emitState(SocketState.connecting);
    WebSocketChannel channel;
    try {
      channel = WebSocketChannel.connect(uriProvider());
    } catch (_) {
      _scheduleRetry();
      return;
    }
    _channel = channel;

    _subscription = channel.stream.listen(
      _onFrame,
      onError: (Object _) {
        // onDone always follows an error, which is where the retry is scheduled.
      },
      onDone: () {
        _clearTimers();
        _channel = null;
        _emitState(SocketState.closed);
        if (!_stopped) {
          _scheduleRetry();
        }
      },
      cancelOnError: false,
    );
  }

  void _onFrame(dynamic frame) {
    if (frame is! String) {
      return;
    }
    Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(frame);
      if (parsed is! Map<String, dynamic>) {
        return;
      }
      decoded = parsed;
    } on FormatException {
      return;
    }
    final event = RealtimeEvent.fromJson(decoded);
    if (event.isHeartbeat) {
      return;
    }
    if (event.isHello) {
      // The server's greeting doubles as proof the handshake succeeded.
      _attempt = 0;
      _emitState(SocketState.open);
      if (_everOpened) {
        _reconnects.add(null);
      }
      _everOpened = true;
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(
        _heartbeatInterval,
        (_) => _send(<String, String>{'type': 'ping'}),
      );
      return;
    }
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  void _scheduleRetry() {
    if (_stopped || _retry != null) {
      return;
    }
    final index = _attempt < _backoff.length ? _attempt : _backoff.length - 1;
    _attempt += 1;
    _retry = Timer(_backoff[index], () {
      _retry = null;
      if (!_stopped) {
        _open();
      }
    });
  }

  void _clearTimers() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _retry?.cancel();
    _retry = null;
  }

  void _emitState(SocketState state) {
    if (!_states.isClosed) {
      _states.add(state);
    }
  }
}
