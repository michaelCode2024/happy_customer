import 'package:flutter_test/flutter_test.dart';
import 'package:tongyu_agent_console/src/util/app_update.dart';

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
}
