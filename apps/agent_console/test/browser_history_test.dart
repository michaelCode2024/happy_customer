import 'package:flutter_test/flutter_test.dart';
import 'package:tongyu_agent_console/src/util/browser_history.dart';

void main() {
  test('非 Web 的 History 门闸可安全调用且不影响监听', () async {
    final gate = BrowserHistoryGate();
    var hits = 0;
    final sub = gate.listen(() => hits++);
    gate.push('conversation/c1');
    gate.syncAfterLocalPop();
    await Future<void>.delayed(Duration.zero);
    expect(hits, 0);
    await sub.cancel();
  });
}
