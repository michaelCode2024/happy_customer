import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:relaydesk_agent_console/src/api/models.dart';

/// Where the console keeps the session between launches.
///
/// This is an interface rather than a direct `SharedPreferences` call for two
/// reasons. Tests need to run without a platform channel, and the console is
/// built for desktop, phone and web where "remember me" means different things
/// (a shared work machine arguably should not remember at all). Both are solved
/// by swapping the implementation, not by branching inside the UI.
abstract class CredentialStore {
  Future<StoredSession?> load();

  Future<void> save(StoredSession session, int expiresInSeconds);

  /// Remembers the server address on its own, so the login form is pre-filled
  /// even after the session itself has been discarded.
  Future<void> saveServer(String server);

  Future<String?> loadServer();

  /// The remembered appearance choice, as `system` / `light` / `dark`.
  ///
  /// Stored next to the session rather than in the session: an agent who signed
  /// out at night should not be greeted by a white login form.
  Future<String?> loadThemeMode();

  Future<void> saveThemeMode(String mode);

  Future<void> clear();
}

/// The production store, backed by the platform's preferences.
class PreferencesCredentialStore implements CredentialStore {
  const PreferencesCredentialStore();

  static const _serverKey = 'relaydesk.server';
  static const _tokenKey = 'relaydesk.token';
  static const _agentKey = 'relaydesk.agent';
  static const _tenantKey = 'relaydesk.tenant';
  static const _inboxesKey = 'relaydesk.inboxes';
  static const _expiresKey = 'relaydesk.expiresAt';
  static const _themeKey = 'relaydesk.themeMode';

  @override
  Future<StoredSession?> load() async {
    final preferences = await SharedPreferences.getInstance();
    final server = preferences.getString(_serverKey);
    final token = preferences.getString(_tokenKey);
    final agentRaw = preferences.getString(_agentKey);
    if (server == null || token == null || agentRaw == null) {
      return null;
    }
    final expiresAt = preferences.getInt(_expiresKey) ?? 0;
    if (expiresAt > 0 && DateTime.now().millisecondsSinceEpoch >= expiresAt) {
      // Expired tokens are dropped here rather than provoking a 401 on the
      // first screen the agent sees.
      await clear();
      return null;
    }
    return StoredSession(
      server: server,
      token: token,
      agent: AgentProfile.fromJson(
        decodeMap(preferences.getString(_agentKey)),
      ),
      tenant: TenantInfo.fromJson(
        decodeMap(preferences.getString(_tenantKey)),
      ),
      inboxes: decodeList(
        preferences.getString(_inboxesKey),
        InboxInfo.fromJson,
      ),
    );
  }

  @override
  Future<void> save(StoredSession session, int expiresInSeconds) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_serverKey, session.server);
    await preferences.setString(_tokenKey, session.token);
    await preferences.setString(_agentKey, jsonEncode(session.agent.toJson()));
    await preferences.setString(_tenantKey, jsonEncode(session.tenant.toJson()));
    await preferences.setString(
      _inboxesKey,
      jsonEncode(session.inboxes.map((inbox) => inbox.toJson()).toList()),
    );
    await preferences.setInt(
      _expiresKey,
      DateTime.now()
          .add(Duration(seconds: expiresInSeconds))
          .millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> saveServer(String server) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_serverKey, server);
  }

  @override
  Future<String?> loadServer() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_serverKey);
  }

  @override
  Future<String?> loadThemeMode() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_themeKey);
  }

  @override
  Future<void> saveThemeMode(String mode) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_themeKey, mode);
  }

  @override
  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_tokenKey);
    await preferences.remove(_agentKey);
    await preferences.remove(_tenantKey);
    await preferences.remove(_inboxesKey);
    await preferences.remove(_expiresKey);
    // The theme choice and the server address deliberately survive a sign-out.
  }
}

/// A store that keeps everything in memory. Used by tests and by the web build
/// when the browser blocks storage.
class MemoryCredentialStore implements CredentialStore {
  StoredSession? _session;
  int _expiresAt = 0;
  String _server = '';
  String _theme = '';

  @override
  Future<StoredSession?> load() async {
    if (_expiresAt > 0 && DateTime.now().millisecondsSinceEpoch >= _expiresAt) {
      await clear();
      return null;
    }
    return _session;
  }

  @override
  Future<void> save(StoredSession session, int expiresInSeconds) async {
    _session = session;
    _server = session.server;
    _expiresAt = DateTime.now()
        .add(Duration(seconds: expiresInSeconds))
        .millisecondsSinceEpoch;
  }

  @override
  Future<void> saveServer(String server) async {
    _server = server;
  }

  @override
  Future<String?> loadServer() async => _server.isEmpty ? null : _server;

  @override
  Future<String?> loadThemeMode() async => _theme.isEmpty ? null : _theme;

  @override
  Future<void> saveThemeMode(String mode) async => _theme = mode;

  @override
  Future<void> clear() async {
    _session = null;
    _expiresAt = 0;
  }
}

/// Decodes a JSON object stored as a string, tolerating anything malformed: a
/// corrupt preference must never prevent the app from starting.
Map<String, dynamic> decodeMap(String? raw) {
  if (raw == null || raw.isEmpty) {
    return const <String, dynamic>{};
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return const <String, dynamic>{};
  } on FormatException {
    return const <String, dynamic>{};
  }
}

/// Decodes a JSON array stored as a string, dropping entries that are not
/// objects rather than failing the whole read.
List<T> decodeList<T>(String? raw, T Function(Map<String, dynamic>) build) {
  if (raw == null || raw.isEmpty) {
    return <T>[];
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return <T>[];
    }
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(build)
        .toList(growable: false);
  } on FormatException {
    return <T>[];
  }
}
