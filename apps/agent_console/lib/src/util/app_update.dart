import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tongyu_agent_console/src/util/apk_install.dart';
import 'package:tongyu_agent_console/src/util/apk_install_api.dart';
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
const _apkShaKey = 'tongyu.android.apkSha';
const _apkBuildKey = 'tongyu.android.apkBuild';
const _apkBytesKey = 'tongyu.android.apkBytes';

/// 已下载的安装包必须对得上当前发行清单，并且文件还在、大小没变。
bool downloadedApkRecordMatches({
  required String storedSha,
  required int storedBuild,
  required int storedBytes,
  required int fileBytes,
  required String remoteSha,
  required int remoteBuild,
}) {
  if (remoteBuild <= 0 || storedBuild != remoteBuild) return false;
  if (fileBytes <= 0 || storedBytes != fileBytes) return false;
  return sha256Matches(storedSha, remoteSha);
}

Future<void> rememberDownloadedApk({
  required String sha256,
  required int buildNumber,
  required int bytes,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_apkShaKey, sha256);
  await prefs.setInt(_apkBuildKey, buildNumber);
  await prefs.setInt(_apkBytesKey, bytes);
}

Future<void> forgetDownloadedApk() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_apkShaKey);
  await prefs.remove(_apkBuildKey);
  await prefs.remove(_apkBytesKey);
}

/// 对得上当前版本时返回文件字节数；对不上就清掉，避免拿旧包去装。
Future<int?> readyDownloadedApkBytes(AndroidReleaseInfo remote) async {
  final fileBytes = await cachedApkBytes();
  final prefs = await SharedPreferences.getInstance();
  final storedSha = prefs.getString(_apkShaKey) ?? '';
  final storedBuild = prefs.getInt(_apkBuildKey) ?? 0;
  final storedBytes = prefs.getInt(_apkBytesKey) ?? 0;
  final matches = downloadedApkRecordMatches(
    storedSha: storedSha,
    storedBuild: storedBuild,
    storedBytes: storedBytes,
    fileBytes: fileBytes,
    remoteSha: remote.sha256,
    remoteBuild: remote.buildNumber,
  );
  if (matches) return fileBytes;
  if (fileBytes > 0 || storedSha.isNotEmpty) {
    await forgetDownloadedApk();
    await discardCachedApk();
  }
  return null;
}

Future<void> clearDownloadedApk() async {
  await forgetDownloadedApk();
  await discardCachedApk();
}

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
    final manifest =
        Uri.parse(serverBase.trim()).resolve('/downloads/release.json');
    final response = await http.get(manifest, headers: const {
      'Cache-Control': 'no-cache'
    }).timeout(const Duration(seconds: 12));
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

/// 只接受本站 `/downloads/*.apk`，避免发行清单被改写后跳到陌生域名。
Uri? allowedAndroidApkUri(String serverBase, String relativeOrAbsolute) {
  final uri = resolveReleaseUri(serverBase, relativeOrAbsolute);
  if (uri == null) return null;
  final base = Uri.tryParse(serverBase.trim());
  if (base == null ||
      uri.origin != base.origin ||
      !uri.path.startsWith('/downloads/') ||
      !uri.path.toLowerCase().endsWith('.apk')) {
    return null;
  }
  return uri;
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
    await clearDownloadedApk();
    if (!context.mounted) return;
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
  final readyBytes = await readyDownloadedApkBytes(result.remote!);
  if (!context.mounted) return;
  await showAndroidUpdateDialog(
    context,
    serverBase: serverBase,
    localVersion: result.localVersion,
    localBuild: result.localBuildNumber,
    remote: result.remote!,
    force: result.forceUpdate,
    alreadyDownloaded: readyBytes != null,
    downloadedBytes: readyBytes ?? 0,
  );
}

Future<void> showAndroidUpdateDialog(
  BuildContext context, {
  required String serverBase,
  required String localVersion,
  required int localBuild,
  required AndroidReleaseInfo remote,
  required bool force,
  bool alreadyDownloaded = false,
  int downloadedBytes = 0,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: !force,
    builder: (ctx) => _AndroidUpdateDialog(
      serverBase: serverBase,
      localVersion: localVersion,
      localBuild: localBuild,
      remote: remote,
      force: force,
      alreadyDownloaded: alreadyDownloaded,
      downloadedBytes: downloadedBytes,
    ),
  );
}

