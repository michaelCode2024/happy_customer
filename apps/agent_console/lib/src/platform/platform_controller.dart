import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:tongyu_agent_console/src/api/api_exception.dart';
import 'package:tongyu_agent_console/src/platform/platform_api.dart';
import 'package:tongyu_agent_console/src/platform/platform_models.dart';
import 'package:tongyu_agent_console/src/state/credential_store.dart';

/// Which screen the operations console is showing.
enum PlatformPhase { booting, locked, signingIn, ready }

/// What the operator is looking at inside the console.
enum PlatformSection { overview, tenants, plans, ai, about, account, history }

/// Owns the operations console: the bearer token, the tenant list and whichever
/// detail is open.
///
/// The token never reaches a widget. Screens ask this object for data and it
/// decides whether the stored token is still good, which is the same rule the
/// agent console follows — a screen cannot forget to authorize a request because
/// it never builds one.
class PlatformController extends ChangeNotifier {
  PlatformController({required CredentialStore store, this.apiFactory})
      : _store = store;

  /// Injectable so tests can drive the console without a server.
  final PlatformApi Function(String server)? apiFactory;

  final CredentialStore _store;

  PlatformApi? _api;
  PlatformPhase _phase = PlatformPhase.booting;
  PlatformSection _section = PlatformSection.overview;
  String? _error;
  bool _busy = false;
  bool _disposed = false;

  Map<String, dynamic> _profile = {};
  bool get isSuperAdmin => _profile['role'] == 'SUPER_ADMIN';
  String get operatorName => (_profile['displayName'] ?? '平台管理员').toString();
  String _server = '';
  PlatformOverview? _overview;
  List<TenantSummary> _tenants = const <TenantSummary>[];
  PlatformAiUsage? _aiUsage;
  PlatformMeta? _meta;
  TenantDetail? _detail;
  String? _assignmentPlan;
  String? get assignmentPlan => _assignmentPlan;

  void beginPlanAssignment(String plan) {
    _assignmentPlan = plan;
    _detail = null;
    selectSection(PlatformSection.tenants);
    _notify();
  }

  void clearPlanAssignment() {
    _assignmentPlan = null;
    _notify();
  }

  String _tenantQuery = '';
  int _aiDays = 14;
  bool _hasMoreTenants = false;
  int _tenantRevision = 0;
  bool get hasMoreTenants => _hasMoreTenants;
  Timer? _searchDebounce;

  PlatformPhase get phase => _phase;

  PlatformSection get section => _section;

  String? get error => _error;

  bool get busy => _busy;

  String get server => _server;

  PlatformApi get api => _api!;

  PlatformOverview? get overview => _overview;

  List<TenantSummary> get tenants => _tenants;

  PlatformAiUsage? get aiUsage => _aiUsage;

  PlatformMeta? get meta => _meta;

  TenantDetail? get detail => _detail;

  String get tenantQuery => _tenantQuery;

  int get aiDays => _aiDays;

  /// 登录页预填用；密码永不通过此接口暴露。
  Future<String?> rememberedEmail() => _store.loadPlatformEmail();

  /// ------------------------------------------------------------------ session

  /// Restores a stored operator token, then proves it still works.
  ///
  /// A stale token is not an error worth alarming the operator with: it is the
  Future<void> bootstrap() async {
    _server = await _store.loadServer() ?? '';
    if (_server.isEmpty) {
      _setPhase(PlatformPhase.locked);
      return;
    }
    final stored = await _store.loadPlatformToken();
    final api = _makeApi(_server);
    if (stored == null || stored.isEmpty) {
      _api = api;
      _setPhase(PlatformPhase.locked);
      return;
    }
    _api = api;
    try {
      _overview = await api.restore(stored);
      _meta = await api.meta();
      _profile = await api.profile();
      _setPhase(PlatformPhase.ready);
      unawaited(refreshTenants());
      unawaited(refreshAiUsage());
    } on ApiException catch (failure) {
      if (failure.isUnauthorized) {
        api.close();
        _api = null;
        await _store.clearPlatformToken();
        _setPhase(PlatformPhase.locked);
        return;
      }
      // The server is unreachable but the token may well be fine; keeping the
      // operator signed in means a restart fixes it without retyping a secret.
      _error = failure.message;
      _setPhase(PlatformPhase.ready);
    }
  }

