import 'package:flutter/material.dart';
import 'package:relaydesk_agent_console/src/ui/brand.dart';
import 'package:relaydesk_agent_console/src/ui/product_brand.dart';

/// 两类账号共用品牌登录框。
///
/// 宽屏左侧做品牌主视觉，右侧收纳表单；窄屏只保留表单并置顶品牌，
/// 避免小屏横向滚动。动画只做入场一次，便于 widget 测试 pumpAndSettle。
class LoginShell extends StatefulWidget {
  const LoginShell({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
    this.badgeLabel,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  /// 区分客服工作台与平台运营入口，避免两套表单长得一模一样。
  final String? badgeLabel;

  @override
  State<LoginShell> createState() => _LoginShellState();
}

class _LoginShellState extends State<LoginShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    );
    // 缓入 + 轻微上移，让表单区先被注意到，而不是整页同时跳出来。
    _fade = CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic));
    _entrance.forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = scheme.brightness == Brightness.dark;

    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: _LoginAtmosphere()),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 960;
                return SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: wide ? 40 : 20,
                    vertical: wide ? 32 : 20,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: (constraints.maxHeight - (wide ? 64 : 40))
                          .clamp(0, double.infinity),
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1120),
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    flex: 11,
                                    child: FadeTransition(
                                      opacity: _fade,
                                      child: const _LoginHeroPanel(),
                                    ),
                                  ),
                                  const SizedBox(width: 48),
                                  Expanded(
                                    flex: 9,
                                    child: SlideTransition(
                                      position: _slide,
                                      child: FadeTransition(
                                        opacity: _fade,
                                        child: _LoginFormCard(
                                          icon: widget.icon,
                                          title: widget.title,
                                          subtitle: widget.subtitle,
                                          badgeLabel: widget.badgeLabel,
                                          showBrand: false,
                                          child: widget.child,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : SlideTransition(
                                position: _slide,
                                child: FadeTransition(
                                  opacity: _fade,
                                  child: _LoginFormCard(
                                    icon: widget.icon,
                                    title: widget.title,
                                    subtitle: widget.subtitle,
                                    badgeLabel: widget.badgeLabel,
                                    showBrand: true,
                                    child: widget.child,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // 角落轻量状态点，暗示服务在线，不抢主视觉。
          Positioned(
            left: 20,
            bottom: 16,
            child: IgnorePointer(
              child: Text(
                dark
                    ? ProductBrand.consoleTitle
                    : '${ProductBrand.nameZh} · 安全连接中',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurface.withOpacity(0.38),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 登录页氛围层：冷色径向渐变 + 低对比网格，避免纯色底显得空。
class _LoginAtmosphere extends StatelessWidget {
  const _LoginAtmosphere();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [
                  Color(0xFF12161F),
                  Color(0xFF1A2233),
                  Color(0xFF151A24),
                ]
              : const [
                  Color(0xFFEEF3FB),
                  Color(0xFFF7F9FC),
                  Color(0xFFE8F0FA),
                ],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -120,
            right: -80,
            child: _GlowOrb(
              diameter: 360,
              color: dark
                  ? const Color(0xFF2F6BFF).withOpacity(0.18)
                  : const Color(0xFF2F6BFF).withOpacity(0.12),
            ),
          ),
          Positioned(
            bottom: -140,
            left: -100,
            child: _GlowOrb(
              diameter: 420,
              color: dark
                  ? const Color(0xFF1B9E8A).withOpacity(0.10)
                  : const Color(0xFF5B8DEF).withOpacity(0.10),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: _GridPainter(
                color: (dark ? Colors.white : const Color(0xFF1F2329))
                    .withOpacity(dark ? 0.04 : 0.035),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({required this.diameter, required this.color});

  final double diameter;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withOpacity(0)],
          ),
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const step = 48.0;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 宽屏左侧：品牌是第一信号，再跟一句价值主张与对话示意。
class _LoginHeroPanel extends StatelessWidget {
  const _LoginHeroPanel();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(right: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 定稿：Logo + 通语 / TongYu 占满第一视线，不再堆插画与功能胶囊。
          const TongYuBrand(size: TongYuBrandSize.hero),
          const SizedBox(height: 36),
          Text(
            ProductBrand.tagline,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.25,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            ProductBrand.subtitle,
            style: theme.textTheme.titleMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 36),
          const _ConversationPreview(),
        ],
      ),
    );
  }
}

/// 对话示意卡：用真实场景文案建立「这是客服产品」的直觉，而不是抽象图标墙。
class _ConversationPreview extends StatelessWidget {
  const _ConversationPreview();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surface.withOpacity(0.88),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withOpacity(0.9)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1F2329).withOpacity(0.06),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.forum_rounded,
                    size: 16, color: scheme.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '连接客户，也连接团队',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF34B368),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '在线',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerLeft,
            child: _PreviewBubble(
              text: '你好，有个问题想咨询一下。',
              color: scheme.surfaceContainerHighest,
              alignEnd: false,
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: _PreviewBubble(
              text: '我在，我们一起看看。',
              color: scheme.primaryContainer,
              alignEnd: true,
            ),
          ),
          const SizedBox(height: 16),
          Divider(color: scheme.outlineVariant.withOpacity(0.7)),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.sentiment_satisfied_alt_outlined,
                  size: 18, color: scheme.outline),
              const SizedBox(width: 12),
              Icon(Icons.attach_file, size: 18, color: scheme.outline),
              const Spacer(),
              Text(
                '每个企业拥有独立的账号、消息与接入空间',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({
    required this.text,
    required this.color,
    required this.alignEnd,
  });

  final String text;
  final Color color;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(12),
          topRight: const Radius.circular(12),
          bottomLeft: Radius.circular(alignEnd ? 12 : 4),
          bottomRight: Radius.circular(alignEnd ? 4 : 12),
        ),
      ),
      child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}

class _LoginFormCard extends StatelessWidget {
  const _LoginFormCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
    required this.showBrand,
    this.badgeLabel,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;
  final bool showBrand;
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          // 默认测试视口 800×600，上下留白不能过大，否则底部切换入口滚出屏幕。
          padding: const EdgeInsets.fromLTRB(26, 24, 26, 18),
          decoration: BoxDecoration(
            color: scheme.surface.withOpacity(0.94),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: scheme.outlineVariant.withOpacity(0.85),
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1F2329).withOpacity(0.08),
                blurRadius: 36,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showBrand) ...[
                const TongYuBrand(size: TongYuBrandSize.large),
                const SizedBox(height: 20),
              ],
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: scheme.primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (badgeLabel != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      badgeLabel!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// 服务器地址收进可折叠区，主表单只保留业务账号字段。
class LoginAdvancedServerField extends StatelessWidget {
  const LoginAdvancedServerField({
    super.key,
    required this.controller,
    required this.enabled,
    required this.expanded,
    required this.onExpansionChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool expanded;
  final ValueChanged<bool> onExpansionChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: ValueKey<bool>(expanded),
        initiallyExpanded: expanded,
        onExpansionChanged: onExpansionChanged,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4, top: 4),
        title: Text(
          '高级设置',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
        ),
        subtitle: Text(
          '服务器地址与部署连接',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.outline,
              ),
        ),
        children: [
          TextFormField(
            controller: controller,
            enabled: enabled,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'chat.example.com 或 http://localhost:8080',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
            validator: (value) =>
                (value ?? '').trim().isEmpty ? '请填写服务器地址' : null,
          ),
        ],
      ),
    );
  }
}

/// 登录表单字段区的轻量分隔，把「连哪里」与「谁来登」分成两段阅读。
class LoginFieldSection extends StatelessWidget {
  const LoginFieldSection({
    super.key,
    required this.label,
    required this.child,
  });

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.outline,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
        ),
        const SizedBox(height: 10),
        child,
      ],
    );
  }
}

/// 登录主按钮：高度固定，忙碌态用进度圈替换文案，避免布局抖动。
class LoginSubmitButton extends StatelessWidget {
  const LoginSubmitButton({
    super.key,
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      child: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );
  }
}
