import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/theme.dart';

/// Stitch B 高密控制台的通用表面参数。
///
/// 这里集中约束圆角、描边和留白，避免各页面各写一套 8/10/12/16 圆角，
/// 造成「同一系统里像多个产品」的观感。
abstract final class WbTokens {
  static const double cardRadius = 14;
  static const double controlRadius = 12;
  static const EdgeInsets pagePadding = EdgeInsets.fromLTRB(22, 6, 22, 26);
  static const EdgeInsets cardPadding = EdgeInsets.all(16);

  static Color border(BuildContext context) =>
      Theme.of(context).colorScheme.outlineVariant;

  static Color surface(BuildContext context) =>
      Theme.of(context).colorScheme.surface;

  static Color canvas(BuildContext context) =>
      Theme.of(context).scaffoldBackgroundColor;

  static Color muted(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;

  static Color tint(BuildContext context, Color color, [double alpha = .10]) =>
      color.withOpacity(alpha);

  static List<BoxShadow> softShadow(BuildContext context) =>
      RelayTheme.softShadow(Theme.of(context).brightness);

  static List<BoxShadow> cardShadow(BuildContext context) =>
      RelayTheme.cardShadow(Theme.of(context).brightness);
}

/// 页内工具条。外层已经有「企业 / 页面」路径，这里只留一行标题和操作，
/// 避免再叠一块大图标标题。
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
    // 被 Navigator.push 打开时显示返回；嵌在底栏 section 里时 canPop 为 false，不画多余箭头。
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    return AppBar(
      toolbarHeight: 52,
      titleSpacing: canPop ? 0 : 16,
      automaticallyImplyLeading: canPop,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      bottom: bottom,
      title: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 360;
          return Row(children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: scheme.primary.withOpacity(.08),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(icon, color: scheme.primary, size: 15),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface)),
                  if (!isNarrow)
                    Text(description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            height: 1.2,
                            fontWeight: FontWeight.w400,
                            color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ]);
        },
      ),
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
      Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: scheme.primary.withOpacity(.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: scheme.primary, size: 18),
      ),
      const SizedBox(width: 10),
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 1),
        Text(description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant, height: 1.3)),
      ])),
    ]);
    return Container(
        color: Colors.transparent,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: LayoutBuilder(
            builder: (context, box) => box.maxWidth < 660
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        heading,
                        if (actions.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(spacing: 8, runSpacing: 8, children: actions)
                        ]
                      ])
                : Row(children: [
                    Expanded(child: heading),
                    const SizedBox(width: 20),
                    Wrap(spacing: 8, runSpacing: 8, children: actions)
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
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              for (var i = 0; i < labels.length; i++)
                Semantics(
                    button: true,
                    selected: i == selectedIndex,
                    child: InkWell(
                        onTap: () => onSelected(i),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                                border: Border(
                                    bottom: BorderSide(
                                        width: 2.5,
                                        color: i == selectedIndex
                                            ? scheme.primary
                                            : Colors.transparent))),
                            child: Text(labels[i],
                                style: TextStyle(
                                    fontSize: 13.5,
                                    height: 1.2,
                                    fontWeight: i == selectedIndex
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: i == selectedIndex
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant)))))
            ])));
  }
}

/// 统一的面板容器：白底、12 圆角、1px 描边，可选标题行与右侧操作。
class WorkspaceCard extends StatelessWidget {
  const WorkspaceCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.icon,
    this.actions = const [],
    this.padding = WbTokens.cardPadding,
    this.headerPadding,
    this.clip = true,
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> actions;
  final EdgeInsets padding;
  final EdgeInsets? headerPadding;
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasHeader = title != null || actions.isNotEmpty;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasHeader)
          Container(
            padding: headerPadding ?? const EdgeInsets.fromLTRB(14, 12, 12, 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                    color: scheme.outlineVariant.withOpacity(.7)),
              ),
            ),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 15, color: scheme.primary),
                  const SizedBox(width: 7),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (title != null)
                        Text(title!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13,
                                height: 1.3,
                                fontWeight: FontWeight.w600)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11.5,
                                height: 1.35,
                                color: scheme.onSurfaceVariant)),
                      ],
                    ],
                  ),
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Wrap(spacing: 6, children: actions),
                ],
              ],
            ),
          ),
        Padding(padding: padding, child: child),
      ],
    );
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(WbTokens.cardRadius),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      child: body,
    );
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
      this.caption,
      this.trend,
      this.onTap});
  final String label, value;
  final IconData icon;
  final Color? tone;
  final String? caption;
  final String? trend;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = tone ?? scheme.primary;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurfaceVariant))),
              Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          color.withOpacity(.95),
                          color.withOpacity(.75),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: color.withOpacity(.22),
                          blurRadius: 12,
                          offset: const Offset(0, 6),
                        ),
                      ]),
                  child: Icon(icon, size: 15, color: Colors.white)),
            ]),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value,
                    style: theme.textTheme.headlineSmall?.copyWith(
                        fontSize: 23,
                        height: 1.1,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4)),
                if (trend != null) ...[
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: WorkspaceTag(
                        text: trend!, tone: color, dense: true),
                  ),
                ],
              ],
            ),
            if (caption != null) ...[
              const SizedBox(height: 6),
              Text(caption!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ]),
    );
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface.withOpacity(0.96),
        borderRadius: BorderRadius.circular(WbTokens.cardRadius),
        border: Border.all(color: scheme.outlineVariant.withOpacity(0.95)),
        boxShadow: WbTokens.cardShadow(context),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: -18,
            bottom: -28,
            child: IgnorePointer(
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      color.withOpacity(0.28),
                      color.withOpacity(0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Material(
            color: Colors.transparent,
            child: onTap == null
                ? content
                : InkWell(onTap: onTap, child: content),
          ),
        ],
      ),
    );
  }
}

