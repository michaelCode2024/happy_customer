import 'package:flutter/material.dart';
import 'package:relaydesk_agent_console/src/api/models.dart';

/// 创建规则与字段校验集中在弹窗内；失败保留填写内容。
class CreateGroupDialog extends StatefulWidget {
  const CreateGroupDialog(
      {super.key, required this.inboxes, required this.onCreate});
  final List<InboxInfo> inboxes;
  final Future<String> Function(Map<String, dynamic>) onCreate;
  @override
  State<CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<CreateGroupDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  String _kind = 'INTERNAL';
  String? _inbox;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    if (widget.inboxes.length == 1) _inbox = widget.inboxes.first.id;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Widget _label(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall));
  InputDecoration _decoration(String hint) => InputDecoration(
      hintText: hint,
      filled: true,
      fillColor:
          Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(70),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:
              BorderSide(color: Theme.of(context).colorScheme.outlineVariant)));
  Widget _kindCard(
      String value, String title, String description, IconData icon) {
    final theme = Theme.of(context);
    final selected = _kind == value;
    return Semantics(
        selected: selected,
        button: true,
        child: InkWell(
            onTap: _busy
                ? null
                : () => setState(() {
                      _kind = value;
                      _error = null;
                    }),
            borderRadius: BorderRadius.circular(10),
            child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: selected
                        ? theme.colorScheme.primaryContainer.withAlpha(65)
                        : theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                        width: selected ? 1.5 : 1)),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon,
                          size: 22,
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(title, style: theme.textTheme.titleSmall),
                            const SizedBox(height: 4),
                            Text(description, style: theme.textTheme.bodySmall)
                          ])),
                      const SizedBox(width: 8),
                      Icon(
                          selected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 20,
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline)
                    ]))));
  }

  Future<void> _create() async {
    if (!_form.currentState!.validate()) return;
    if (_kind == 'SERVICE' && _inbox == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await widget.onCreate({
        'name': _name.text.trim(),
        'kind': _kind,
        if (_kind == 'SERVICE') 'inboxId': _inbox,
        'agentIds': <String>[]
      });
      if (mounted) Navigator.of(context).pop(id);
    } catch (e) {
      if (mounted)
        setState(() {
          _busy = false;
          _error = '创建失败，请检查后重试：$e';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final noInbox = _kind == 'SERVICE' && widget.inboxes.isEmpty;
    return PopScope(
        canPop: !_busy,
        child: AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
            contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            title: const Text('创建群聊'),
            content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                    child: Form(
                        key: _form,
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text('先选择沟通对象，再填写群名称。你将成为这个群的群主。',
                                  style: theme.textTheme.bodySmall),
                              const SizedBox(height: 16),
                              _label('1. 选择群类型'),
                              LayoutBuilder(builder: (context, constraints) {
                                final internal = _kindCard(
                                    'INTERNAL',
                                    '内部协作群',
                                    '只让企业同事加入，用于团队讨论；不接入客户。',
                                    Icons.groups_outlined);
                                final service = _kindCard(
                                    'SERVICE',
                                    '客户服务群',
                                    '客服与客户在同一群沟通，需要关联客服入口。',
                                    Icons.support_agent);
                                if (constraints.maxWidth < 480)
                                  return Column(children: [
                                    internal,
                                    const SizedBox(height: 10),
                                    service
                                  ]);
                                return IntrinsicHeight(
                                    child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                      Expanded(child: internal),
                                      const SizedBox(width: 12),
                                      Expanded(child: service)
                                    ]));
                              }),
                              const SizedBox(height: 16),
                              _label('2. 填写群名称'),
                              TextFormField(
                                  controller: _name,
                                  enabled: !_busy,
                                  maxLength: 120,
                                  textInputAction: TextInputAction.done,
                                  decoration: _decoration(_kind == 'INTERNAL'
                                      ? '例如：售后协作群'
                                      : '例如：客户项目服务群'),
                                  validator: (v) {
                                    final name = (v ?? '').trim();
                                    if (name.isEmpty) return '请填写群名称';
                                    if (name.runes.length > 120)
                                      return '群名称不能超过120个字符';
                                    return null;
                                  }),
                              if (_kind == 'SERVICE') ...[
                                const SizedBox(height: 8),
                                _label('3. 关联客服入口'),
                                if (noInbox)
                                  Container(
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                          color: theme
                                              .colorScheme.errorContainer
                                              .withAlpha(90),
                                          borderRadius:
                                              BorderRadius.circular(8)),
                                      child: const Text(
                                          '你还没有可用的客服入口，暂时不能创建客户服务群。请联系主管为你分配入口权限，或切换为内部协作群。'))
                                else
                                  DropdownButtonFormField<String>(
                                      value: _inbox,
                                      isExpanded: true,
                                      decoration: _decoration('请选择客服入口'),
                                      items: widget.inboxes
                                          .map((i) => DropdownMenuItem(
                                              value: i.id,
                                              child: Text(i.name,
                                                  overflow:
                                                      TextOverflow.ellipsis)))
                                          .toList(),
                                      onChanged: _busy
                                          ? null
                                          : (v) => setState(() => _inbox = v),
                                      validator: (v) =>
                                          v == null ? '请选择有接待权限的客服入口' : null),
                                if (!noInbox)
                                  const Padding(
                                      padding: EdgeInsets.only(top: 8),
                                      child: Text(
                                          '这里仅列出你有接待权限的入口。客户将通过所选入口的邀请链接入群。',
                                          style: TextStyle(fontSize: 12))),
                              ],
                              const SizedBox(height: 16),
                              Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                      color: theme
                                          .colorScheme.surfaceContainerHighest
                                          .withAlpha(65),
                                      borderRadius: BorderRadius.circular(8)),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text('创建后怎么加人？',
                                            style: theme.textTheme.titleSmall),
                                        const SizedBox(height: 8),
                                        const Text(
                                            '1. 创建完成后，你就是群主。\n2. 进入“群成员”，添加企业同事。'),
                                        if (_kind == 'SERVICE')
                                          const Text(
                                              '3. 点击“邀请客户”，复制入群链接给客户。\n客户无需注册客服账号。'),
                                        if (_kind == 'INTERNAL')
                                          const Text('• 内部协作群不能邀请客户。')
                                      ])),
                              if (_error != null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(_error!,
                                        style: TextStyle(
                                            color: theme.colorScheme.error))),
                            ])))),
            actions: [
              TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('取消')),
              FilledButton.icon(
                  onPressed: _busy || noInbox ? null : _create,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add, size: 18),
                  label: Text(_busy ? '正在创建' : '创建并进入群聊'))
            ]));
  }
}
