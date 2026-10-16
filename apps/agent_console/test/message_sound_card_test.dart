import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyu_agent_console/src/util/message_sound_card.dart';

void main() {
  testWidgets('窄屏展示所有方式，关闭后禁止选择和试听', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var enabled = true;
    var choice = 'sender';
    var plays = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: StatefulBuilder(
          builder: (context, refresh) => MessageSoundCard(
                enabled: enabled,
                choice: choice,
                onEnabled: (v) => refresh(() => enabled = v),
                onChoice: (v) => refresh(() => choice = v),
                onTest: () => plays++,
              )),
    ))));
    expect(find.text('客户消息播报'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('经典提示音'));
    await tester.pump();
    expect(choice, 'tone');
    await tester.tap(find.text('试听当前提醒'));
    expect(plays, 1);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.text('播报发送者'));
    await tester.tap(find.text('试听当前提醒'));
    expect(choice, 'tone');
    expect(plays, 1);
    expect(tester.takeException(), isNull);
  });
}