  /// console.
  Future<bool> signIn({
    required String server,
    required String email,
    required String password,
  }) async {
    final origin = PlatformApi(server: server).server;
    if (origin.isEmpty) {
      _error = '请填写服务器地址';
      _notify();
      return false;
    }
    if (email.trim().isEmpty || password.isEmpty) {
      _error = '请填写账号和密码';
      _notify();
      return false;
    }
    _busy = true;
    _error = null;
    _setPhase(PlatformPhase.signingIn);
    _api?.close();
    final api = _makeApi(origin);
    _api = api;
    try {
      await api.login(email, password);
      final overview = await api.overview();
      final meta = await api.meta();
      _profile = await api.profile();
      await _store.saveServer(origin);
      await _store.savePlatformToken(api.token);
      // 记住用户名方便回访；密码绝不落盘。
      await _store.savePlatformEmail(email.trim());
      _server = origin;
      _overview = overview;
      _meta = meta;
      // 登录成功一律落在运营主页，而不是上次停留的子页。
      _section = PlatformSection.overview;
      _busy = false;
      _setPhase(PlatformPhase.ready);
      unawaited(refreshTenants());
      unawaited(refreshAiUsage());
      return true;
    } on ApiException catch (failure) {
      api.close();
      _api = null;
      _error = failure.isNetworkFailure
          ? '${failure.message}\n请确认服务器地址与网络连通性。'
          : failure.message;
      _busy = false;
      _setPhase(PlatformPhase.locked);
      return false;
    }
  }

  Future<void> signOut() async {
    try {
      await _api?.logout();
    } catch (_) {/* 即使会话已过期，也清除本地凭证。 */}
    _api?.close();
    _api = null;
    _overview = null;
    _profile = {};
    _tenants = const <TenantSummary>[];
    _aiUsage = null;
    _detail = null;
    _tenantQuery = '';
    _section = PlatformSection.overview;
    _error = null;
    await _store.clearPlatformToken();
    // locked → 根路由回到平台登录页；不切换到客服门面。
    _setPhase(PlatformPhase.locked);
  }

  void selectSection(PlatformSection section) {
    if (_section == section) {
      return;
    }
    _section = section;
    _notify();
    switch (section) {
      case PlatformSection.history:
        break;
      case PlatformSection.account:
      case PlatformSection.plans:
        // 套餐页是静态营销内容，无需额外拉取。
        break;
      case PlatformSection.overview:
        unawaited(refreshOverview());
      case PlatformSection.tenants:
        if (_tenants.isEmpty) {
          unawaited(refreshTenants());
        }
      case PlatformSection.ai:
        if (_aiUsage == null) {
          unawaited(refreshAiUsage());
        }
      case PlatformSection.about:
        if (_meta == null) {
          unawaited(refreshMeta());
        }
    }
  }

  /// ------------------------------------------------------------------- reads

  Future<void> refreshOverview() async {
    final api = _api;
    if (api == null) {
      return;
    }
    try {
      _overview = await api.overview();
      _error = null;
    } on ApiException catch (failure) {
      _error = failure.message;
      if (failure.isUnauthorized) {
        await _expire();
        return;
      }
    }
    _notify();
  }

  Future<void> refreshTenants() async {
    final api = _api;
    if (api == null) {
      return;
    }
    final revision = ++_tenantRevision;
    _busy = true;
    _notify();
    try {
      final rows = await api.tenants(query: _tenantQuery);
      if (revision != _tenantRevision) return;
      _tenants = rows;
      _hasMoreTenants = rows.length == 100;
      _error = null;
    } on ApiException catch (failure) {
      _error = failure.message;
      if (failure.isUnauthorized) {
        await _expire();
        return;
      }
    }
    _busy = false;
    _notify();
  }

  Future<void> loadMoreTenants() async {
    final api = _api;
    if (api == null || _busy || !_hasMoreTenants) return;
    final revision = _tenantRevision;
    _busy = true;
    _notify();
    try {
      final rows =
          await api.tenants(query: _tenantQuery, offset: _tenants.length);
      if (revision != _tenantRevision) return;
      _tenants = [..._tenants, ...rows];
      _hasMoreTenants = rows.length == 100;
    } on ApiException catch (failure) {
      _error = failure.message;
      if (failure.isUnauthorized) await _expire();
    } finally {
      if (revision == _tenantRevision) {
        _busy = false;
        _notify();
      }
    }
  }

