import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyu_agent_console/src/ui/app_safe_area.dart';

void main() {
  for (final row in [
    (0.0, 34.0, 0.0, 34.0),
    (34.0, 34.0, 0.0, 34.0),
    (0.0, 34.0, 300.0, 0.0),
    (0.0, 0.0, 0.0, 0.0),
    (0.0, 21.0, 0.0, 21.0)
  ]) {
    testWidgets('底部安全区域 native=${row.$1} browser=${row.$2} keyboard=${row.$3}',
        (tester) async {
      MediaQueryData? inside;
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
        data: MediaQueryData(
            size: const Size(800, 600),
            padding: EdgeInsets.only(bottom: row.$1),
            viewPadding: EdgeInsets.only(bottom: row.$1),
            viewInsets: EdgeInsets.only(bottom: row.$3)),
        child: AppSafeArea(
            browserBottom: row.$2,
            child: Builder(builder: (context) {
              inside = MediaQuery.of(context);
              return const SizedBox.expand(key: Key('content'));
            })),
      )));
      expect(tester.getBottomLeft(find.byKey(const Key('content'))).dy, 600,
          reason: '安全距离不能把页面整体垫高');
      expect(inside!.padding.bottom, row.$4, reason: '贴底栏自己读取这段高度，页面不再留一条空带');
      expect(inside!.viewInsets.bottom, row.$3,
          reason: '保留键盘距离供 Scaffold 自身避让');
      expect(tester.takeException(), isNull);
    });
  }
}
