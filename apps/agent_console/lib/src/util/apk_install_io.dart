import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:tongyu_agent_console/src/util/apk_install_api.dart';

const _channel = MethodChannel('tongyu/apk');

Future<bool> canRequestPackageInstall() async {
  final allowed = await _channel.invokeMethod<bool>('canInstall');
  return allowed == true;
}

Future<DownloadedApk> downloadReleaseApk({
  required Uri uri,
  required String expectedSha256,
  required void Function(int received, int total) onProgress,
  required bool Function() isCancelled,
}) async {
  final part = await _channel.invokeMethod<String>('prepare');
  if (part == null || part.isEmpty) {
    throw const ApkDownloadException('无法创建安装包文件');
  }
  final file = File(part);
  final client = http.Client();
  final hash = RollingSha256();
  try {
    final request = http.Request('GET', uri);
    request.followRedirects = true;
    request.maxRedirects = 5;
    request.headers['Cache-Control'] = 'no-cache';
    final response = await client.send(request).timeout(
          const Duration(seconds: 20),
        );
    final finalUri = response.request?.url ?? uri;
    if (finalUri.origin != uri.origin ||
        !finalUri.path.toLowerCase().endsWith('.apk')) {
      throw const ApkDownloadException('安装包地址无效');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApkDownloadException('下载失败（${response.statusCode}）');
    }
    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in response.stream) {
        if (isCancelled()) throw const ApkDownloadCancelled();
        hash.add(chunk);
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (isCancelled()) throw const ApkDownloadCancelled();
    if (received <= 0) {
      throw const ApkDownloadException('安装包是空的');
    }
    final digest = hash.close();
    if (!sha256Matches(digest, expectedSha256)) {
      throw const ApkDownloadException('安装包校验未通过，请重新下载');
    }
    final committed = await _channel.invokeMethod<String>('commit');
    if (committed == null || committed.isEmpty) {
      throw const ApkDownloadException('无法保存安装包');
    }
    final bytes = await File(committed).length();
    if (bytes <= 0) {
      throw const ApkDownloadException('无法保存安装包');
    }
    return DownloadedApk(path: committed, sha256: digest, bytes: bytes);
  } on ApkDownloadCancelled {
    await _deleteQuiet(file);
    rethrow;
  } on ApkDownloadException {
    await _deleteQuiet(file);
    rethrow;
  } catch (_) {
    await _deleteQuiet(file);
    throw const ApkDownloadException('下载未完成，请检查网络后重试');
  } finally {
    client.close();
  }
}

Future<String> installLocalApk() async {
  final status = await _channel.invokeMethod<String>('install');
  return status ?? 'failed';
}

Future<void> openInstallPermissionSettings() async {
  await _channel.invokeMethod<void>('openPermissionSettings');
}

Future<int> cachedApkBytes() async {
  final raw = await _channel.invokeMethod<Object>('cachedBytes');
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return 0;
}

Future<void> discardCachedApk() async {
  await _channel.invokeMethod<void>('discard');
}

Future<void> _deleteQuiet(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}
