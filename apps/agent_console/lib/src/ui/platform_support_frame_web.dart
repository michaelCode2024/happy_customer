// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui;

import 'package:flutter/material.dart';

class PlatformSupportFrame extends StatefulWidget {
  const PlatformSupportFrame({super.key, required this.url});

  final String url;

  @override
  State<PlatformSupportFrame> createState() => _PlatformSupportFrameState();
}

class _PlatformSupportFrameState extends State<PlatformSupportFrame> {
  static int _sequence = 0;
  late final String _viewType;
  late final html.IFrameElement _frame;

  @override
  void initState() {
    super.initState();
    _viewType = 'tongyu-official-support-${++_sequence}';
    _frame = html.IFrameElement()
      ..src = widget.url
      ..style.border = '0'
      ..style.width = '100%'
      ..style.height = '100%';
    ui.platformViewRegistry.registerViewFactory(_viewType, (_) => _frame);
  }

  @override
  void dispose() {
    _frame.src = 'about:blank';
    _frame.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
