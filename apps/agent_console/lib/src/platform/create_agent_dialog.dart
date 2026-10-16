import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/ui/console_form_dialog.dart';
import 'package:tongyu_agent_console/src/platform/platform_controller.dart';
import 'package:tongyu_agent_console/src/api/api_exception.dart';

/// 平台独有的直接建号入口；密码不写本地存储，也不走邀请邮件。
class CreateAgentDialog extends StatefulWidget {
  const CreateAgentDialog(
      {super.key, required this.controller, required this.tenantId});
  final PlatformController controller;
  final String tenantId;
  @override
  State<CreateAgentDialog> createState() => _CreateAgentDialogState();
}

class _CreateAgentDialogState extends State<CreateAgentDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _email = TextEditingController(),
      _password = TextEditingController();
  String _role = 'AGENT';
  String? _error;
  bool _saving = false, _showPassword = false;
  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.api.createAgent(widget.tenantId, {
        'displayName': _name.text.trim(),
        'email': _email.text.trim(),
        'password': _password.text,
        'role': _role,
        'maxConcurrent': 10
      });
      await widget.controller.openTenant(widget.tenantId);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '提交失败，请检查连接后重试。已填写的信息已保留。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ConsoleFormDialog(
      title: '建立账户',
      description: '直接创建企业成员账号，创建后为成员分配接待渠道。',
      icon: Icons.person_add_alt_1_outlined,
      busy: _saving,
      error: _error,
      submitLabel: '建立账户',
      onSubmit: _save,
      child: Form(
          key: _form,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ConsoleFormSection('成员资料',
                child: ConsoleFormGrid(children: [
                  ConsoleField('成员姓名',
                      required: true,
                      child: TextFormField(
                          controller: _name,
                          decoration: const InputDecoration(hintText: '请输入姓名'),
                          validator: (v) =>
                              (v ?? '').trim().isEmpty ? '请填写姓名' : null)),
                  ConsoleField('登录用户名',
                      required: true,
                      child: TextFormField(
                          controller: _email,
                          keyboardType: TextInputType.text,
                          autocorrect: false,
                          decoration: const InputDecoration(
                              hintText: '例如：admin 或 kefu01'),
                          validator: (v) =>
                              (v ?? '').trim().isNotEmpty ? null : '请填写有效用户名')),
                ])),
            const SizedBox(height: 28),
            ConsoleFormSection('登录与权限',
                child: ConsoleFormGrid(children: [
                  ConsoleField('初始密码',
                      required: true,
                      child: TextFormField(
                          controller: _password,
                          obscureText: !_showPassword,
                          enableSuggestions: false,
                          autocorrect: false,
                          decoration: InputDecoration(
                              hintText: '至少 8 位',
                              suffixIcon: IconButton(
                                  tooltip: _showPassword ? '隐藏密码' : '显示密码',
                                  onPressed: () => setState(
                                      () => _showPassword = !_showPassword),
                                  icon: Icon(
                                      _showPassword
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                      size: 18))),
                          validator: (v) =>
                              (v ?? '').length < 8 ? '初始密码至少 8 位' : null)),
                  ConsoleField('账户角色',
                      required: true,
                      child: DropdownButtonFormField<String>(
                          isExpanded: true,
                          value: _role,
                          items: const [
                            DropdownMenuItem(
                                value: 'AGENT', child: Text('客服坐席')),
                            DropdownMenuItem(
                                value: 'SUPERVISOR', child: Text('客服主管'))
                          ],
                          onChanged: (v) =>
                              setState(() => _role = v ?? _role))),
                ])),
            const SizedBox(height: 20),
            Text('账号不会发送邀请邮件，请将登录信息交给对应成员。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ])));
}
