import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 只保存当前账号实际读取过的文本快照，不保存令牌、附件或管理密钥。
/// 服务端仍负责在线鉴权；离线快照最多保留 24 小时，退出后删除。
class OfflineStore {
  OfflineStore(String server, String tenant, String agent)
      : prefix =
            'tongyu.offline.v2.${Uri.encodeComponent(server)}.$tenant.$agent.' {
    _pending = _removeLegacy();
  }
  Future<void> _removeLegacy() async {
    final prefs = await SharedPreferences.getInstance();
    final legacy =
        prefix.replaceFirst('tongyu.offline.v2.', 'tongyu.offline.v1.');
    for (final key in prefs.getKeys().where((key) => key.startsWith(legacy))) {
      await prefs.remove(key);
    }
  }

  final String prefix;
  OfflineStore._(this.prefix);
  OfflineStore fresh() => OfflineStore._(prefix);
  static const maxAge = Duration(hours: 24);
  static const maxCharacters = 1000000;
  static const maxEntries = 120;
  bool _cleared = false;
  bool writeFailed = false;
  Future<void> _pending = Future.value();

  Future<void> flush() => _pending;

  String _key(String path) => prefix + Uri.encodeComponent(path);

  Future<Map<String, dynamic>?> read(String path) async {
    await _pending;
    if (_cleared) return null;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(path));
    if (raw == null) return null;
    try {
      final row = jsonDecode(raw) as Map<String, dynamic>;
      final age = DateTime.now().millisecondsSinceEpoch - (row['time'] as int);
      if (age < 0 ||
          age >
              (path.startsWith('draft/') ? const Duration(days: 7) : maxAge)
                  .inMilliseconds) {
        await prefs.remove(_key(path));
        return null;
      }
      return Map<String, dynamic>.from(row['data'] as Map);
    } catch (_) {
      await prefs.remove(_key(path));
      return null;
    }
  }

  Future<void> write(String path, Map<String, dynamic> data) {
    // 串行保存与清理，防止退出过程中尚未完成的请求重新写回客户数据。
    _pending = _pending.then((_) async {
      if (_cleared) {
        writeFailed = true;
        return;
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        final value = jsonEncode(
            {'time': DateTime.now().millisecondsSinceEpoch, 'data': data});
        if (value.length > maxCharacters ~/ 3) {
          writeFailed = true;
          return;
        }
        final keys = prefs
            .getKeys()
            .where((k) => k.startsWith(prefix) && k != _key(path))
            .toList();
        keys.sort((a, b) =>
            (prefs.getString(a) ?? '').compareTo(prefs.getString(b) ?? ''));
        var size =
            keys.fold<int>(0, (n, k) => n + (prefs.getString(k)?.length ?? 0));
        while (keys.isNotEmpty &&
            (keys.length >= maxEntries ||
                size + value.length > maxCharacters)) {
          final candidates =
              keys.where((k) => !k.startsWith(prefix + 'draft%2F')).toList();
          if (candidates.isEmpty) {
            writeFailed = true;
            return;
          }
          final key = candidates.first;
          keys.remove(key);
          size -= prefs.getString(key)?.length ?? 0;
          await prefs.remove(key);
        }
        final saved = await prefs.setString(_key(path), value);
        if (!saved)
          writeFailed = true;
        else if (path.startsWith('draft/')) writeFailed = false;
      } catch (_) {
        writeFailed = true;
        // 存储配额或隐私模式失败不能把已成功的服务端操作报告为失败。
      }
    });
    return _pending;
  }

  Future<void> clear({bool retire = true}) async {
    _cleared = true;
    await _pending;
    final prefs = await SharedPreferences.getInstance();
    for (final key
        in prefs.getKeys().where((k) => k.startsWith(prefix)).toList()) {
      await prefs.remove(key);
    }
    _cleared = retire;
    writeFailed = false;
  }
}
