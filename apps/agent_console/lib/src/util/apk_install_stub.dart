import 'package:tongyu_agent_console/src/util/apk_install_api.dart';

Future<bool> canRequestPackageInstall() async => false;

Future<DownloadedApk> downloadReleaseApk({
  required Uri uri,
  required String expectedSha256,
  required void Function(int received, int total) onProgress,
  required bool Function() isCancelled,
}) async {
  throw UnsupportedError('仅安卓安装包支持应用内更新');
}

Future<String> installLocalApk() async {
  throw UnsupportedError('仅安卓安装包支持应用内更新');
}

Future<void> openInstallPermissionSettings() async {
  throw UnsupportedError('仅安卓安装包支持应用内更新');
}

Future<int> cachedApkBytes() async => 0;

Future<void> discardCachedApk() async {}
