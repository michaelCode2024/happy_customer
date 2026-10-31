import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:tongyu_agent_console/src/ui/platform_support_frame.dart';
import 'package:tongyu_agent_console/src/util/server_hint.dart';
import 'package:url_launcher/url_launcher.dart';

/// 通语官方技术支持收件箱。企业标识 tongyu-support。
/// 不使用官网商务入口；商务收件箱未建立，也不能拿它顶替。
const officialSupportInboxKey = 'tongyu-official-support';

const _supportStorage = 'tongyu.console.support';

String supportRoleLabel(String role) => switch (role) {
      'SUPERVISOR' => '客服主管',
      'AGENT' => '客服坐席',
      _ => '',
    };

String supportVisitorLabel({
  String tenantName = '',
  String role = '',
  String displayName = '',
}) {
  final parts = <String>[
    tenantName.trim(),
    supportRoleLabel(role),
    displayName.trim(),
  ].where((part) => part.isNotEmpty);
  final label = parts.join(' · ');
  return label.isEmpty ? '工作台访客' : _clip(label, 80);
}

String resolveSupportOrigin(String? typed) {
  final value = (typed ?? '').trim();
  if (value.isNotEmpty) return value;
  return initialServerHint('');
}

/// 配置里的技术支持入口必须就是官方收件箱。指向别处时拒绝，避免接到商务或其他企业。
String? officialSupportKeyFromConfig(Object? json) {
  if (json is! Map) return null;
  final entries = json['entries'];
  if (entries is! Map) return null;
  final support = entries['support'];
  if (support is! Map) return null;
  final key = support['inboxKey'];
  if (key is! String || key.trim() != officialSupportInboxKey) return null;
  return officialSupportInboxKey;
}

Uri platformSupportPage({
  required String origin,
  required String displayName,
  required String subject,
}) {
  final root = origin.trim().replaceAll(RegExp(r'/+$'), '');
  return Uri.parse('$root/h5/$officialSupportInboxKey').replace(
    queryParameters: <String, String>{
      'title': '通语技术支持',
      'displayName':
          _clip(displayName.trim().isEmpty ? '工作台访客' : displayName.trim(), 80),
      'subject': _clip(subject.trim().isEmpty ? '工作台技术支持' : subject.trim(), 80),
      'storage': _supportStorage,
      'source': 'PC',
      'theme': 'light',
    },
  );
}

Future<void> openPlatformSupport(
  BuildContext context, {
  String? origin,
  String displayName = '',
  String subject = '工作台技术支持',
}) async {
  final root = resolveSupportOrigin(origin);
  if (root.isEmpty) {
    _notice(context, '暂时无法打开通语技术支持');
    return;
  }
  final allowed = await _supportInboxAllowed(root);
  if (!context.mounted) return;
  if (!allowed) {
    _notice(context, '通语技术支持入口未就绪，请稍后再试');
    return;
  }
  final page = platformSupportPage(
    origin: root,
    displayName: displayName,
    subject: subject,
  );
  if (!kIsWeb) {
    final opened = await launchUrl(page, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      _notice(context, '暂时无法打开通语技术支持');
    }
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final size = MediaQuery.sizeOf(dialogContext);
      final width = size.width < 520 ? size.width - 24 : 420.0;
      final height = size.height < 760 ? size.height - 48 : 640.0;
      return Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          width: width,
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
                child: Row(children: [
                  const Expanded(
                    child: Text('通语技术支持',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(dialogContext),
                    icon: const Icon(Icons.close),
                  ),
                ]),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '账号停用和重置密码，请先联系本企业客服主管。这里只接通语技术支持。',
                  style: TextStyle(fontSize: 12, height: 1.4),
                ),
              ),
              Expanded(child: PlatformSupportFrame(url: page.toString())),
            ],
          ),
        ),
      );
    },
  );
}

Future<bool> _supportInboxAllowed(String origin) async {
  final root = origin.trim().replaceAll(RegExp(r'/+$'), '');
  final uri = Uri.parse('$root/website/support-config.json');
  try {
    final response = await http.get(uri).timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) return true;
    final decoded = jsonDecode(response.body);
    return officialSupportKeyFromConfig(decoded) == officialSupportInboxKey;
  } catch (_) {
    return true;
  }
}

void _notice(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

String _clip(String value, int max) {
  final units = value.runes.toList();
  if (units.length <= max) return value;
  return String.fromCharCodes(units.take(max));
}
