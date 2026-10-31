import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 应用内下载被取消。调用方不要当成失败提示。
class ApkDownloadCancelled implements Exception {
  const ApkDownloadCancelled();
}

/// 下载或校验失败时给界面看的说明。
class ApkDownloadException implements Exception {
  const ApkDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DownloadedApk {
  const DownloadedApk({
    required this.path,
    required this.sha256,
    required this.bytes,
  });

  final String path;
  final String sha256;
  final int bytes;
}

/// 边收边算 SHA-256，避免把整包读进内存。
class RollingSha256 {
  final _sink = _DigestSink();
  late final ByteConversionSink _input = sha256.startChunkedConversion(_sink);

  void add(List<int> chunk) => _input.add(chunk);

  String close() {
    _input.close();
    return _sink.value?.toString() ?? '';
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 发行清单里的校验和必须是 64 位十六进制，并且与下载结果一致。
bool sha256Matches(String actual, String expected) {
  final want = expected.trim().toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(want)) return false;
  return actual.trim().toLowerCase() == want;
}

/// 未知总长度时返回 null，进度条改为不确定状态。
double? downloadFraction(int received, int total) {
  if (total <= 0) return null;
  final value = received / total;
  if (value < 0) return 0;
  if (value > 1) return 1;
  return value;
}

String formatByteSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const kb = 1024;
  const mb = 1024 * 1024;
  if (bytes < kb) return '$bytes B';
  if (bytes < mb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  return '${(bytes / mb).toStringAsFixed(1)} MB';
}
