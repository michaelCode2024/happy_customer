import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyu_agent_console/src/ui/alert_enable_card.dart';

void main() {
  group('alertCardStage', () {
    test('还没问过权限时请用户直接开启', () {
      expect(
        alertCardStage(
            permission: 'default', pushChecked: false, pushOff: true),
        AlertCardStage.enable,
      );
    });

    test('浏览器已拒绝时只能引导去系统设置', () {
      expect(
        alertCardStage(permission: 'denied', pushChecked: false, pushOff: true),
        AlertCardStage.openSettings,
      );
    });

    test('已允许但推送没订上时提示再允许一次', () {
      expect(
        alertCardStage(permission: 'granted', pushChecked: true, pushOff: true),
        AlertCardStage.finishPush,
      );
    });

    test('核对推送期间不弹，避免工作台刚打开就闪一下', () {
      expect(
        alertCardStage(
            permission: 'granted', pushChecked: false, pushOff: true),
        isNull,
      );
    });

    test('全部就绪或环境不支持时不弹', () {
      expect(
        alertCardStage(
            permission: 'granted', pushChecked: true, pushOff: false),
        isNull,
      );
      expect(
        alertCardStage(
            permission: 'unsupported', pushChecked: true, pushOff: true),
        isNull,
      );
    });
  });

  testWidgets('卡片按截图结构渲染标题、正文、关闭和黑底按钮', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: AlertEnableCard(
            stage: AlertCardStage.openSettings,
            onAction: () async => null,
            onClose: () {},
          ),
        ),
      ),
    ));

    expect(find.text('开启桌面通知'), findsOneWidget);
    expect(find.text('前往系统设置开启桌面通知，第一时间获取任务状态提醒。'), findsOneWidget);
    expect(find.text('前往系统设置'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
  });

  testWidgets('动作返回提示文案时保留卡片并展示', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: AlertEnableCard(
            stage: AlertCardStage.enable,
            onAction: () async => '浏览器未允许通知，请在站点设置中允许后重试',
            onClose: () {},
          ),
        ),
      ),
    ));

    await tester.tap(find.text('立即开启'));
    await tester.pumpAndSettle();

    expect(find.text('浏览器未允许通知，请在站点设置中允许后重试'), findsOneWidget);
    expect(find.text('立即开启'), findsOneWidget);
  });
}
