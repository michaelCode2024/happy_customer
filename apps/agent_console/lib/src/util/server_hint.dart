import 'package:flutter/foundation.dart';

String initialServerHint(String saved, {bool? web, Uri? location}) {
  if (saved.isNotEmpty) {
    return saved;
  }
  if (!(web ?? kIsWeb)) return const String.fromEnvironment('TONGYU_SERVER', defaultValue:'https://chat.lookfunny.xyz');
  final page = location ?? Uri.base;
  return page.scheme == 'http' || page.scheme == 'https' ? page.origin : '';
}
