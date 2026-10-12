import 'package:flutter/material.dart';

/// KPI 仅展示调用方提供的真实指标；没有比较数据时不生成变化率。
class WorkspaceKpiCard extends StatelessWidget {
  const WorkspaceKpiCard(
      {super.key,
      required this.label,
      required this.value,
      required this.icon,
      this.tone,
      this.caption});
  final String label, value;
  final IconData icon;
  final Color? tone;
  final String? caption;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tone ?? theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(10)),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 10),
            Text(value,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontSize: 28, fontWeight: FontWeight.w500)),
            if (caption != null) ...[
              const SizedBox(height: 8),
              Text(caption!,
                  style: theme.textTheme.bodySmall?.copyWith(color: color))
            ],
          ]),
    );
  }
}

/// 宽屏让独立设置卡片并排，窄屏保留正常阅读顺序和自然高度。
class WorkspaceGrid extends StatelessWidget {
  const WorkspaceGrid(
      {super.key,
      required this.children,
      this.padding = const EdgeInsets.all(24)});
  final List<Widget> children;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth - padding.horizontal;
        final columns = width >= 880 ? 2 : 1;
        return SingleChildScrollView(
            padding: padding,
            child: Wrap(spacing: 16, runSpacing: 16, children: [
              for (final child in children)
                if (child is! SizedBox)
                  SizedBox(
                      width: (width - (columns - 1) * 16) / columns,
                      child: child)
            ]));
      });
}

class WorkspaceHeading extends StatelessWidget {
  const WorkspaceHeading(this.title, this.description, {super.key});
  final String title;
  final String description;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontSize: 26, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(description,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]));
}

/// 平台信息面板避免在手机上被一条横向布局挤压。
class WorkspacePair extends StatelessWidget {
  const WorkspacePair({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final panels = [
          for (final child in children)
            if (child is Expanded) child.child
        ];
        return constraints.maxWidth < 680
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final panel in panels)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 16), child: panel)
              ])
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children);
      });
}
