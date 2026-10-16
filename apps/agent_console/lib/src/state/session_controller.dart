import 'dart:async';
import '../util/push_bridge_stub.dart'
    if (dart.library.html) '../util/push_bridge_web.dart';

import 'package:flutter/foundation.dart';

import 'package:tongyu_agent_console/src/api/api_exception.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/state/credential_store.dart';

/// How long a stored session is trusted locally before the console asks for a
/// password again.
///
/// This is only a courtesy bound: the server remains the authority, and
/// [SessionController.bootstrap] verifies the token on every launch, so a
/// revoked session is discovered immediately rather than after this window.
const int sessionWindowSeconds = 30 * 24 * 3600;

/// Where the console is in its start-up sequence.
enum SessionPhase {
  /// Reading the stored session; the UI shows a splash rather than the login
  /// form, so a signed-in agent never sees a flash of the password field.
  booting,
  loggedOut,
  authenticating,
  loggedIn,
}

/// Owns the session: who is signed in, where the server is, and the one
/// [TongYuApi] the rest of the app talks through.
///
/// The token is deliberately never exposed to widgets. Everything that needs the
/// server goes through [api], which already carries the bearer header, so there
/// is no path by which a screen accidentally forgets to authorize a request.
class SessionController extends ChangeNotifier {
  SessionController({
    CredentialStore? store,
    TongYuApi Function(String server)? apiFactory,
  })  : _store = store ?? const PreferencesCredentialStore(),
        _apiFactory = apiFactory ?? ((server) => TongYuApi(server: server));

  final CredentialStore _store;
  final TongYuApi Function(String server) _apiFactory;

  TongYuApi? _api;
  StoredSession? _session;
  SessionPhase _phase = SessionPhase.booting;
  String? _error;
  bool _busy = false;
  bool _disposed = false;

  SessionPhase get phase => _phase;

  StoredSession? get session => _session;

  AgentProfile? get agent => _session?.agent;

  TenantInfo? get tenant => _session?.tenant;

  List<InboxInfo> get inboxes => _session?.inboxes ?? const <InboxInfo>[];

  /// The server address as last used, shown pre-filled on the login form even
  /// when no session could be restored.
  String get serverHint => _session?.server ?? _lastServer;

  String? get error => _error;

  bool get busy => _busy;

  TongYuApi get api {
    final instance = _api;
    if (instance == null) {
      throw StateError('尚未选择服务器');
    }
    return instance;
  }

  bool get isSignedIn => _phase == SessionPhase.loggedIn && _api != null;

  String _lastServer = '';
  Timer? _presenceRefresh;

  /// Restores a stored session, then verifies it against the server.
  ///
  /// The verification matters: a token can be revoked server-side (an admin
  /// reset the password), and finding that out on the first message send is far
  /// worse than finding it out during start-up.
  Future<void> bootstrap() async {
    _lastServer = await _store.loadServer() ?? '';
    final stored = await _store.load();
    if (stored == null) {
      _setPhase(SessionPhase.loggedOut);
      return;
    }
    final api = _apiFactory(stored.server)..token = stored.token;
    api.configureOffline(tenant: stored.tenant.id, agent: stored.agent.id);
    _api = api;
    _session = stored;
    try {
      final profile = await api.me();
      final inboxes = await api.inboxes();
      _session = stored.copyWith(
          agent: profile, inboxes: inboxes, tenant: api.currentTenant);
      // Re-stamped with the same window used at login. A literal 0 here would
      // mark the session as already expired and sign the agent out on the very
      // next launch.
      await _store.save(_session!, sessionWindowSeconds);
      _setPhase(SessionPhase.loggedIn);
    } on ApiException catch (failure) {
      if (failure.isUnauthorized) {
        // The stored session is no longer valid; start clean but keep the
        // server address so the form is only missing credentials.
        await api.clearOfflineData();
        await disableBackgroundAlerts();
        await _store.clear();
        _api?.close();
        _api = null;
        _session = null;
        _lastServer = stored.server;
        _setPhase(SessionPhase.loggedOut);
        return;
      }
      // A network failure is not a reason to sign the agent out: the token is
      // probably still good and the server is simply unreachable right now.
      _error = failure.message;
      _setPhase(SessionPhase.loggedIn);
    }
  }

