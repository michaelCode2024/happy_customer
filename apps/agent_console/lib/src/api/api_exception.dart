/// Every non-2xx response from the RelayDesk API, carrying the machine-readable
/// code the server sends alongside the human message.
///
/// The console branches on [code] rather than on the message text, so a wording
/// change on the server never breaks the client: `CONVERSATION_NOT_FOUND` and
/// `ALREADY_ASSIGNED` are decisions, whereas the message is only ever displayed.
class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  /// The session token is gone: the caller should return to the login screen.
  bool get isUnauthorized => statusCode == 401;

  /// A request that never reached the server, or whose response never arrived.
  bool get isNetworkFailure => statusCode == 0;

  /// The conversation was taken by someone else between listing and claiming.
  bool get isTaken => statusCode == 409;

  /// The agent may not see this conversation (missing inbox membership).
  bool get isMissing => statusCode == 404;

  @override
  String toString() => message;
}
