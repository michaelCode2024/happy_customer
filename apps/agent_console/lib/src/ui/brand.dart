import 'package:flutter/material.dart';
import 'package:relaydesk_agent_console/src/ui/product_brand.dart';

/// 品牌字号档位：侧栏用紧凑，登录英雄区放大，保证第一眼先看到产品名。
enum TongYuBrandSize { compact, regular, large, hero }

/// 兼容旧调用名；实现已统一为通语标识。
typedef LiaoQiaoBrandSize = TongYuBrandSize;

/// 展示品牌「通语」；RelayDesk 协议与存储键不变，已有客户无需迁移。
class TongYuBrand extends StatelessWidget {
  const TongYuBrand({
    super.key,
    this.compact = false,
    this.size = TongYuBrandSize.regular,
    this.showEnglish = true,
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

/// 旧名别名，避免散落引用一次性炸裂。
class LiaoQiaoBrand extends TongYuBrand {
  const LiaoQiaoBrand({
    super.key,
    super.compact = false,
    super.size = TongYuBrandSize.regular,
    super.showEnglish = true,
  });
}

/// 通语 Logo 图形：蓝底圆角方块 + 双对话气泡（对齐正式横排标识）。
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
    final r = size.shortestSide;
    final radius = r * 0.22;
    final bg = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, r, r),
      Radius.circular(radius),
    );
    canvas.drawRRect(bg, Paint()..color = const Color(0xFF2F6BFF));

    // 左侧主气泡
    final left = RRect.fromRectAndRadius(
      Rect.fromLTWH(r * 0.16, r * 0.18, r * 0.48, r * 0.42),
      Radius.circular(r * 0.12),
    );
    canvas.drawRRect(left, Paint()..color = Colors.white);
    final leftTail = Path()
      ..moveTo(r * 0.22, r * 0.56)
      ..lineTo(r * 0.18, r * 0.72)
      ..lineTo(r * 0.36, r * 0.58)
      ..close();
    canvas.drawPath(leftTail, Paint()..color = Colors.white);

    // 右侧叠放气泡，略浅以区分层次
    final right = RRect.fromRectAndRadius(
      Rect.fromLTWH(r * 0.40, r * 0.36, r * 0.42, r * 0.36),
      Radius.circular(r * 0.11),
    );
    canvas.drawRRect(right, Paint()..color = const Color(0xFFE8F0FF));
    final rightTail = Path()
      ..moveTo(r * 0.72, r * 0.68)
      ..lineTo(r * 0.82, r * 0.82)
      ..lineTo(r * 0.62, r * 0.70)
      ..close();
    canvas.drawPath(rightTail, Paint()..color = const Color(0xFFE8F0FF));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class WorkspaceNavItem {
  const WorkspaceNavItem(this.label, this.icon, {this.count = 0});
  final String label;
  final IconData icon;
  final int count;
}

/// 同一套导航覆盖平台、企业后台；选中态使用轻底色，减少长时间接待的视觉负担。
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
    return Container(
      width: 232,
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF171B24) : Colors.white,
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const TongYuBrand(),
                const SizedBox(height: 10),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (leading != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withOpacity(0.65),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: scheme.outlineVariant.withOpacity(0.7),
                  ),
                ),
                child: leading!,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 16, 8),
            child: Text(
              '工作空间',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: scheme.outline,
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                for (var i = 0; i < items.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Material(
                      color: i == selectedIndex
                          ? scheme.primaryContainer
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => onSelected(i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 11,
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
                                        : scheme.error,
                                    borderRadius: BorderRadius.circular(999),
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
              ],
            ),
          ),
          if (footer != null)
            Padding(padding: const EdgeInsets.all(16), child: footer!),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 16, 18),
            child: Text(
              '${ProductBrand.nameZh} · ${ProductBrand.tagline}',
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}

/// 客服工作台左侧导航轨。
///
/// 定稿为「图标 + 中文名」展开态（约 88px），不再只露图标；窄屏仍走底部 NavigationBar。
class ConsoleIconRail extends StatelessWidget {
  const ConsoleIconRail({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    this.avatar,
    this.footer,
    this.expanded = true,
  });

  final List<WorkspaceNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Widget? avatar;
  final Widget? footer;

  /// true：图标下显示菜单名；false：仅图标（兼容极窄布局）。
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return Container(
      width: expanded ? 88 : 72,
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF141820) : const Color(0xFFF5F6F8),
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 14),
            const TongYuBrand(compact: true),
            const SizedBox(height: 18),
            if (avatar != null) ...[
              avatar!,
              const SizedBox(height: 14),
            ],
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (var i = 0; i < items.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Builder(
                        builder: (context) {
                          // 展开态文案已可见，不必再挂 Tooltip；收起态才用悬停提示。
                          final tile = Material(
                            color: i == selectedIndex
                                ? scheme.primaryContainer
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () => onSelected(i),
                              child: SizedBox(
                                height: expanded ? 58 : 46,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          items[i].icon,
                                          size: 22,
                                          color: i == selectedIndex
                                              ? scheme.primary
                                              : scheme.onSurfaceVariant,
                                        ),
                                        if (expanded) ...[
                                          const SizedBox(height: 4),
                                          Text(
                                            // 四字菜单缩成短名，避免轨宽被撑破。
                                            _railLabel(items[i].label),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 11,
                                              height: 1.1,
                                              fontWeight: i == selectedIndex
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                              color: i == selectedIndex
                                                  ? scheme.primary
                                                  : scheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    if (items[i].count > 0)
                                      Positioned(
                                        top: 4,
                                        right: expanded ? 10 : 6,
                                        child: Container(
                                          constraints: const BoxConstraints(
                                              minWidth: 16),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: scheme.error,
                                            borderRadius:
                                                BorderRadius.circular(999),
                                          ),
                                          child: Text(
                                            items[i].count > 99
                                                ? '99+'
                                                : '${items[i].count}',
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 9,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                          if (expanded) return tile;
                          return Tooltip(
                              message: items[i].label, child: tile);
                        },
                      ),
                    ),
                ],
              ),
            ),
            if (footer != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 14),
                child: footer!,
              ),
          ],
        ),
      ),
    );
  }
}

/// 侧轨宽度有限：优先保留定稿里的短名，长名截到前两字。
String _railLabel(String label) {
  switch (label) {
    case '工作概览':
      return '概览';
    case '收件箱':
      return '收件箱';
    case '数据统计':
      return '统计';
    case '知识库':
      return '知识库';
    case '应用接入':
      return '接入';
    case '自动回复':
      return '自动';
    case '渠道管理':
      return '渠道';
    case '个人设置':
      return '设置';
    case '企业管理':
      return '企业';
    case '群聊':
      return '群聊';
    default:
      return label.length <= 3 ? label : label.substring(0, 2);
  }
}
