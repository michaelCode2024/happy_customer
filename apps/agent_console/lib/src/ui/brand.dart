import 'package:tongyu_agent_console/src/ui/design_a.dart';
import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/ui/product_brand.dart';

/// 品牌字号档位：侧栏用紧凑，登录英雄区放大，保证第一眼先看到产品名。
enum TongYuBrandSize { compact, regular, large, hero }

/// 展示品牌「通语」。协议头、存储键和模块名同为 TongYu / tongyu。
class TongYuBrand extends StatelessWidget {
  const TongYuBrand({
    super.key,
    this.compact = false,
    this.size = TongYuBrandSize.regular,
    this.showEnglish = false,
  });

  /// 兼容旧调用；与 [size] 同时传入时以 [size] 为准，除非仍是默认 regular。
  final bool compact;
  final TongYuBrandSize size;

  /// 横排 Logo 是否显示 TongYu 副标；紧凑图标轨始终只显示标记。
  final bool showEnglish;

  TongYuBrandSize get _resolved {
    if (size != TongYuBrandSize.regular) return size;
    return compact ? TongYuBrandSize.compact : TongYuBrandSize.regular;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final resolved = _resolved;
    final mark = switch (resolved) {
      TongYuBrandSize.compact => 32.0,
      TongYuBrandSize.regular => 36.0,
      TongYuBrandSize.large => 44.0,
      TongYuBrandSize.hero => 56.0,
    };
    final titleStyle = switch (resolved) {
      TongYuBrandSize.compact => Theme.of(context).textTheme.titleMedium,
      TongYuBrandSize.regular => Theme.of(context).textTheme.titleLarge,
      TongYuBrandSize.large => Theme.of(context).textTheme.headlineSmall,
      TongYuBrandSize.hero => Theme.of(context).textTheme.headlineMedium,
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TongYuLogoMark(size: mark),
        if (resolved != TongYuBrandSize.compact) ...[
          SizedBox(width: mark * 0.28),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                ProductBrand.nameZh,
                style: titleStyle?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                  height: 1.05,
                  color: scheme.onSurface,
                ),
              ),
              if (showEnglish)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    ProductBrand.nameEn,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.8,
                          height: 1.1,
                        ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 通语 Logo 图形：双对话气泡，与官网使用相同的轮廓和品牌色。
class TongYuLogoMark extends StatelessWidget {
  const TongYuLogoMark({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _TongYuMarkPainter()),
    );
  }
}

class _TongYuMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 36, size.height / 36);
    final blue = Paint()..color = const Color(0xFF4263EB);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(2, 3, 25, 23), const Radius.circular(9)),
        blue);
    canvas.drawPath(
        Path()
          ..moveTo(8, 23)
          ..lineTo(8, 31)
          ..lineTo(17, 24)
          ..close(),
        blue);
    canvas.drawPath(
        Path()
          ..moveTo(14, 12)
          ..lineTo(30, 12)
          ..lineTo(30, 27)
          ..lineTo(24, 24)
          ..lineTo(14, 24),
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class WorkspaceNavItem {
  const WorkspaceNavItem(
    this.label,
    this.icon, {
    this.count = 0,
    this.group = '',
  });

  final String label;
  final IconData icon;
  final int count;

  /// 侧栏分组标题；相邻项相同则只显示一次，空串表示不分组。
  final String group;
}

/// 同一套导航覆盖平台、企业后台；分组 + 左侧色条选中，降低「菜单很多」的压迫感。
class WorkspaceSidebar extends StatelessWidget {
  const WorkspaceSidebar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    required this.subtitle,
    this.leading,
    this.footer,
  });

  final List<WorkspaceNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final String subtitle;
  final Widget? leading;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    // 左侧导航纯白/深色贴边，与腾讯云控制台侧栏一致，不做灰渐变。
    return Container(
      width: 232,
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF151922) : Colors.white,
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const TongYuBrand(),
                const SizedBox(height: 18),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (leading != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: dark
                      ? scheme.surfaceContainerHighest.withOpacity(0.45)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: scheme.outlineVariant.withOpacity(0.8)),
                ),
                child: leading!,
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (items[i].group.isNotEmpty &&
                      (i == 0 || items[i].group != items[i - 1].group))
                    Padding(
                      padding: EdgeInsets.fromLTRB(10, i == 0 ? 4 : 14, 8, 6),
                      child: Text(
                        items[i].group,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                          color: scheme.outline,
                        ),
                      ),
                    ),
                  Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Semantics(
                        button: true,
                        selected: i == selectedIndex,
                        label: items[i].label,
                        onTap: () => onSelected(i),
                        excludeSemantics: true,
                        child: Material(
                          color: i == selectedIndex
                              ? scheme.primaryContainer.withOpacity(0.85)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => onSelected(i),
                            child: Ink(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: i == selectedIndex
                                    ? Border(
                                        left: BorderSide(
                                          color: scheme.primary,
                                          width: 3,
                                        ),
                                      )
                                    : null,
                              ),
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                  i == selectedIndex ? 9 : 12,
                                  11,
                                  12,
                                  11,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      items[i].icon,
                                      size: 20,
                                      color: i == selectedIndex
                                          ? scheme.primary
                                          : scheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        items[i].label,
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: i == selectedIndex
                                              ? scheme.primary
                                              : scheme.onSurface,
                                          fontWeight: i == selectedIndex
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                        ),
                                      ),
                                    ),
                                    if (items[i].count > 0)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: i == selectedIndex
                                              ? scheme.primary
                                              : const Color(0xFFE11D48),
                                          borderRadius:
                                              BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          '${items[i].count}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      )),
                ],
              ],
            ),
          ),
          if (MediaQuery.sizeOf(context).height >= 960)
            Container(
                margin: const EdgeInsets.fromLTRB(14, 8, 14, 16),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: scheme.primaryContainer.withOpacity(.5),
                    borderRadius: BorderRadius.circular(14)),
                child: const Row(children: [
                  TongYuArtwork(ai: true, size: 50),
                  SizedBox(width: 8),
                  Expanded(
                      child: Text('让每一次咨询，\n都有温暖的回应。',
                          style: TextStyle(fontSize: 11, height: 1.8)))
                ])),
          if (footer != null)
            Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                child: footer!),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 16, 16),
            child: Text(
              '通语工作台',
              style:
                  TextStyle(fontSize: 11, color: scheme.outline, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// 客服工作台左侧图标轨。
///
/// 宽屏只留图标和短标题，把横向空间留给会话；窄屏仍走底部 NavigationBar。
class ConsoleIconRail extends StatelessWidget {
  const ConsoleIconRail({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    this.avatar,
    this.footer,
    this.expanded = true,
    this.showBrand = true,
  });

  final List<WorkspaceNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Widget? avatar;
  final Widget? footer;

  /// true：图标旁显示菜单名；false：仅图标（兼容极窄布局）。
  final bool expanded;
  final bool showBrand;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final rail = dark ? const Color(0xFF151922) : const Color(0xFFF4F6FC);
    final selected = dark ? const Color(0xFF243044) : const Color(0xFFE8EEFF);
    return Container(
      width: 72,
      decoration: BoxDecoration(
        color: rail,
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        child: Column(children: [
          const SizedBox(height: 14),
          if (showBrand) const TongYuLogoMark(size: 32),
          const SizedBox(height: 16),
          Expanded(
              child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            children: [
              for (var i = 0; i < items.length; i++)
                Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Tooltip(
                        message: items[i].label,
                        child: Material(
                          color: i == selectedIndex
                              ? selected
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => onSelected(i),
                            child: SizedBox(
                                height: 54,
                                child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(items[i].icon,
                                                size: 20,
                                                color: i == selectedIndex
                                                    ? scheme.primary
                                                    : scheme.onSurfaceVariant),
                                            const SizedBox(height: 3),
                                            Text(_railLabel(items[i].label),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 10,
                                                    height: 1.1,
                                                    fontWeight:
                                                        i == selectedIndex
                                                            ? FontWeight.w600
                                                            : FontWeight.w400,
                                                    color: i == selectedIndex
                                                        ? scheme.primary
                                                        : scheme
                                                            .onSurfaceVariant)),
                                          ]),
                                      if (items[i].count > 0)
                                        Positioned(
                                            top: 2,
                                            right: 2,
                                            child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 4,
                                                        vertical: 1),
                                                decoration: BoxDecoration(
                                                    color: scheme.primary,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            6)),
                                                child: Text(
                                                    items[i].count > 99
                                                        ? '99+'
                                                        : '${items[i].count}',
                                                    style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 9)))),
                                    ])),
                          ),
                        ))),
            ],
          )),
          if (footer != null) footer!,
          if (avatar != null)
            Padding(
                padding: const EdgeInsets.only(bottom: 12, top: 4),
                child: avatar!),
        ]),
      ),
    );
  }
}

/// 侧轨宽度有限：优先保留定稿里的短名，长名截到前两字。
/// 图标下方只放得下四个字；长名称收成导航里已经在用的短名。
String _railLabel(String label) {
  switch (label) {
    case '今天待办':
    case '工作概览':
      return '工作台';
    case '我的设置':
    case '个人设置':
      return '设置';
    case '接入网站':
    case '应用接入':
    case '接入管理':
      return '接入';
    case '渠道入口':
    case '渠道管理':
      return '渠道';
    case '同事账号':
    case '企业管理':
      return '企业';
    case '自动接待':
    case '自动回复':
      return '自动';
    case '收件箱':
      return '消息';
    case '数据统计':
      return '统计';
    case '平台概览':
      return '概览';
    case '企业与账号':
      return '企业';
    case '套餐与额度':
      return '额度';
    case '操作记录':
      return '记录';
    case '平台设置':
      return '设置';
    default:
      return label.length <= 4 ? label : label.substring(0, 2);
  }
}
