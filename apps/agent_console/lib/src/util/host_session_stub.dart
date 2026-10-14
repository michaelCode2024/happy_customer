import 'dart:async';

Stream<String> hostSessions() => const Stream.empty();
bool get isHostedConsole => false;
void closeHostedConsole() {}

String? get hostConversationId => null;
