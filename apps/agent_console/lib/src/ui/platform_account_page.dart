import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/platform/platform_controller.dart';
import 'package:tongyu_agent_console/src/ui/workspace_layout.dart';

class PlatformAccountPage extends StatefulWidget {
  const PlatformAccountPage({super.key, required this.controller});
  final PlatformController controller;
  @override
  State<PlatformAccountPage> createState() => _PlatformAccountPageState();
}

class _PlatformAccountPageState extends State<PlatformAccountPage> {
  late final Future<Map<String, dynamic>> _profile =
      widget.controller.api.profile();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;
  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_current.text.isEmpty ||
        _next.text.length < 8 ||
        _next.text != _confirm.text) {
      setState(() => _error = '请填写当前密码，输入至少 8 位的新密码并确认一致。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.api.changePassword(_current.text, _next.text);
      await widget.controller.signOut();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(24), children: [
        const WorkspaceHeading('管理员账号', '管理平台账号与登录安全'),
        FutureBuilder<Map<String, dynamic>>(
            future: _profile,
            builder: (context, snapshot) => Card(
                child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.admin_panel_settings_outlined,
                              size: 36),
                          const SizedBox(height: 16),
                          Text(
                              snapshot.data?['displayName']?.toString() ??
                                  '平台管理员',
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 8),
                          SelectableText(snapshot.hasError
                              ? '账号加载失败：${snapshot.error}'
                              : snapshot.data?['email']?.toString() ??
                                  '正在加载账号…'),
                          const SizedBox(height: 16),
                          const Text('登录有效期 8 小时。退出或修改密码后，服务端立即撤销对应会话。'),
                        ])))),
        const SizedBox(height: 20),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('修改登录密码',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 20),
                      TextField(
                          controller: _current,
                          obscureText: true,
                          decoration: const InputDecoration(labelText: '当前密码')),
                      const SizedBox(height: 14),
                      TextField(
                          controller: _next,
                          obscureText: true,
                          decoration:
                              const InputDecoration(labelText: '新密码（至少 8 位）')),
                      const SizedBox(height: 14),
                      TextField(
                          controller: _confirm,
                          obscureText: true,
                          decoration:
                              const InputDecoration(labelText: '确认新密码')),
                      const SizedBox(height: 16),
                      if (_error != null)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(_error!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error))),
                      FilledButton(
                          onPressed: _busy ? null : _save,
                          child: Text(_busy ? '正在更新…' : '更新密码并重新登录')),
                    ]))),
      ]);
}