/// 小徽标：状态、计数、标签共用。
class WorkspaceTag extends StatelessWidget {
  const WorkspaceTag(
      {super.key,
      required this.text,
      this.tone,
      this.dense = false,
      this.solid = false});
  final String text;
  final Color? tone;
  final bool dense;
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = tone ?? scheme.primary;
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: dense ? 5 : 7, vertical: dense ? 1 : 2.5),
      decoration: BoxDecoration(
        color: solid ? color : color.withOpacity(.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: dense ? 10 : 10.5,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: solid ? Colors.white : color)),
    );
  }
}

/// 空状态：统一留白与图标层级，避免各页各写一段灰色小字。
class WorkspaceEmptyState extends StatelessWidget {
  const WorkspaceEmptyState({
    super.key,
    required this.title,
    required this.description,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.compact = false,
  });
  final String title, description;
  final IconData icon;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final decoSize = compact ? 72.0 : 110.0;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: 24, vertical: compact ? 16 : 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: decoSize,
              height: decoSize * 0.85,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    left: decoSize * 0.22,
                    top: decoSize * 0.18,
                    child: Container(
                      width: decoSize * 0.52,
                      height: decoSize * 0.52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF7AA0FF), Color(0xFF3263FF)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF3263FF).withOpacity(0.28),
                            blurRadius: 22,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: decoSize * 0.06,
                    top: decoSize * 0.04,
                    child: Container(
                      width: decoSize * 0.30,
                      height: decoSize * 0.30,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [Color(0xFFB197FC), Color(0xFF845EF7)],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: decoSize * 0.08,
                    bottom: decoSize * 0.12,
                    child: Container(
                      width: decoSize * 0.24,
                      height: decoSize * 0.24,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [Color(0xFF63E6BE), Color(0xFF12B886)],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: decoSize * 0.14,
                    right: decoSize * 0.14,
                    bottom: 2,
                    child: Transform(
                      transform: Matrix4.skewX(-0.2),
                      child: Container(
                        height: 8,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          gradient: const LinearGradient(
                            colors: [
                              Color(0x885B8CFF),
                              Color(0x88845EF7),
                              Color(0x8812B886),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Icon(icon,
                      size: compact ? 18 : 20,
                      color: Colors.white.withOpacity(0.92)),
                ],
              ),
            ),
            SizedBox(height: compact ? 12 : 16),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: compact ? 14 : 15,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                    color: scheme.onSurface)),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(description,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.75,
                      color: scheme.onSurfaceVariant)),
            ),
            if (action != null) ...[
              const SizedBox(height: 14),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 列表行：左侧图标块 + 主副标题 + 尾部内容。
class WorkspaceListRow extends StatelessWidget {
  const WorkspaceListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconTone,
    this.leading,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconTone;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tone = iconTone ?? scheme.primary;
    final content = Container(
      color: selected ? scheme.primary.withOpacity(.05) : Colors.transparent,
      padding: padding,
      child: Row(children: [
        if (leading != null)
          leading!
        else if (icon != null)
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: tone.withOpacity(.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: tone),
          ),
        if (leading != null || icon != null) const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      fontWeight: FontWeight.w500)),
              if (subtitle != null) ...[
                const SizedBox(height: 1),
                Text(subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5,
                        height: 1.4,
                        color: scheme.onSurfaceVariant)),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          trailing!,
        ],
      ]),
    );
    if (onTap == null) return content;
    return InkWell(onTap: onTap, child: content);
  }
}

/// 列表容器：把多行内容包成一张标准面板。
class WorkspaceListCard extends StatelessWidget {
  const WorkspaceListCard({
    super.key,
    required this.children,
    this.title,
    this.subtitle,
    this.icon,
    this.actions = const [],
    this.empty,
    this.padded = false,
  });
  final List<Widget> children;
  final String? title;
  final String? subtitle;
  final IconData? icon;
  final List<Widget> actions;
  final Widget? empty;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return WorkspaceCard(
      title: title,
      subtitle: subtitle,
      icon: icon,
      actions: actions,
      padding: padded ? WbTokens.cardPadding : EdgeInsets.zero,
      child: children.isEmpty
          ? (empty ?? const SizedBox.shrink())
          : Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                        height: 1,
                        color: scheme.outlineVariant.withOpacity(.75)),
                  children[i],
                ],
              ],
            ),
    );
  }
}

/// 页内分段筛选条。
class WorkspaceFilterBar extends StatelessWidget {
  const WorkspaceFilterBar(
      {super.key, required this.children, this.padding});
  final List<Widget> children;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding ?? const EdgeInsets.fromLTRB(20, 10, 20, 12),
        child: Wrap(spacing: 8, runSpacing: 8, children: children),
      );
}

/// 宽屏让独立设置卡片并排，窄屏保留正常阅读顺序和自然高度。
class WorkspaceGrid extends StatelessWidget {
  const WorkspaceGrid(
      {super.key,
      required this.children,
      this.padding = const EdgeInsets.all(20)});
  final List<Widget> children;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth - padding.horizontal;
        final columns = width >= 880 ? 2 : 1;
        return SingleChildScrollView(
            padding: padding,
            child: Wrap(spacing: 14, runSpacing: 14, children: [
              for (final child in children)
                if (child is! SizedBox)
                  SizedBox(
                      width: (width - (columns - 1) * 14) / columns,
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
                ?.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 3),
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
                      padding: const EdgeInsets.only(bottom: 14), child: panel)
              ])
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children);
      });
}
