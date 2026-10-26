import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tongyu_agent_console/src/theme.dart';
import 'package:tongyu_agent_console/src/ui/brand.dart';
import 'package:tongyu_agent_console/src/util/browser_chrome.dart';
import 'package:tongyu_agent_console/src/util/website.dart';

enum LoginHeroKind { agent, platform }

/// 官网、登录和工作台共用品牌；平台入口降为次级入口，身份权限仍由服务端确认。
class LoginShell extends StatelessWidget {
  const LoginShell(
      {super.key,
      required this.icon,
      required this.title,
      required this.subtitle,
      required this.child,
      this.badgeLabel,
      this.heroKind = LoginHeroKind.agent,
      this.onSurfaceSwitch});
  final IconData icon;
  final String title, subtitle;
  final Widget child;
  final String? badgeLabel;
  final LoginHeroKind heroKind;
  final VoidCallback? onSurfaceSwitch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final platform = heroKind == LoginHeroKind.platform;
    return Scaffold(
      // 手机稿是浅渐变底；宽屏右侧表单区仍用冷灰底。
      backgroundColor: const Color(0xFFEEF2FB),
      body: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 960;
        if (!wide) {
          return _MobileLoginBody(
            theme: theme,
            platform: platform,
            title: title,
            subtitle: subtitle,
            onSurfaceSwitch: onSurfaceSwitch,
            child: child,
          );
        }
        return Row(children: [
          Expanded(child: _LoginHeroPanel(kind: heroKind)),
          Expanded(
            child: _DesktopLoginForm(
              theme: theme,
              platform: platform,
              title: title,
              subtitle: subtitle,
              onSurfaceSwitch: onSurfaceSwitch,
              child: child,
            ),
          ),
        ]);
      }),
    );
  }
}

/// 手机 / PWA：真正的原生移动 App 风格。
/// 满屏沉浸式微渐变背景，顶部大气居中品牌 Header，呼吸质感浮层白卡，
/// 底部布局自适应推底（Spacer / bottom pinning），消灭“悬空半截”的半成品网页感。
class _MobileLoginBody extends StatefulWidget {
  const _MobileLoginBody({
    required this.theme,
    required this.platform,
    required this.title,
    required this.subtitle,
    required this.onSurfaceSwitch,
    required this.child,
  });

  final ThemeData theme;
  final bool platform;
  final String title;
  final String subtitle;
  final VoidCallback? onSurfaceSwitch;
  final Widget child;

  @override
  State<_MobileLoginBody> createState() => _MobileLoginBodyState();
}

