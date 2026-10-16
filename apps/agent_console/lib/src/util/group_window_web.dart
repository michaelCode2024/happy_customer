import 'dart:async';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui;
import 'package:flutter/material.dart';

int _openPanels = 0;
bool get groupCallPanelIsOpen => _openPanels > 0;

Widget groupCallPanel(String groupId, String token, String actorId) =>
    _GroupCallFrame(groupId: groupId, token: token, actorId: actorId);

class _GroupCallFrame extends StatefulWidget {
  const _GroupCallFrame(
      {required this.groupId, required this.token, required this.actorId});
  final String groupId, token, actorId;
  @override
  State<_GroupCallFrame> createState() => _GroupCallFrameState();
}

class _GroupCallFrameState extends State<_GroupCallFrame> {
  static int sequence = 0;
  late final String viewType;
  late final html.IFrameElement frame;
  StreamSubscription<html.Event>? loaded;
  @override
  void initState() {
    super.initState();
    _openPanels++;
    final origin = html.window.location.origin;
    viewType = 'tongyu-group-call-${++sequence}';
    frame = html.IFrameElement()
      ..src = '$origin/groups.html?console=1&embedded=1'
      ..setAttribute('allow', 'microphone; camera; autoplay')
      ..style.border = '0'
      ..style.width = '100%'
      ..style.height = '100%';
    loaded = frame.onLoad.listen((_) {
      frame.contentWindow?.postMessage(
          jsonEncode({
            'type': 'tongyu-group-auth',
            'token': widget.token,
            'groupId': widget.groupId,
            'actorId': widget.actorId,
            'actorKind': 'agent'
          }),
          origin);
    });
    ui.platformViewRegistry.registerViewFactory(viewType, (_) => frame);
  }

  @override
  void dispose() {
    _openPanels--;
    loaded?.cancel();
    frame.src = 'about:blank';
    frame.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: viewType);
}
