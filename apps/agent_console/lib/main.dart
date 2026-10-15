import 'src/ui/app_safe_area.dart';
import 'src/util/browser_theme.dart';
import 'dart:async';
import 'package:relaydesk_agent_console/src/util/host_session.dart';
import 'package:relaydesk_agent_console/src/util/console_surface.dart';

import 'package:flutter/material.dart';
import 'package:relaydesk_agent_console/src/platform/platform_api.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:relaydesk_agent_console/src/platform/platform_controller.dart';
import 'package:relaydesk_agent_console/src/state/credential_store.dart';
import 'package:relaydesk_agent_console/src/state/session_controller.dart';
import 'package:relaydesk_agent_console/src/theme.dart';
import 'package:relaydesk_agent_console/src/ui/login_page.dart';
import 'package:relaydesk_agent_console/src/ui/platform_login_page.dart';
import 'package:relaydesk_agent_console/src/ui/platform_page.dart';
import 'package:relaydesk_agent_console/src/ui/product_brand.dart';
import 'package:relaydesk_agent_console/src/ui/workbench_page.dart';

void main() {
  runApp(const RelayDeskConsoleApp());
}

/// 同一安装包里的两套门面：客服工作台与平台运营后台。
enum ConsoleSurface { agent, platform }

/// 应用根：按「已登录 → 主页 / 未登录 → 登录页」路由，并记住上次门面。
class RelayDeskConsoleApp extends StatefulWidget {
  const RelayDeskConsoleApp(
      {super.key, this.credentials, this.platformApiFactory});

  final CredentialStore? credentials;
  final PlatformApi Function(String server)? platformApiFactory;

  @override
  State<RelayDeskConsoleApp> createState() => _RelayDeskConsoleAppState();
}

class _RelayDeskConsoleAppState extends State<RelayDeskConsoleApp> {
  StreamSubscription<String>? _hostSession;
  late final CredentialStore _store;
  late final SessionController _session;
  late final PlatformController _platform;

  bool _startupComplete = false;
  ThemeMode _themeMode = ThemeMode.system;
  ConsoleSurface _surface = ConsoleSurface.agent;

  /// 平台 bootstrap 完成前不暴露「平台管理员登录」，避免点进去还在闪 splash。
  bool _platformResolved = false;

  /// 门面偏好读完前先挡一层，避免先闪客服登录再跳运营台。
  bool _surfaceRestored = false;
  bool _manualSurface = false;

  @override
  void initState() {
    super.initState();
    _store = widget.credentials ??
        (isHostedConsole
            ? MemoryCredentialStore()
            : const PreferencesCredentialStore());
    _manualSurface = isHostedConsole || loadTabConsoleSurface() != null;
    _session = SessionController(store: _store)..addListener(_onSessionChanged);
    _platform =
        PlatformController(store: _store, apiFactory: widget.platformApiFactory)
          ..addListener(_onPlatformChanged);
    unawaited(_restorePrefs());
    if (isHostedConsole) {
      _hostSession = hostSessions().listen((token) =>
          unawaited(_session.adoptHostSession(Uri.base.origin, token)));
    } else {
      unawaited(_session.bootstrap());
    }
    if (!isHostedConsole) unawaited(_platform.bootstrap());
    if (isHostedConsole) _platformResolved = true;
  }

  @override
  void dispose() {
    _hostSession?.cancel();
    _session.removeListener(_onSessionChanged);
    _platform.removeListener(_onPlatformChanged);
    _session.dispose();
    _platform.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (_session.phase == SessionPhase.loggedIn) {
      _session.startPresenceHeartbeat();
    } else {
      _session.stopPresenceHeartbeat();
    }
    // 客服会话变化时也要刷新根路由（例如退出后回登录页）。
    setState(() {});
  }

  void _onPlatformChanged() {
    if (!_platformResolved && _platform.phase != PlatformPhase.booting) {
      _platformResolved = true;
    }
    setState(() {});
  }

