// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

bool openChannelPreview(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
    return false;
  }
  html.window.open(uri.toString(), '_blank', 'noopener,noreferrer');
  return true;
}
