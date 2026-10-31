import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/ui/alert_enable_banner.dart';

void main() {
  test('桌面通知已开、浏览器推送还没订上时继续提示；核对完成前不闪', () {
    expect(
      showAlertEnableBanner(
        soundOn: true,
        permissionMissing: false,
        pushChecked: false,
        pushNeedsEnable: true,
      ),
      isFalse,
    );
    expect(
      showAlertEnableBanner(
        soundOn: true,
        permissionMissing: false,
        pushChecked: true,
        pushNeedsEnable: true,
      ),
      isTrue,
    );
  });

  test('推送订阅已确认开启时收起', () {
    expect(
      showAlertEnableBanner(
        soundOn: true,
        permissionMissing: false,
        pushChecked: true,
        pushNeedsEnable: false,
      ),
      isFalse,
    );
  });

  test('通知还没允许时继续显示，核对推送期间先不闪', () {
    expect(
      showAlertEnableBanner(
        soundOn: true,
        permissionMissing: true,
        pushChecked: false,
        pushNeedsEnable: true,
      ),
      isTrue,
    );
    expect(
      showAlertEnableBanner(
        soundOn: true,
        permissionMissing: false,
        pushChecked: false,
        pushNeedsEnable: true,
      ),
      isFalse,
    );
    expect(
      showAlertEnableBanner(
        soundOn: true,
        permissionMissing: false,
        pushChecked: true,
        pushNeedsEnable: true,
      ),
      isTrue,
    );
  });

  test('声音关着时继续提醒打开', () {
    expect(
      showAlertEnableBanner(
        soundOn: false,
        permissionMissing: false,
        pushChecked: true,
        pushNeedsEnable: false,
      ),
      isTrue,
    );
  });

  testWidgets('本机通知渠道已开启时，顶部提醒不留在页面上', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AlertEnableBanner(api: TongYuApi(server: 'https://example.com')),
      ),
    ));
    expect(find.text('请打开声音和消息通知，离开页面也能知道是谁发来了消息'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('请打开声音和消息通知，离开页面也能知道是谁发来了消息'), findsNothing);
  });
}
