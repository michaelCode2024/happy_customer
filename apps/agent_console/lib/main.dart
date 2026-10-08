import 'dart:async';

import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/platform/platform_controller.dart';
import 'package:relaydesk_agent_console/src/state/credential_store.dart';
import 'package:relaydesk_agent_console/src/state/session_controller.dart';
import 'package:relaydesk_agent_console/src/theme.dart';
import 'package:relaydesk_agent_console/src/ui/login_page.dart';
import 'package:relaydesk_agent_console/src/ui/platform_login_page.dart';
import 'package:relaydesk_agent_console/src/ui/platform_page.dart';
import 'package:relaydesk_agent_console/src/ui/workbench_page.dart';

void main() {
  runApp(const RelayDeskConsoleApp());
}

/// Which of the two consoles the window is showing.
///
/// The agent workbench and the operations backend are different principals with
/// different credentials, but they ship as one binary: the person running a
/// self-hosted RelayDesk is usually both the first agent and the operator, and a
/// second download for four screens would be a worse answer than a switch.
enum ConsoleSurface { agent, platform }

/// The console's root.
///
/// It owns the things that outlive a sign-in: the stored agent session, the
/// stored operator token and the brightness choice. The session and the surface
/// are read before the first frame so a returning user never sees the wrong
/// screen flash, which is why the root is stateful rather than a plain
/// [MaterialApp].
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
  late final PlatformController _platform;

  ThemeMode _themeMode = ThemeMode.system;

  /// Agent by default, because a shared machine is far more likely to be an
  /// agent's desk than the operator's.
  ConsoleSurface _surface = ConsoleSurface.agent;

  /// True once the platform controller has decided whether it holds a usable
  /// token. Until then the surface must not be switchable, or a cold start could
  /// flash the operator's login form at an agent.
  bool _platformResolved = false;

  @override
  void initState() {
    super.initState();
    _store = widget.credentials ?? const PreferencesCredentialStore();
    _session = SessionController(store: _store)..addListener(_onSessionChanged);
    _platform = PlatformController(store: _store)
      ..addListener(_onPlatformChanged);
    unawaited(_restoreTheme());
    unawaited(_session.bootstrap());
    unawaited(_platform.bootstrap());
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _platform.removeListener(_onPlatformChanged);
    _session.dispose();
    _platform.dispose();
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

  /// Follows the operator's own state instead of tracking it separately: if they
  /// sign out from inside the console, the surface has to come back with them.
  void _onPlatformChanged() {
    if (!_platformResolved && _platform.phase != PlatformPhase.booting) {
      _platformResolved = true;
    }
    setState(() {});
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

  void _openPlatformConsole() {
    setState(() => _surface = ConsoleSurface.platform);
  }

  void _openAgentConsole() {
    setState(() => _surface = ConsoleSurface.agent);
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
    if (_surface == ConsoleSurface.platform) {
      return ListenableBuilder(
        listenable: _platform,
        builder: (context, _) {
          if (_platform.phase == PlatformPhase.booting) {
            return const _Splash();
          }
          if (_platform.phase != PlatformPhase.ready) {
            return PlatformLoginPage(
              controller: _platform,
              onAgentLogin: _openAgentConsole,
            );
          }
          return PlatformPage(
            controller: _platform,
            onAgentLogin: _openAgentConsole,
          );
        },
      );
    }
    switch (_session.phase) {
      case SessionPhase.booting:
        return const _Splash();
      case SessionPhase.loggedOut:
      case SessionPhase.authenticating:
        return LoginPage(
          session: _session,
          onPlatformLogin:
              _platformResolved ? _openPlatformConsole : null,
        );
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
