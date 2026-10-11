import 'package:flutter_test/flutter_test.dart';
import 'package:relaydesk_agent_console/src/util/server_hint.dart';

void main() {
  test('web uses the current origin for a first visit under /console/', () {
    expect(
      initialServerHint('',
          web: true, location: Uri.parse('https://chat.example.com/console/')),
      'https://chat.example.com',
    );
  });

  test('saved server overrides the page origin', () {
    expect(
      initialServerHint('https://other.example.com',
          web: true, location: Uri.parse('https://chat.example.com/console/')),
      'https://other.example.com',
    );
  });

  test('native app does not guess an address', () {
    expect(
      initialServerHint('',
          web: false, location: Uri.parse('https://chat.example.com/console/')),
      '',
    );
  });
}