enum _UpdatePhase { prompt, downloading, permission, failed, opened }

class _AndroidUpdateDialog extends StatefulWidget {
  const _AndroidUpdateDialog({
    required this.serverBase,
    required this.localVersion,
    required this.localBuild,
    required this.remote,
    required this.force,
    required this.alreadyDownloaded,
    required this.downloadedBytes,
  });

  final String serverBase;
  final String localVersion;
  final int localBuild;
  final AndroidReleaseInfo remote;
  final bool force;
  final bool alreadyDownloaded;
  final int downloadedBytes;

  @override
  State<_AndroidUpdateDialog> createState() => _AndroidUpdateDialogState();
}

class _AndroidUpdateDialogState extends State<_AndroidUpdateDialog>
    with WidgetsBindingObserver {
  _UpdatePhase _phase = _UpdatePhase.prompt;
  int _received = 0;
  int _total = 0;
  String? _error;
  int _token = 0;
  bool _awaitingPermission = false;
  bool _fileReady = false;
  int _readyBytes = 0;

  @override
  void initState() {
    super.initState();
    _fileReady = widget.alreadyDownloaded;
    _readyBytes = widget.downloadedBytes;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _token++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_awaitingPermission) return;
    _awaitingPermission = false;
    if (_fileReady) {
      unawaited(_install());
    } else {
      unawaited(_startDownload());
    }
  }

  bool get _canLeave => !widget.force && _phase != _UpdatePhase.downloading;

  Future<void> _startDownload() async {
    if (_phase == _UpdatePhase.downloading) return;
    final uri = allowedAndroidApkUri(widget.serverBase, widget.remote.url);
    if (uri == null) {
      setState(() {
        _phase = _UpdatePhase.failed;
        _error = '安装包地址无效';
      });
      return;
    }
    final allowed = await canRequestPackageInstall();
    if (!mounted) return;
    if (!allowed) {
      setState(() {
        _phase = _UpdatePhase.permission;
        _error = null;
      });
      return;
    }
    final token = ++_token;
    _fileReady = false;
    await forgetDownloadedApk();
    if (!mounted || token != _token) return;
    setState(() {
      _phase = _UpdatePhase.downloading;
      _received = 0;
      _total = 0;
      _error = null;
    });
    try {
      final downloaded = await downloadReleaseApk(
        uri: uri,
        expectedSha256: widget.remote.sha256,
        onProgress: (received, total) {
          if (!mounted || token != _token) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
        isCancelled: () => token != _token,
      );
      if (!mounted || token != _token) return;
      await rememberDownloadedApk(
        sha256: downloaded.sha256,
        buildNumber: widget.remote.buildNumber,
        bytes: downloaded.bytes,
      );
      _fileReady = true;
      _readyBytes = downloaded.bytes;
      await _install();
    } on ApkDownloadCancelled {
      if (!mounted || token != _token) return;
      setState(() => _phase = _UpdatePhase.prompt);
    } on ApkDownloadException catch (error) {
      if (!mounted || token != _token) return;
      setState(() {
        _phase = _UpdatePhase.failed;
        _error = error.message;
      });
    }
  }

  void _cancelDownload() {
    _token++;
    setState(() {
      _phase = _UpdatePhase.prompt;
      _received = 0;
      _total = 0;
    });
  }

  Future<void> _install() async {
    try {
      final status = await installLocalApk();
      if (!mounted) return;
      switch (status) {
        case 'ok':
          setState(() {
            _phase = _UpdatePhase.opened;
            _error = null;
          });
        case 'permission':
          setState(() => _phase = _UpdatePhase.permission);
        case 'missing':
        case 'invalid':
          _fileReady = false;
          await forgetDownloadedApk();
          await discardCachedApk();
          if (!mounted) return;
          setState(() {
            _phase = _UpdatePhase.failed;
            _error = '安装包已失效，请重新下载';
          });
        default:
          setState(() {
            _phase = _UpdatePhase.failed;
            _error = '无法打开安装界面，请重试';
          });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _UpdatePhase.failed;
        _error = '无法打开安装界面，请重试';
      });
    }
  }

  Future<void> _openPermission() async {
    _awaitingPermission = true;
    try {
      await openInstallPermissionSettings();
    } catch (_) {
      if (!mounted) return;
      _awaitingPermission = false;
      setState(() {
        _phase = _UpdatePhase.failed;
        _error = '无法打开系统设置，请在设置中允许通语安装应用';
      });
    }
  }

  String _progressLabel() {
    final got = formatByteSize(_received);
    if (_total <= 0) return '已下载 $got';
    final percent = ((_received * 100) / _total).floor().clamp(0, 100);
    return '$percent%  ·  $got / ${formatByteSize(_total)}';
  }

  @override
  Widget build(BuildContext context) {
    final remote = widget.remote;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return PopScope(
      canPop: _canLeave,
      child: AlertDialog(
        title: Row(
          children: [
            Icon(
              widget.force
                  ? Icons.system_update_alt_rounded
                  : Icons.system_update_rounded,
              color: widget.force
                  ? const Color(0xFFE53935)
                  : const Color(0xFF3263FF),
            ),
            const SizedBox(width: 8),
            Text(widget.force ? '需要更新后继续使用' : '发现新版本'),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '当前 ${widget.localVersion}（${widget.localBuild}） → 最新 ${remote.version}'
                '${remote.buildNumber > 0 ? '（${remote.buildNumber}）' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (remote.updatedAt.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '发布于 ${remote.updatedAt}',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ],
              if (remote.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  '更新说明',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
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
              if (_phase == _UpdatePhase.downloading) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: downloadFraction(_received, _total),
                  minHeight: 8,
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                ),
                const SizedBox(height: 8),
                Text(_progressLabel(),
                    style: TextStyle(fontSize: 13, color: muted)),
                const SizedBox(height: 4),
                Text(
                  '下载完成后将打开系统安装界面',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ],
              if (_fileReady &&
                  (_phase == _UpdatePhase.prompt ||
                      _phase == _UpdatePhase.failed ||
                      _phase == _UpdatePhase.opened)) ...[
                const SizedBox(height: 12),
                Text(
                  _readyBytes > 0
                      ? '安装包已下载（${formatByteSize(_readyBytes)}），可直接安装。'
                      : '安装包已下载，可直接安装。',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
              if (_phase == _UpdatePhase.permission) ...[
                const SizedBox(height: 12),
                Text(
                  _fileReady
                      ? '请允许通语安装应用。允许后会打开安装界面。'
                      : '请允许通语安装应用。允许后会自动开始下载。',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
              if (_phase == _UpdatePhase.opened) ...[
                const SizedBox(height: 12),
                Text(
                  '请在系统安装界面完成安装。装完后重新打开通语。',
                  style: TextStyle(fontSize: 13, color: muted),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
              if (widget.force && _phase == _UpdatePhase.prompt) ...[
                const SizedBox(height: 10),
                Text(
                  '此版本为必更版本，更新完成后重新打开应用即可继续接待。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (!widget.force && _phase != _UpdatePhase.downloading)
            TextButton(
              onPressed: () async {
                await skipAndroidUpdate(remote);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('稍后再说'),
            ),
          if (_phase == _UpdatePhase.downloading)
            TextButton(
              onPressed: _cancelDownload,
              child: const Text('取消'),
            ),
          if (_phase == _UpdatePhase.prompt || _phase == _UpdatePhase.failed)
            FilledButton.icon(
              onPressed: _fileReady ? _install : _startDownload,
              icon: Icon(
                _fileReady
                    ? Icons.install_mobile_rounded
                    : Icons.download_rounded,
                size: 18,
              ),
              label: Text(
                _fileReady
                    ? '立即安装'
                    : (_phase == _UpdatePhase.failed ? '重试' : '立即更新'),
              ),
            ),
          if (_phase == _UpdatePhase.permission)
            FilledButton(
              onPressed: _openPermission,
              child: const Text('去允许'),
            ),
          if (_phase == _UpdatePhase.opened)
            FilledButton(
              onPressed: _install,
              child: const Text('继续安装'),
            ),
        ],
      ),
    );
  }
}

/// 设置页展示的本机版本文案。
Future<String> localAppVersionLabel() async {
  final info = await PackageInfo.fromPlatform();
  final build = info.buildNumber.trim();
  if (build.isEmpty || build == '0') return info.version;
  return '${info.version} · $build';
}
