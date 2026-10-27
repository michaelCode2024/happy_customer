import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyu_agent_console/src/ui/browser_back_page_route.dart';
import 'package:tongyu_agent_console/src/util/browser_history.dart';

void main() {
  test('非 Web 的 History 门闸可安全调用且不影响监听', () async {
    final gate = BrowserHistoryGate();
    var hits = 0;
    final sub = gate.listen(() {
      hits++;
      return true;
    });
    gate.push('conversation/c1');
    gate.syncAfterLocalPop();
    gate.drain();
    await Future<void>.delayed(Duration.zero);
    expect(hits, 0);
    await sub.cancel();
  });

  testWidgets('浏览器回退瞬时卸掉当前页，不播第二段转场', (tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: key,
      home: const Text('home'),
    ));
    key.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('child')),
    );
    await tester.pumpAndSettle();
    expect(find.text('child'), findsOneWidget);

    final popped = await popNavigatorWithoutTransition(key.currentState!);
    await tester.pump();

    expect(popped, isTrue);
    expect(find.text('home'), findsOneWidget);
    expect(find.text('child', skipOffstage: false), findsNothing);
  });

  testWidgets('浏览器专用路由回退也只卸一层', (tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: key,
      home: const Text('home'),
    ));
    final route = BrowserBackPageRoute<void>(
      builder: (_) => const Text('child'),
    );
    key.currentState!.push(route);
    await tester.pumpAndSettle();

    route.popFromBrowser();
    await tester.pump();
    await tester.pump();

    expect(find.text('home'), findsOneWidget);
    expect(find.text('child', skipOffstage: false), findsNothing);
  });
}
