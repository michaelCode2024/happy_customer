import 'package:flutter_test/flutter_test.dart';
import 'package:relaydesk_agent_console/main.dart';

void main() {
  testWidgets('renders the workbench', (tester) async {
    await tester.pumpWidget(const RelayDeskApp());
    expect(find.text('工作台已就绪'), findsOneWidget);
  });
}
