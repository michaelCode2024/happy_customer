import 'package:flutter_test/flutter_test.dart';
import 'package:tongyu_agent_console/src/util/apk_install_api.dart';
import 'package:tongyu_agent_console/src/util/app_update.dart';

const _sha = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

void main() {
  test('buildNumber 更大时判定为有新版本', () {
    expect(
      isRemoteNewer(
        localVersion: '0.1.0',
        localBuild: 10,
        remoteVersion: '0.1.0',
        remoteBuild: 11,
      ),
      isTrue,
    );
    expect(
      isRemoteNewer(
        localVersion: '0.2.0',
        localBuild: 20,
        remoteVersion: '0.1.0',
        remoteBuild: 11,
      ),
      isFalse,
    );
  });

  test('无 buildNumber 时按版本号比较', () {
    expect(
      isRemoteNewer(
        localVersion: '0.1.0',
        localBuild: 0,
        remoteVersion: '0.1.1',
        remoteBuild: 0,
      ),
      isTrue,
    );
    expect(
      isRemoteNewer(
        localVersion: '1.0.0',
        localBuild: 0,
        remoteVersion: '0.9.9',
        remoteBuild: 0,
      ),
      isFalse,
    );
  });

  test('相对 APK 路径解析到同源 downloads', () {
    final uri = resolveReleaseUri(
      'https://chat.lookfunny.xyz',
      '/downloads/tongyu-android-20261015.apk',
    );
    expect(uri?.toString(),
        'https://chat.lookfunny.xyz/downloads/tongyu-android-20261015.apk');
  });

  test('解析 AndroidReleaseInfo 的 notes / force / minBuildNumber', () {
    final info = AndroidReleaseInfo.fromJson({
      'version': '0.1.1',
      'buildNumber': 42,
      'url': '/downloads/a.apk',
      'force': true,
      'minBuildNumber': 40,
      'notes': ['修复消息提醒', '安卓检查更新'],
    });
    expect(info.force, isTrue);
    expect(info.minBuildNumber, 40);
    expect(info.notes, ['修复消息提醒', '安卓检查更新']);
    expect(info.isValid, isTrue);
  });

  test('只接受本站 downloads 下的 apk', () {
    expect(
      allowedAndroidApkUri(
        'https://chat.lookfunny.xyz',
        '/downloads/tongyu-android.apk',
      )?.path,
      '/downloads/tongyu-android.apk',
    );
    expect(
      allowedAndroidApkUri(
        'https://chat.lookfunny.xyz',
        'https://evil.example/downloads/a.apk',
      ),
      isNull,
    );
  });

  test('已下载记录必须版本、校验和、文件大小都一致', () {
    expect(
      downloadedApkRecordMatches(
        storedSha: _sha,
        storedBuild: 2026103103,
        storedBytes: 100,
        fileBytes: 100,
        remoteSha: _sha,
        remoteBuild: 2026103103,
      ),
      isTrue,
    );
    expect(
      downloadedApkRecordMatches(
        storedSha: _sha,
        storedBuild: 2026103102,
        storedBytes: 100,
        fileBytes: 100,
        remoteSha: _sha,
        remoteBuild: 2026103103,
      ),
      isFalse,
    );
    expect(
      downloadedApkRecordMatches(
        storedSha: _sha,
        storedBuild: 2026103103,
        storedBytes: 100,
        fileBytes: 0,
        remoteSha: _sha,
        remoteBuild: 2026103103,
      ),
      isFalse,
    );
    expect(sha256Matches(_sha, '$_sha '), isTrue);
    expect(sha256Matches(_sha, ''), isFalse);
  });

  test('下载进度按字节换算', () {
    expect(downloadFraction(0, 0), isNull);
    expect(downloadFraction(50, 100), 0.5);
    expect(formatByteSize(0), '0 B');
    expect(formatByteSize(1536), '1.5 KB');
  });

  test('流式 sha256 与整段结果一致', () {
    final rolling = RollingSha256()..add('abc'.codeUnits);
    expect(rolling.close(), _sha);
  });
}
