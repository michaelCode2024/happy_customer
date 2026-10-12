import 'package:flutter/material.dart';

/// 管理表单共用布局：错误留在表单内，提交期间阻止误关和重复请求。
class ConsoleFormDialog extends StatelessWidget {
  const ConsoleFormDialog(
      {super.key,
      required this.title,
      required this.description,
      required this.child,
      required this.onSubmit,
      this.busy = false,
      this.error,
      this.submitLabel = '保存',
      this.icon = Icons.edit_outlined,
      this.width = 680});
  final String title, description, submitLabel;
  final Widget child;
  final VoidCallback onSubmit;
  final bool busy;
  final String? error;
  final IconData icon;
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
        canPop: !busy,
        child: Dialog(
            insetPadding: const EdgeInsets.all(20),
            child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: width,
                    maxHeight: MediaQuery.sizeOf(context).height - 40),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(
                      padding: const EdgeInsets.fromLTRB(24, 22, 16, 20),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                    color: colors.primaryContainer,
                                    borderRadius: BorderRadius.circular(8)),
                                child: Icon(icon,
                                    color: colors.primary, size: 22)),
                            const SizedBox(width: 14),
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text(title,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge),
                                  const SizedBox(height: 5),
                                  Text(description,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                              color: colors.onSurfaceVariant)),
                                ])),
                            IconButton(
                                tooltip: '关闭表单',
                                onPressed:
                                    busy ? null : () => Navigator.pop(context),
                                icon: const Icon(Icons.close, size: 20)),
                          ])),
                  const Divider(),
                  if (error != null)
                    Padding(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                        child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                                color: colors.errorContainer.withAlpha(100),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                    color: colors.error.withAlpha(70))),
                            child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(Icons.error_outline,
                                      size: 18, color: colors.error),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: Text(error!,
                                          style:
                                              TextStyle(color: colors.error))),
                                ]))),
                  Flexible(
                      child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: AbsorbPointer(absorbing: busy, child: child))),
                  const Divider(),
                  Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 16),
                      child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            OutlinedButton(
                                onPressed:
                                    busy ? null : () => Navigator.pop(context),
                                child: const Text('取消')),
                            const SizedBox(width: 10),
                            FilledButton(
                                onPressed: busy ? null : onSubmit,
                                child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (busy) ...[
                                        const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2)),
                                        const SizedBox(width: 8)
                                      ],
                                      Text(busy ? '正在提交…' : submitLabel),
                                    ])),
                          ])),
                ]))));
  }
}

class ConsoleField extends StatelessWidget {
  const ConsoleField(this.label,
      {super.key, required this.child, this.required = false});
  final String label;
  final Widget child;
  final bool required;
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (required)
            Text('* ',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          Text(label, style: Theme.of(context).textTheme.labelLarge)
        ]),
        const SizedBox(height: 8),
        child,
      ]);
}

class ConsoleFormGrid extends StatelessWidget {
  const ConsoleFormGrid({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth >= 540 ? 2 : 1;
        return Wrap(spacing: 20, runSpacing: 20, children: [
          for (final child in children)
            SizedBox(
                width: (constraints.maxWidth - (columns - 1) * 20) / columns,
                child: child)
        ]);
      });
}

class ConsoleFormSection extends StatelessWidget {
  const ConsoleFormSection(this.title, {super.key, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        child,
      ]);
}