  Future<void> _restorePrefs() async {
    final storedTheme = await _store.loadThemeMode();
    final mode = switch (storedTheme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => null,
    };
    final storedSurface =
        loadTabConsoleSurface() ?? await _store.loadConsoleSurface();
    final surface = switch (storedSurface) {
      'platform' => ConsoleSurface.platform,
      'agent' => ConsoleSurface.agent,
      _ => ConsoleSurface.agent,
    };
    if (!mounted) return;
    setState(() {
      if (mode != null) _themeMode = mode;
      _surface = isHostedConsole ? ConsoleSurface.agent : surface;
      _surfaceRestored = true;
    });
  }

  void _setThemeMode(ThemeMode mode) {
    setState(() => _themeMode = mode);
    unawaited(_store.saveThemeMode(mode.name));
  }

  void _openPlatformConsole() {
    _manualSurface = true;
    saveTabConsoleSurface('platform');
    setState(() => _surface = ConsoleSurface.platform);
    unawaited(_store.saveConsoleSurface('platform'));
  }

  void _openAgentConsole() {
    _manualSurface = true;
    saveTabConsoleSurface('agent');
    setState(() => _surface = ConsoleSurface.agent);
    unawaited(_store.saveConsoleSurface('agent'));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: ProductBrand.consoleTitle,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const <Locale>[Locale('zh', 'CN')],
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: RelayTheme.light(),
      darkTheme: RelayTheme.dark(),
      themeMode: _themeMode,
      builder: (context, child) {
        final theme = Theme.of(context);
        if (!_startupComplete && _surfaceRestored &&
            _session.phase != SessionPhase.booting &&
            (isHostedConsole || _platform.phase != PlatformPhase.booting)) {
          _startupComplete = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => markAppReady());
        }
        syncBrowserTheme(theme.colorScheme.surface.value,
            theme.brightness == Brightness.dark);
        return ColoredBox(color: theme.colorScheme.surface,
            child: AppSafeArea(browserBottom: isHostedConsole ? 0 : browserSafeBottom,
                child: child ?? const SizedBox.shrink()));
      },
      home: isHostedConsole
          ? Scaffold(
              appBar: AppBar(
                  leading: IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: '返回商城',
                      onPressed: closeHostedConsole),
                  title: const Text('店铺消息与群聊')),
              body: _home(),
            )
          : _home(),
    );
  }

  Widget _home() {
    // 偏好未恢复完时先 splash，避免门面闪烁。
    if (!_surfaceRestored ||
        _session.phase == SessionPhase.booting ||
        (!isHostedConsole && _platform.phase == PlatformPhase.booting)) {
      return const _Splash();
    }

    if (!_manualSurface) {
      if (_surface == ConsoleSurface.agent &&
          _session.phase == SessionPhase.loggedOut &&
          _platform.phase == PlatformPhase.ready) {
        _surface = ConsoleSurface.platform;
        saveTabConsoleSurface('platform');
      } else if (_surface == ConsoleSurface.platform &&
          _platform.phase == PlatformPhase.locked &&
          _session.phase == SessionPhase.loggedIn) {
        _surface = ConsoleSurface.agent;
        saveTabConsoleSurface('agent');
      }
    }
    if (_surface == ConsoleSurface.platform) {
      return ListenableBuilder(
        listenable: _platform,
        builder: (context, _) {
          // 已登录 → 运营主页；未登录 / 登录中 → 登录页；启动校验中 → splash。
          switch (_platform.phase) {
            case PlatformPhase.booting:
              return const _Splash();
            case PlatformPhase.ready:
              return PlatformPage(
                controller: _platform,
                onAgentLogin: _openAgentConsole,
              );
            case PlatformPhase.locked:
            case PlatformPhase.signingIn:
              return PlatformLoginPage(
                controller: _platform,
                onAgentLogin: _openAgentConsole,
              );
          }
        },
      );
    }

    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        switch (_session.phase) {
          case SessionPhase.booting:
            return const _Splash();
          case SessionPhase.loggedOut:
          case SessionPhase.authenticating:
            return LoginPage(
              session: _session,
              onPlatformLogin: _platformResolved ? _openPlatformConsole : null,
            );
          case SessionPhase.loggedIn:
            final agentId = _session.agent?.id ?? '';
            return WorkbenchPage(
              key: ValueKey<String>('workbench-$agentId'),
              session: _session,
              themeMode: _themeMode,
              onThemeModeChanged: _setThemeMode,
            );
        }
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.forum_rounded,
                  color: Colors.white, size: 26),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
