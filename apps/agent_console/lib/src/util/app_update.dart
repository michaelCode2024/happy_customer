import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:tongyu_agent_console/src/util/app_platform.dart';

/// 与官网 `/downloads/release.json` 对齐的安卓发行信息。
class AndroidReleaseInfo {
  const AndroidReleaseInfo({
    required this.version,
    required this.buildNumber,
    required this.url,
    this.updatedAt = '',
    this.sha256 = '',
    this.notes = const [],
    this.force = false,
    this.minBuildNumber = 0,
  });

  factory AndroidReleaseInfo.fromJson(Map<String, dynamic> json) {
    final notesRaw = json['notes'];
    final notes = <String>[];
    if (notesRaw is List) {
      for (final item in notesRaw) {
        final text = '$item'.trim();
        if (text.isNotEmpty) notes.add(text);
      }
    } else if (notesRaw is String && notesRaw.trim().isNotEmpty) {
      notes.addAll(
        notesRaw
            .split(RegExp(r'[\r\n]+'))
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty),
      );
    }
    return AndroidReleaseInfo(
      version: '${json['version'] ?? ''}'.trim(),
      buildNumber: _asInt(json['buildNumber']),
      url: '${json['url'] ?? ''}'.trim(),
      updatedAt: '${json['updatedAt'] ?? ''}'.trim(),
      sha256: '${json['sha256'] ?? ''}'.trim(),
      notes: notes,
      force: json['force'] == true,
      minBuildNumber: _asInt(json['minBuildNumber']),
    );
  }

  final String version;
  final int buildNumber;
  final String url;
  final String updatedAt;
  final String sha256;
  final List<String> notes;
  final bool force;
  final int minBuildNumber;

  bool get isValid => version.isNotEmpty && url.isNotEmpty;
}

class AppUpdateCheckResult {
  const AppUpdateCheckResult({
    required this.localVersion,
    required this.localBuildNumber,
    this.remote,
    this.updateAvailable = false,
    this.forceUpdate = false,
    this.error,
  });

  final String localVersion;
  final int localBuildNumber;
  final AndroidReleaseInfo? remote;
  final bool updateAvailable;
  final bool forceUpdate;
  final String? error;
}

const _skipBuildKey = 'tongyu.android.skipBuild';

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? 0;
}

/// 比较远端与本机：优先 buildNumber；否则按 x.y.z 版本段比较。
bool isRemoteNewer({
  required String localVersion,
  required int localBuild,
  required String remoteVersion,
  required int remoteBuild,
}) {
  if (remoteBuild > 0 && localBuild > 0) {
    return remoteBuild > localBuild;
  }
  return _compareVersion(remoteVersion, localVersion) > 0;
}

int _compareVersion(String a, String b) {
  List<int> parts(String raw) => raw
      .split(RegExp(r'[^0-9]+'))
      .where((p) => p.isNotEmpty)
      .map((p) => int.tryParse(p) ?? 0)
      .toList(growable: false);
  final left = parts(a);
  final right = parts(b);
  final n = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < n; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l.compareTo(r);
  }
  return 0;
}

Uri? resolveReleaseUri(String serverBase, String relativeOrAbsolute) {
  final raw = relativeOrAbsolute.trim();
  if (raw.isEmpty) return null;
  final parsed = Uri.tryParse(raw);
  if (parsed == null) return null;
  if (parsed.hasScheme) return parsed;
  final base = Uri.tryParse(serverBase.trim());
  if (base == null || !base.hasScheme) return null;
  return base.resolveUri(parsed);
}

/// 拉取官网发行清单并与本机安装包对比。仅安卓原生包有意义。
Future<AppUpdateCheckResult> checkAndroidAppUpdate(String serverBase) async {
  final info = await PackageInfo.fromPlatform();
  final localVersion = info.version;
  final localBuild = int.tryParse(info.buildNumber) ?? 0;
  if (!runningOnAndroid) {
    return AppUpdateCheckResult(
      localVersion: localVersion,
      localBuildNumber: localBuild,
    );
  }
  try {
    final manifest = Uri.parse(serverBase.trim()).resolve('/downloads/release.json');
    final response = await http
        .get(manifest, headers: const {'Cache-Control': 'no-cache'})
        .timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return AppUpdateCheckResult(
        localVersion: localVersion,
        localBuildNumber: localBuild,
        error: '暂时无法获取版本信息（${response.statusCode}）',
      );
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map) {
      return AppUpdateCheckResult(
        localVersion: localVersion,
        localBuildNumber: localBuild,
        error: '版本信息格式无效',
      );
    }
    final android = body['android'];
    if (android is! Map) {
      return AppUpdateCheckResult(
        localVersion: localVersion,
        localBuildNumber: localBuild,
        error: '未发布安卓安装包',
      );
    }
    final remote =
        AndroidReleaseInfo.fromJson(Map<String, dynamic>.from(android));
    if (!remote.isValid) {
      return AppUpdateCheckResult(
        localVersion: localVersion,
        localBuildNumber: localBuild,
        error: '安卓版本信息不完整',
      );
    }
    final newer = isRemoteNewer(
      localVersion: localVersion,
      localBuild: localBuild,
      remoteVersion: remote.version,
      remoteBuild: remote.buildNumber,
    );
    final belowMin =
        remote.minBuildNumber > 0 && localBuild < remote.minBuildNumber;
    final force = remote.force || belowMin;
    var available = newer || belowMin;
    if (available && !force) {
      final prefs = await SharedPreferences.getInstance();
      final skipped = prefs.getInt(_skipBuildKey) ?? 0;
      final remoteKey =
          remote.buildNumber > 0 ? remote.buildNumber : remote.version.hashCode;
      if (skipped == remoteKey) {
        available = false;
      }
    }
    return AppUpdateCheckResult(
      localVersion: localVersion,
      localBuildNumber: localBuild,
      remote: remote,
      updateAvailable: available,
      forceUpdate: force && (newer || belowMin),
    );
  } catch (error) {
    return AppUpdateCheckResult(
      localVersion: localVersion,
      localBuildNumber: localBuild,
      error: '检查更新失败，请稍后重试',
    );
  }
}

