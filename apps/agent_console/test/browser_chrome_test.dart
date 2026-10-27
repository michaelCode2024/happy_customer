import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyu_agent_console/src/theme.dart';
import 'package:tongyu_agent_console/src/ui/app_safe_area.dart';
import 'package:tongyu_agent_console/src/ui/mobile_workbench_nav.dart';
import 'package:tongyu_agent_console/src/util/browser_chrome.dart';

Widget _withBar() => MaterialApp(
      theme: RelayTheme.light(),
      home: Scaffold(
        bottomNavigationBar: MobileBottomNavBar(
          currentIndex: 0,
          onTap: (_) {},
          unreadCount: 0,
        ),
      ),
    );

void main() {
  test('底部安全距离只算一次，键盘弹起时不补', () {
    const media = MediaQueryData(size: Size(390, 844));
    expect(
        AppSafeArea.resolveBottom(
            media.copyWith(padding: const EdgeInsets.only(bottom: 34)), 21),
        34);
    expect(
        AppSafeArea.resolveBottom(
            media.copyWith(padding: const EdgeInsets.only(bottom: 0)), 34),
        34);
    expect(
        AppSafeArea.resolveBottom(
            media.copyWith(
                padding: const EdgeInsets.only(bottom: 34),
                viewInsets: const EdgeInsets.only(bottom: 300)),
            34),
        0);
  });

  testWidgets('贴底栏把自己的颜色登记给外层安全区', (tester) async {
    BrowserChrome.registerBottom('probe', const Color(0xFF123456));
    expect(BrowserChrome.bottom.value, const Color(0xFF123456));
    BrowserChrome.unregisterBottom('probe');
    expect(BrowserChrome.bottom.value, isNull);

    await tester.pumpWidget(_withBar());
    await tester.pump();
    expect(BrowserChrome.bottom.value, Colors.white,
        reason: '工作台底栏是白底，iOS Home 条那一截必须同色');

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(BrowserChrome.bottom.value, isNull, reason: '底栏卸载后不能留着旧颜色');
  });

  testWidgets('被新页面整页盖住时不再登记底栏颜色', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: RelayTheme.light(),
      home: TickerMode(
        enabled: false,
        child: Scaffold(
          bottomNavigationBar: MobileBottomNavBar(
            currentIndex: 0,
            onTap: (_) {},
            unreadCount: 0,
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(BrowserChrome.bottom.value, isNull);

    await tester.pumpWidget(_withBar());
    await tester.pump();
    expect(BrowserChrome.bottom.value, Colors.white);
  });
}
