import 'package:flutter/material.dart';

/// 页内工具条。外层已经有「企业 / 页面」路径，这里只留一行标题和操作，避免再叠一块大图标标题。
class WorkspaceAppBar extends StatelessWidget implements PreferredSizeWidget {
  const WorkspaceAppBar(
      {super.key,
      required this.title,
      required this.description,
      required this.icon,
      this.actions = const [],
      this.bottom});
  final String title, description;
  final IconData icon;
  final List<Widget> actions;
  final PreferredSizeWidget? bottom;
  @override
  Size get preferredSize =>
      Size.fromHeight(52 + (bottom?.preferredSize.height ?? 0));
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppBar(
      toolbarHeight: 52,
      titleSpacing: 16,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const Border(),
      bottom: bottom,
      title: Row(children: [
        Icon(icon, color: scheme.primary, size: 18),
        const SizedBox(width: 8),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface)),
          Text(description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  fontWeight: FontWeight.w400,
                  color: scheme.onSurfaceVariant)),
        ])),
      ]),
      actions: [...actions, const SizedBox(width: 8)],
    );
  }
}

/// 页面标题与操作。窄屏把操作换到下一行，避免和标题挤在同一行。
class WorkspacePageHeader extends StatelessWidget {
  const WorkspacePageHeader(
      {super.key,
      required this.title,
      required this.description,
      required this.icon,
      this.actions = const []});
  final String title, description;
  final IconData icon;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final heading = Row(children: [
      Icon(icon, color: scheme.primary, size: 18),
      const SizedBox(width: 8),
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontSize: 16, fontWeight: FontWeight.w600)),
        Text(description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant, height: 1.3)),
      ])),
    ]);
    return Container(
        color: Colors.transparent,
        padding: const EdgeInsets.fromLTRB(20, 12, 16, 8),
        child: LayoutBuilder(
            builder: (context, box) => box.maxWidth < 660
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        heading,
                        if (actions.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, runSpacing: 8, children: actions)
                        ]
                      ])
                : Row(children: [
                    Expanded(child: heading),
                    const SizedBox(width: 20),
                    Wrap(spacing: 8, children: actions)
                  ])));
  }
}

class WorkspaceTabs extends StatelessWidget {
  const WorkspaceTabs(
      {super.key,
      required this.labels,
      required this.selectedIndex,
      required this.onSelected});
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
        decoration: BoxDecoration(
            color: scheme.surface,
            border: Border(bottom: BorderSide(color: scheme.outlineVariant))),
        child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(children: [
              for (var i = 0; i < labels.length; i++)
                Semantics(
                    button: true,
                    selected: i == selectedIndex,
                    child: InkWell(
                        onTap: () => onSelected(i),
                        child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 14),
                            decoration: BoxDecoration(
                                border: Border(
                                    bottom: BorderSide(
                                        width: 2,
                                        color: i == selectedIndex
                                            ? scheme.primary
                                            : Colors.transparent))),
                            child: Text(labels[i],
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: i == selectedIndex
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: i == selectedIndex
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant)))))
            ])));
  }
}

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
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(10)),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                      color: color.withOpacity(.08),
                      borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, size: 16, color: color)),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(label,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)))
            ]),
            const SizedBox(height: 10),
            Text(value,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontSize: 22, fontWeight: FontWeight.w600)),
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
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(description,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