Future<void> skipAndroidUpdate(AndroidReleaseInfo remote) async {
  final prefs = await SharedPreferences.getInstance();
  final key =
      remote.buildNumber > 0 ? remote.buildNumber : remote.version.hashCode;
  await prefs.setInt(_skipBuildKey, key);
}

Future<bool> openAndroidReleaseDownload(
  String serverBase,
  AndroidReleaseInfo remote,
) async {
  final uri = resolveReleaseUri(serverBase, remote.url);
  if (uri == null) return false;
  // 仅允许本站 /downloads/*.apk，避免发行清单被改写后跳到陌生域名。
  final base = Uri.tryParse(serverBase.trim());
  if (base == null ||
      uri.origin != base.origin ||
      !uri.path.startsWith('/downloads/') ||
      !uri.path.toLowerCase().endsWith('.apk')) {
    return false;
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// 登录后静默检查；有更新再弹窗。设置页可强制弹出结果。
Future<void> promptAndroidAppUpdateIfNeeded(
  BuildContext context, {
  required String serverBase,
  bool manual = false,
}) async {
  if (!runningOnAndroid) {
    if (manual && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前不是安卓安装包，请使用网页版的检查更新')),
      );
    }
    return;
  }
  final result = await checkAndroidAppUpdate(serverBase);
  if (!context.mounted) return;
  if (result.error != null) {
    if (manual) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error!)),
      );
    }
    return;
  }
  if (!result.updateAvailable || result.remote == null) {
    if (manual) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已是最新版本（${result.localVersion} · ${result.localBuildNumber}）',
          ),
        ),
      );
    }
    return;
  }
  await showAndroidUpdateDialog(
    context,
    serverBase: serverBase,
    localVersion: result.localVersion,
    localBuild: result.localBuildNumber,
    remote: result.remote!,
    force: result.forceUpdate,
  );
}

Future<void> showAndroidUpdateDialog(
  BuildContext context, {
  required String serverBase,
  required String localVersion,
  required int localBuild,
  required AndroidReleaseInfo remote,
  required bool force,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: !force,
    builder: (ctx) => PopScope(
      canPop: !force,
      child: AlertDialog(
        title: Row(
          children: [
            Icon(
              force
                  ? Icons.system_update_alt_rounded
                  : Icons.system_update_rounded,
              color: force
                  ? const Color(0xFFE53935)
                  : const Color(0xFF3263FF),
            ),
            const SizedBox(width: 8),
            Text(force ? '需要更新后继续使用' : '发现新版本'),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '当前 $localVersion（$localBuild） → 最新 ${remote.version}'
                '${remote.buildNumber > 0 ? '（${remote.buildNumber}）' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (remote.updatedAt.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '发布于 ${remote.updatedAt}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (remote.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('更新说明',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                for (final note in remote.notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('· '),
                        Expanded(child: Text(note)),
                      ],
                    ),
                  ),
              ] else ...[
                const SizedBox(height: 10),
                const Text('建议更新到最新安装包，以获得修复与新能力。'),
              ],
              if (force) ...[
                const SizedBox(height: 10),
                Text(
                  '此版本为必更版本，更新完成后重新打开应用即可继续接待。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (!force)
            TextButton(
              onPressed: () async {
                await skipAndroidUpdate(remote);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('稍后再说'),
            ),
          FilledButton.icon(
            onPressed: () async {
              final ok =
                  await openAndroidReleaseDownload(serverBase, remote);
              if (!ctx.mounted) return;
              if (!ok) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('无法打开下载地址，请稍后在下载页重试')),
                );
                return;
              }
              if (!force) Navigator.pop(ctx);
            },
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('立即更新'),
          ),
        ],
      ),
    ),
  );
}

/// 设置页展示的本机版本文案。
Future<String> localAppVersionLabel() async {
  final info = await PackageInfo.fromPlatform();
  final build = info.buildNumber.trim();
  if (build.isEmpty || build == '0') return info.version;
  return '${info.version} · $build';
}