  Future<bool> login({
    required String server,
    required String email,
    required String password,
    required String tenantSlug,
  }) async {
    final origin = TongYuApi.normalizeServer(server);
    if (origin.isEmpty) {
      _error = '请填写服务器地址';
      _notify();
      return false;
    }
    _busy = true;
    _error = null;
    _setPhase(SessionPhase.authenticating);
    _api?.close();
    final api = _apiFactory(origin);
    _api = api;
    try {
      final signedIn = await api.login(
        server: origin,
        email: email,
        password: password,
        tenantSlug: tenantSlug,
      );
      // The stored expiry is deliberately generous: the server is the authority
      // on whether the token is still valid, and re-checking on every launch
      // (in bootstrap) is cheaper than forcing a re-login mid-shift.
      api.configureOffline(
          tenant: signedIn.tenant.id, agent: signedIn.agent.id);
      await _store.save(signedIn, sessionWindowSeconds);
      await _store.saveServer(origin);
      _lastServer = origin;
      _session = signedIn;
      _busy = false;
      _setPhase(SessionPhase.loggedIn);
      return true;
    } on ApiException catch (failure) {
      _error = failure.isNetworkFailure
          ? '${failure.message}\n请确认服务器地址与网络连通性。'
          : failure.message;
      _busy = false;
      _setPhase(SessionPhase.loggedOut);
      return false;
    }
  }

  /// 宿主后端签发的店员会话仍须向 SaaS 验证，不信任前端传来的角色。
  Future<void> adoptHostSession(String server, String token) async {
    if (_busy) return;
    _busy = true;
    _api?.close();
    _api = null;
    _session = null;
    _setPhase(SessionPhase.authenticating);
    final api = _apiFactory(server)..token = token;
    try {
      final agent = await api.me();
      final inboxes = await api.inboxes();
      final tenant = api.currentTenant;
      if (tenant == null) throw StateError('店铺身份无效');
      _api?.close();
      _api = api;
      _session = StoredSession(
          server: server,
          token: token,
          agent: agent,
          tenant: tenant,
          inboxes: inboxes);
      // 宿主会话仅在内存中使用，避免切换商城账号后复用旧店员身份。
      _error = null;
      _setPhase(SessionPhase.loggedIn);
    } catch (_) {
      api.close();
      _error = '店铺接待身份验证失败，请返回后重新进入';
      _setPhase(SessionPhase.loggedOut);
    } finally {
      _busy = false;
    }
  }

  /// Signs out. The socket is closed by [WorkbenchController] before this runs,
  /// so a presence event does not race the revocation.
  Future<void> logout() async {
    await disableBackgroundAlerts();
    _presenceRefresh?.cancel();
    final api = _api;
    if (api != null) {
      try {
        await api.logout();
      } on ApiException {
        // Signing out locally must succeed even if the server is unreachable.
      }
      api.close();
    }
    await api?.clearOfflineData();
    await _store.clear();
    _api = null;
    _session = null;
    _error = null;
    _setPhase(SessionPhase.loggedOut);
  }

  /// Re-reads the profile, used after changing a display name.
  Future<void> refreshProfile() async {
    final api = _api;
    if (api == null) {
      return;
    }
    try {
      final profile = await api.me();
      final current = _session;
      if (current != null) {
        _session = current.copyWith(agent: profile);
        _notify();
      }
    } on ApiException {
      // Ignored: a failed refresh leaves the previous profile on screen.
    }
  }

  /// Publishes the agent's status. Failures are swallowed on purpose — an agent
  /// should never see an error because their "away" flag did not stick.
  Future<void> setPresence(String status) async {
    final api = _api;
    final current = _session;
    if (api == null || current == null) {
      return;
    }
    _session = current.copyWith(
      agent: AgentProfile(
        id: current.agent.id,
        email: current.agent.email,
        displayName: current.agent.displayName,
        role: current.agent.role,
        presence: status,
      ),
    );
    _notify();
    try {
      await api.setPresence(status);
    } on ApiException {
      // Ignored by design.
    }
  }

  /// Keeps the presence row fresh while the app is in the foreground, so a
  /// supervisor's view of "online" does not go stale on a long shift.
  void startPresenceHeartbeat() {
    _presenceRefresh?.cancel();
    _presenceRefresh = Timer.periodic(
      const Duration(minutes: 4),
      (_) => setPresence(_session?.agent.presence ?? 'ONLINE'),
    );
  }

  void stopPresenceHeartbeat() {
    _presenceRefresh?.cancel();
    _presenceRefresh = null;
  }

  void clearError() {
    if (_error != null) {
      _error = null;
      _notify();
    }
  }

  void _setPhase(SessionPhase phase) {
    _phase = phase;
    if (phase == SessionPhase.loggedIn) {
      final current = _api;
      current?.onSessionRejected = () {
        if (_api == current && !_disposed)
          unawaited(_clearRejectedSession(current));
      };
    }
    _notify();
  }

  Future<void> _clearRejectedSession(TongYuApi api) async {
    api.onSessionRejected = null;
    await disableBackgroundAlerts();
    await api.clearOfflineData();
    await _store.clear();
    if (_api != api || _disposed) return;
    _presenceRefresh?.cancel();
    _api = null;
    _session = null;
    api.close();
    _error = '登录已失效，请重新登录';
    _setPhase(SessionPhase.loggedOut);
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _presenceRefresh?.cancel();
    _api?.close();
    super.dispose();
  }
}
