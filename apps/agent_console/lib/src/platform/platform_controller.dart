import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:relaydesk_agent_console/src/api/api_exception.dart';
import 'package:relaydesk_agent_console/src/platform/platform_api.dart';
import 'package:relaydesk_agent_console/src/platform/platform_models.dart';
import 'package:relaydesk_agent_console/src/state/credential_store.dart';

/// Which screen the operations console is showing.
enum PlatformPhase { booting, locked, signingIn, ready }

/// What the operator is looking at inside the console.
enum PlatformSection { overview, tenants, ai, about }

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

  String _server = '';
  PlatformOverview? _overview;
  List<TenantSummary> _tenants = const <TenantSummary>[];
  PlatformAiUsage? _aiUsage;
  PlatformMeta? _meta;
  TenantDetail? _detail;
  String _tenantQuery = '';
  int _aiDays = 14;
  Timer? _searchDebounce;

  PlatformPhase get phase => _phase;

  PlatformSection get section => _section;

  String? get error => _error;

  bool get busy => _busy;

  String get server => _server;

  PlatformOverview? get overview => _overview;

  List<TenantSummary> get tenants => _tenants;

  PlatformAiUsage? get aiUsage => _aiUsage;

  PlatformMeta? get meta => _meta;

  TenantDetail? get detail => _detail;

  String get tenantQuery => _tenantQuery;

  int get aiDays => _aiDays;

  /// ------------------------------------------------------------------ session

  /// Restores a stored operator token, then proves it still works.
  ///
  /// A stale token is not an error worth alarming the operator with: it is the
  /// ordinary end of a 24-hour shift, so the console simply comes back locked.
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

  /// Exchanges the deployment's static token for a bearer token and enters the
  /// console.
  Future<bool> signIn({
    required String server,
    required String staticToken,
  }) async {
    final origin = PlatformApi(server: server).server;
    if (origin.isEmpty) {
      _error = '请填写服务器地址';
      _notify();
      return false;
    }
    if (staticToken.trim().isEmpty) {
      _error = '请填写平台管理令牌';
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
      await api.exchange(staticToken.trim());
      final overview = await api.overview();
      final meta = await api.meta();
      await _store.saveServer(origin);
      await _store.savePlatformToken(api.token);
      _server = origin;
      _overview = overview;
      _meta = meta;
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

  /// Leaves the console. The static token is never stored, so signing out really
  /// does mean the operator has to produce the deployment secret again.
  Future<void> signOut() async {
    _api?.close();
    _api = null;
    _overview = null;
    _tenants = const <TenantSummary>[];
    _aiUsage = null;
    _detail = null;
    _tenantQuery = '';
    await _store.clearPlatformToken();
    _setPhase(PlatformPhase.locked);
  }

  void selectSection(PlatformSection section) {
    if (_section == section) {
      return;
    }
    _section = section;
    _notify();
    switch (section) {
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
    _busy = true;
    _notify();
    try {
      _tenants = await api.tenants(query: _tenantQuery);
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
      _error = failure.message;
      _busy = false;
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
