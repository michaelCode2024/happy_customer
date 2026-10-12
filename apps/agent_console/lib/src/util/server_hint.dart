import 'package:flutter/foundation.dart';

String initialServerHint(String saved, {bool? web, Uri? location}) {
  if (saved.isNotEmpty || !(web ?? kIsWeb)) {
    return saved;
  }
  final page = location ?? Uri.base;
  return page.scheme == 'http' || page.scheme == 'https' ? page.origin : '';
}