class _MobileLoginBodyState extends State<_MobileLoginBody>
    with WidgetsBindingObserver {
  final GlobalKey _cardKey = GlobalKey();

  /// 蓝头最上沿。状态栏贴着这块，不能用整页的浅底。
  static const _headerBlue = Color(0xFF2251F5);
  static const _cardWhite = Color(0xFFFFFFFF);
  static const _pageBottom = Color(0xFFEEF2FB);

  Color _top = _headerBlue;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncTop());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final blue = _headerBlue;
    final white = _cardWhite;
    final bottom = _pageBottom;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final current = BrowserChrome.top.value;
      if (current == blue || current == white || current == bottom) {
        BrowserChrome.setTop(null);
      }
    });
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncTop());
  }

  void _syncTop() {
    if (!mounted) return;
    final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    final status = MediaQuery.paddingOf(context).top;
    Color next = _headerBlue;
    if (box != null && box.attached && box.hasSize) {
      final dy = box.localToGlobal(Offset.zero).dy;
      if (dy > status + 1) {
        next = _headerBlue;
      } else if (dy + box.size.height > status + 1) {
        next = _cardWhite;
      } else {
        next = _pageBottom;
      }
    }
    BrowserChrome.setTop(next);
    if (next != _top) setState(() => _top = next);
  }

  SystemUiOverlayStyle _overlay(Color color) {
    final lightIcons = color.computeLuminance() < 0.45;
    return SystemUiOverlayStyle(
      statusBarColor: color,
      statusBarIconBrightness: lightIcons ? Brightness.light : Brightness.dark,
      statusBarBrightness: lightIcons ? Brightness.dark : Brightness.light,
      systemStatusBarContrastEnforced: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final platform = widget.platform;
    final title = widget.title;
    final subtitle = widget.subtitle;
    final onSurfaceSwitch = widget.onSurfaceSwitch;
    final child = widget.child;
    final scheme = theme.colorScheme;
    final inset = MediaQuery.viewInsetsOf(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _overlay(_top),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFEBF1FF),
              Color(0xFFF3F6FD),
              Color(0xFFF8FAFC),
            ],
          ),
        ),
        child: Stack(
          children: [
            // 移动原生顶部大弧光晕背景
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 290,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF2251F5),
                      Color(0xFF386CFB),
                      Color(0xFF5B8EFF),
                    ],
                  ),
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(40),
                    bottomRight: Radius.circular(40),
                  ),
                ),
              ),
            ),
            // 柔和光晕装饰泡泡
            Positioned(
              top: -60,
              right: -40,
              child: IgnorePointer(
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.09),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 80,
              left: -50,
              child: IgnorePointer(
                child: Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.06),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      _syncTop();
                      return false;
                    },
                    child: SingleChildScrollView(
                      padding:
                          EdgeInsets.fromLTRB(20, 16, 20, 16 + inset.bottom),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight - 32 - inset.bottom,
                        ),
                        child: IntrinsicHeight(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // 顶部居中原生 App 品牌 Header
                              Padding(
                                padding:
                                    const EdgeInsets.only(top: 12, bottom: 20),
                                child: Column(
                                  children: [
                                    Container(
                                      width: 56,
                                      height: 56,
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(18),
                                        boxShadow: [
                                          BoxShadow(
                                            color: const Color(0xFF102A83)
                                                .withOpacity(0.25),
                                            blurRadius: 18,
                                            offset: const Offset(0, 8),
                                          ),
                                        ],
                                      ),
                                      child: const Center(
                                        child: TongYuLogoMark(size: 38),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        const Text(
                                          '通语',
                                          style: TextStyle(
                                            fontSize: 22,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 1.0,
                                            color: Colors.white,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          platform ? '管理后台' : '客服工作台',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.6,
                                            color:
                                                Colors.white.withOpacity(0.95),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      platform
                                          ? '平台专属管理后台 · 服务治理与系统配置'
                                          : '新一代企业在线智能客服系统',
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: Colors.white.withOpacity(0.85),
                                        letterSpacing: 0.2,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // 原生移动端主表单卡片
                              Container(
                                key: _cardKey,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(24),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF1B3B9E)
                                          .withOpacity(0.08),
                                      blurRadius: 28,
                                      offset: const Offset(0, 12),
                                    ),
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.03),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 22, vertical: 24),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          title,
                                          style: TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.w800,
                                            color: scheme.onSurface,
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 9, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFEFF4FF),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            platform ? '平台管理员登录' : '客服工作台登录',
                                            style: const TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF2855F6),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      subtitle,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                    Theme(
                                      data: theme.copyWith(
                                        inputDecorationTheme:
                                            theme.inputDecorationTheme.copyWith(
                                          filled: true,
                                          fillColor: const Color(0xFFF7F9FC),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 16, vertical: 15),
                                          border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              borderSide: BorderSide.none),
                                          enabledBorder: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              borderSide: const BorderSide(
                                                  color: Color(0xFFE9EEF5))),
                                          focusedBorder: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              borderSide: const BorderSide(
                                                  color: Color(0xFF3263FF),
                                                  width: 1.8)),
                                        ),
                                      ),
                                      child: AutofillGroup(child: child),
                                    ),
                                    const SizedBox(height: 12),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: TextButton.icon(
                                        onPressed: () =>
                                            _showLoginHelp(context, platform),
                                        icon: const Icon(Icons.help_outline,
                                            size: 16),
                                        label: const Text('需要登录帮助？'),
                                        style: TextButton.styleFrom(
                                          foregroundColor:
                                              scheme.onSurfaceVariant,
                                          padding: EdgeInsets.zero,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // 弹性撑开区域：将底部版权与切换键推到屏幕最底部，消灭“悬空半截”
                              const Spacer(),
                              const SizedBox(height: 24),
                              // 底部功能切换栏与原生品牌标语
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.65),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: const Color(0xFFE2E8F4)
                                        .withOpacity(0.7),
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '通语企业服务',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: onSurfaceSwitch,
                                      icon: Icon(
                                        platform
                                            ? Icons.support_agent_rounded
                                            : Icons
                                                .admin_panel_settings_outlined,
                                        size: 16,
                                      ),
                                      label: Text(
                                        platform ? '客服工作台登录' : '平台管理员登录',
                                        style: const TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 4),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 14),
                              Center(
                                child: Text(
                                  '通语 TongYu · 原生级企业在线客服',
                                  style: TextStyle(
                                    fontSize: 11,
                                    letterSpacing: 0.3,
                                    color: scheme.onSurfaceVariant
                                        .withOpacity(0.65),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 宽屏右侧表单：保留卡片与完整桌面说明。
class _DesktopLoginForm extends StatelessWidget {
  const _DesktopLoginForm({
    required this.theme,
    required this.platform,
    required this.title,
    required this.subtitle,
    required this.onSurfaceSwitch,
    required this.child,
  });

  final ThemeData theme;
  final bool platform;
  final String title;
  final String subtitle;
  final VoidCallback? onSurfaceSwitch;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Stack(
      children: [
        Positioned(
          top: -60,
          right: 40,
          child: IgnorePointer(
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(120),
                gradient: const LinearGradient(
                  colors: [Color(0x55845EF7), Color(0x333263FF)],
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.92),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xE6E7EDF6)),
                    boxShadow: RelayTheme.softShadow(Brightness.light),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (canReturnToWebsite) ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: openWebsite,
                            icon: const Icon(Icons.arrow_back, size: 16),
                            label: const Text('返回通语官网'),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            platform ? '平台管理员登录' : '客服工作台登录',
                            style:
                                TextStyle(fontSize: 12, color: scheme.primary),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 28,
                          height: 1.4,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.8,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 28),
                      Theme(
                        data: theme.copyWith(
                          inputDecorationTheme:
                              theme.inputDecorationTheme.copyWith(
                            filled: true,
                            fillColor: const Color(0xFFF5F7FB),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 14),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide:
                                    const BorderSide(color: Color(0xFFE7EDF6))),
                            enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide:
                                    const BorderSide(color: Color(0xFFE7EDF6))),
                            focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(
                                    color: Color(0xFF3263FF), width: 1.5)),
                          ),
                        ),
                        child: AutofillGroup(child: child),
                      ),
                      const SizedBox(height: 16),
                      TextButton.icon(
                        onPressed: () => _showLoginHelp(context, platform),
                        icon: const Icon(Icons.help_outline, size: 16),
                        label: const Text('需要登录帮助？'),
                        style: TextButton.styleFrom(
                            foregroundColor: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 22),
                      const Divider(),
                      if (canOpenWebsite && canReturnToWebsite)
                        TextButton.icon(
                          onPressed: openDownloads,
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('安卓客户端下载 / iPhone 添加到桌面'),
                        ),
                      const SizedBox(height: 12),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          Text(
                            '通语企业服务',
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                          TextButton(
                            onPressed: onSurfaceSwitch,
                            child: Text(
                              platform ? '客服工作台登录' : '平台管理员登录',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

void _showLoginHelp(BuildContext context, bool platform) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('登录帮助'),
      content: Text(platform
          ? '此入口仅供平台管理员使用。企业客服请切换到客服工作台登录。忘记密码时，请联系平台负责人。'
          : '企业标识由企业管理员提供。请使用管理员为你创建的用户名和密码登录。忘记密码或无法进入工作台时，请联系企业管理员。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

class _LoginHeroPanel extends StatelessWidget {
  const _LoginHeroPanel({required this.kind});
  final LoginHeroKind kind;
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: RelayTheme.loginHeroGradient),
      child: Stack(
        children: [
          Positioned(
            top: -80,
            right: -60,
            child: IgnorePointer(
              child: Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withOpacity(0.12),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -40,
            left: -30,
            child: IgnorePointer(
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(80),
                  color: const Color(0xFF12B886).withOpacity(0.20),
                ),
              ),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 56),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight:
                      (constraints.maxHeight - 112).clamp(0, double.infinity),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.18),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              )
                            ],
                          ),
                          child: const Icon(Icons.forum_rounded,
                              color: Color(0xFF3263FF), size: 22),
                        ),
                        const SizedBox(width: 12),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '通语',
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                letterSpacing: 1,
                              ),
                            ),
                            Text(
                              '企业客服工作台',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFFD7E2FF),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.bolt,
                                    size: 14, color: Color(0xFF7EA8FF)),
                                SizedBox(width: 6),
                                Text(
                                  '下一代智能企业客服生态系统',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Color(0xEEFFFFFF),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            '让每一次咨询，\n都有回应。',
                            style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              height: 1.4,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            '连接网站与 H5 咨询、团队协作接待与知识辅助，在同一个工作台完成服务。',
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.85,
                              color: Color(0xFFDCE6FF),
                            ),
                          ),
                          const SizedBox(height: 28),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final label in const [
                                '网站嵌入',
                                'H5 入口',
                                '协作接待',
                                '知识辅助',
                              ])
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.14),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                        color: Colors.white.withOpacity(0.20)),
                                  ),
                                  child: Text(
                                    label,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Text(
                      '© 2026 通语 TongYu. 保留所有权利。',
                      style: TextStyle(fontSize: 11, color: Color(0x66FFFFFF)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
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
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          key: ValueKey<bool>(expanded),
          initiallyExpanded: expanded,
          maintainState: true,
          enabled: enabled,
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
            '连接地址（通常无需修改）',
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
    return child;
  }
}

/// 登录按钮文字必须自带中文字体。按钮 textStyle 会换掉主题字体，缺了它「登录」在网页上不显示。
TextStyle _loginButtonText(bool narrow) => TextStyle(
      fontFamily: 'SportsChinese',
      fontFamilyFallback: const <String>['ChatEmoji'],
      color: Colors.white,
      fontSize: narrow ? 16 : 15,
      fontWeight: FontWeight.w600,
      letterSpacing: narrow ? 1.5 : 0.5,
    );

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
    final narrow = MediaQuery.sizeOf(context).width < 560;
    final radius = narrow ? 16.0 : 14.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RelayTheme.actionGradient,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: narrow
            ? [
                BoxShadow(
                  color: const Color(0xFF3263FF).withOpacity(0.35),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ]
            : RelayTheme.popShadow(),
      ),
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: Colors.white,
          elevation: 0,
          minimumSize: Size.fromHeight(narrow ? 48 : 46),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius)),
          textStyle: TextStyle(
            // 与主题按钮相同：这里再写一遍，避免本按钮的 textStyle 把中文字体覆盖掉。
            fontFamily: 'SportsChinese',
            fontFamilyFallback: const <String>['ChatEmoji'],
            color: Colors.white,
            fontSize: narrow ? 16 : 15,
            fontWeight: FontWeight.w600,
            letterSpacing: narrow ? 1.5 : 0.5,
          ),
        ),
        child: busy
            ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.2, color: Colors.white)),
                const SizedBox(width: 10),
                Text('正在登录…', style: _loginButtonText(narrow)),
              ])
            : Text(label, style: _loginButtonText(narrow)),
      ),
    );
  }
}
