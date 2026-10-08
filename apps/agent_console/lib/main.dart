import 'dart:async';

import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/state/credential_store.dart';
import 'package:relaydesk_agent_console/src/state/session_controller.dart';
import 'package:relaydesk_agent_console/src/theme.dart';
import 'package:relaydesk_agent_console/src/ui/login_page.dart';
import 'package:relaydesk_agent_console/src/ui/workbench_page.dart';

void main() {
  runApp(const RelayDeskConsoleApp());
}

/// The console's root.
///
/// It owns the two things that outlive a sign-in: the stored session and the
/// brightness choice. Both are read before the first frame so a returning agent
/// never sees the login form flash, which is why the root is stateful rather
/// than a plain [MaterialApp].
class RelayDeskConsoleApp extends StatefulWidget {
  const RelayDeskConsoleApp({super.key, this.credentials});

  /// Injectable so tests avoid the platform preferences channel. The store is
  /// shared with [SessionController], so both read the same "remember me" data.
  final CredentialStore? credentials;

  @override
  State<RelayDeskConsoleApp> createState() => _RelayDeskConsoleAppState();
}

class _RelayDeskConsoleAppState extends State<RelayDeskConsoleApp> {
  late final CredentialStore _store;
  late final SessionController _session;

  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _store = widget.credentials ?? const PreferencesCredentialStore();
    _session = SessionController(store: _store)..addListener(_onSessionChanged);
    unawaited(_restoreTheme());
    unawaited(_session.bootstrap());
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    super.dispose();
  }

  /// Keeps the presence heartbeat in step with the session: it should run only
  /// while an agent is actually signed in.
  void _onSessionChanged() {
    if (_session.phase == SessionPhase.loggedIn) {
      _session.startPresenceHeartbeat();
    } else {
      _session.stopPresenceHeartbeat();
    }
  }

  Future<void> _restoreTheme() async {
    final stored = await _store.loadThemeMode();
    final mode = switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => null,
    };
    if (mode == null || !mounted) {
      return;
    }
    setState(() => _themeMode = mode);
  }

  void _setThemeMode(ThemeMode mode) {
    setState(() => _themeMode = mode);
    // Saved outside the session so it applies to the login screen too, and so it
    // survives signing out.
    unawaited(_store.saveThemeMode(mode.name));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'RelayDesk 客服工作台',
      theme: RelayTheme.light(),
      darkTheme: RelayTheme.dark(),
      themeMode: _themeMode,
      home: ListenableBuilder(
        listenable: _session,
        builder: (context, _) => _home(),
      ),
    );
  }

  Widget _home() {
    switch (_session.phase) {
      case SessionPhase.booting:
        return const _Splash();
      case SessionPhase.loggedOut:
      case SessionPhase.authenticating:
        return LoginPage(session: _session);
      case SessionPhase.loggedIn:
        // Keyed by agent so switching accounts rebuilds the workbench instead of
        // reusing a controller bound to the previous session's API client.
        final agentId = _session.agent?.id ?? '';
        return WorkbenchPage(
          key: ValueKey<String>('workbench-$agentId'),
          session: _session,
          themeMode: _themeMode,
          onThemeModeChanged: _setThemeMode,
        );
    }
  }
}

/// Shown for the moment it takes to read the stored session.
class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      ),
    );
  }
}