  /// Debounces the search box, so typing a slug is one request rather than one
  /// per keystroke.
  void searchTenants(String value) {
    _tenantQuery = value;
    _notify();
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(refreshTenants());
    });
  }

  Future<void> openTenant(String id) async {
    final api = _api;
    if (api == null) {
      return;
    }
    _busy = true;
    _detail = null;
    _notify();
    try {
      _detail = await api.tenant(id);
      _error = null;
    } on ApiException catch (failure) {
      _error = failure.message;
      if (failure.isUnauthorized) {
        await _expire();
        return;
      }
    }
    _busy = false;
    _notify();
  }

  void closeTenant() {
    if (_detail == null) {
      return;
    }
    _detail = null;
    _notify();
  }

  Future<void> refreshAiUsage({int? days}) async {
    final api = _api;
    if (api == null) {
      return;
    }
    if (days != null) {
      _aiDays = days;
    }
    _busy = true;
    _notify();
    try {
      _aiUsage = await api.aiUsage(days: _aiDays);
      _error = null;
    } on ApiException catch (failure) {
      _error = failure.message;
      if (failure.isUnauthorized) {
        await _expire();
        return;
      }
    }
    _busy = false;
    _notify();
  }

  Future<void> refreshMeta() async {
    final api = _api;
    if (api == null) {
      return;
    }
    try {
      _meta = await api.meta();
    } on ApiException catch (failure) {
      _error = failure.message;
      if (failure.isUnauthorized) {
        await _expire();
        return;
      }
    }
    _notify();
  }

  /// ------------------------------------------------------------------ writes

  /// Provisions a tenant. The created record is returned so the caller can show
  /// the generated owner password exactly once.
  Future<CreatedTenant?> createTenant({
    required String name,
    required String slug,
    required String ownerEmail,
    required String ownerName,
    required String ownerPassword,
    required String inboxName,
    required String publicKey,
    required String plan,
    required int trialDays,
    bool inlineFailure = false,
  }) async {
    final api = _api;
    if (api == null) {
      return null;
    }
    _busy = true;
    _error = null;
    _notify();
    try {
      final created = await api.createTenant(
        name: name,
        slug: slug,
        ownerEmail: ownerEmail,
        ownerName: ownerName,
        ownerPassword: ownerPassword,
        inboxName: inboxName,
        publicKey: publicKey,
        plan: plan,
        trialDays: trialDays,
      );
      _busy = false;
      await refreshTenants();
      await refreshOverview();
      return created;
    } on ApiException catch (failure) {
      _busy = false;
      if (inlineFailure && !failure.isUnauthorized) {
        // 对话框负责展示创建错误，避免同一错误同时出现在背景页面。
        _error = null;
        _notify();
        rethrow;
      }
      _error = failure.message;
      if (failure.isUnauthorized) {
        await _expire();
        return null;
      }
      _notify();
      return null;
    }
  }

  /// Applies a change to a tenant and re-reads the detail, because the server
  /// recomputes plan limits when a plan changes and the console must not guess
  /// what those are.
  Future<bool> updateTenant({
    String name = '',
    String status = '',
    String plan = '',
    String planStatus = '',
    int? seatLimit,
    int? monthlyMessageLimit,
    int? trialDays,
  }) async {
    final api = _api;
    final current = _detail;
    if (api == null || current == null) {
      return false;
    }
    _busy = true;
    _error = null;
    _notify();
    try {
      await api.updateTenant(
        current.id,
        name: name,
        status: status,
        plan: plan,
        planStatus: planStatus,
        seatLimit: seatLimit,
        monthlyMessageLimit: monthlyMessageLimit,
        trialDays: trialDays,
      );
    } on ApiException catch (failure) {
      _error = failure.message;
      _busy = false;
      if (failure.isUnauthorized) {
        await _expire();
        return false;
      }
      _notify();
      return false;
    }
    _busy = false;
    await openTenant(current.id);
    await refreshTenants();
    await refreshOverview();
    return true;
  }

  Future<bool> extendTrial(int days) async {
    final api = _api;
    final current = _detail;
    if (api == null || current == null) {
      return false;
    }
    try {
      await api.extendTrial(current.id, days);
    } on ApiException catch (failure) {
      _error = failure.message;
      if (failure.isUnauthorized) {
        await _expire();
        return false;
      }
      _notify();
      return false;
    }
    await openTenant(current.id);
    return true;
  }

  /// Resets a tenant's owner. Returns the password now in force, or null when
  /// the reset failed.
  Future<String?> resetOwner(String email) async {
    final api = _api;
    final current = _detail;
    if (api == null || current == null) {
      return null;
    }
    try {
      final password = await api.resetOwner(current.id, email: email);
      await openTenant(current.id);
      return password;
    } on ApiException catch (failure) {
      _error = failure.message;
      if (failure.isUnauthorized) {
        await _expire();
        return null;
      }
      _notify();
      return null;
    }
  }

  /// ----------------------------------------------------------------- plumbing

  PlatformApi _makeApi(String server) =>
      (apiFactory ?? (origin) => PlatformApi(server: origin))(server);

  /// Drops a token the server has stopped accepting.
  Future<void> _expire() async {
    _api?.close();
    _api = null;
    await _store.clearPlatformToken();
    _setPhase(PlatformPhase.locked);
  }

  void _setPhase(PlatformPhase phase) {
    _phase = phase;
    _notify();
  }

  /// Dismisses the current failure notice.
  void clearError() {
    if (_error == null) {
      return;
    }
    _error = null;
    _notify();
  }

  void _notify() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _searchDebounce?.cancel();
    _api?.close();
    super.dispose();
  }
}
