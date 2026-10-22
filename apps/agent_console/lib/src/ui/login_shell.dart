import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/theme.dart';
import 'package:tongyu_agent_console/src/ui/brand.dart';
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
    final scheme = theme.colorScheme;
    // 登录页连同安全区域共用 MaterialApp 同步给浏览器的表面色。
    final pageBackground = const Color(0xFFEEF2FB);
    final platform = heroKind == LoginHeroKind.platform;
    return Scaffold(
      backgroundColor: pageBackground,
      body: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 960;
        final padding = wide ? 48.0 : 24.0;
        return Row(children: [
          if (wide) Expanded(child: _LoginHeroPanel(kind: heroKind)),
          Expanded(
              child: Stack(children: [
                Positioned(
                  top: -60,
                  right: constraints.maxWidth * 0.08,
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
                Positioned(
                  bottom: constraints.maxHeight * 0.08,
                  right: constraints.maxWidth * 0.18,
                  child: IgnorePointer(
                    child: Container(
                      width: 180,
                      height: 180,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [Color(0x4412B886), Color(0x335B8CFF)],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: constraints.maxHeight * 0.22,
                  right: constraints.maxWidth * 0.28,
                  child: IgnorePointer(
                    child: Transform.rotate(
                      angle: 0.32,
                      child: Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          gradient: const LinearGradient(
                            colors: [Color(0x66FFD43B), Color(0x44F59F00)],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: padding, vertical: 36),
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
                    // 移除登录页 PWA 离线提示
                    // const PwaPanel(hideUpdateBanner: true),
                    const SizedBox(height: 12),
                    if (canReturnToWebsite) ...[
                      Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                              onPressed: openWebsite,
                              icon: const Icon(Icons.arrow_back, size: 16),
                              label: const Text('返回通语官网'))),
                      const SizedBox(height: 24),
                    ],
                    if (!wide) ...[
                      const TongYuBrand(showEnglish: true),
                      const SizedBox(height: 18),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                        decoration: BoxDecoration(
                          gradient: RelayTheme.loginHeroGradient,
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF3263FF).withOpacity(0.28),
                              blurRadius: 28,
                              offset: const Offset(0, 12),
                            ),
                          ],
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'MOBILE AGENT',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xD9FFFFFF),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              '随时接起咨询',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              '网站嵌入与 H5 入口的消息，统一在手机工作台处理。',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.6,
                                color: Color(0xE6FFFFFF),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                                color: scheme.primaryContainer,
                                borderRadius: BorderRadius.circular(6)),
                            child: Text(platform ? '平台管理员登录' : '客服工作台登录',
                                style: TextStyle(
                                    fontSize: 12, color: scheme.primary)))),
                    const SizedBox(height: 24),
                    Text(title,
                        style: TextStyle(
                            fontSize: 28,
                            height: 1.4,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface)),
                    const SizedBox(height: 10),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 13,
                            height: 1.8,
                            color: scheme.onSurfaceVariant)),
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
                        )),
                        child: AutofillGroup(child: child)),
                    const SizedBox(height: 16),
                    TextButton.icon(
                        onPressed: () => showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                                    title: const Text('登录帮助'),
                                    content: Text(platform
                                        ? '此入口仅供平台管理员使用。企业客服请切换到客服工作台登录。忘记密码时，请联系平台负责人。'
                                        : '企业标识由企业管理员提供。请使用管理员为你创建的用户名和密码登录。忘记密码或无法进入工作台时，请联系企业管理员。'),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context),
                                          child: const Text('知道了'))
                                    ])),
                        icon: const Icon(Icons.help_outline, size: 16),
                        label: const Text('需要登录帮助？'),
                        style: TextButton.styleFrom(
                            foregroundColor: scheme.onSurfaceVariant)),
                    const SizedBox(height: 22),
                    const Divider(),
                    if (canOpenWebsite && canReturnToWebsite)
                      TextButton.icon(
                          onPressed: openDownloads,
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('安卓客户端下载 / iPhone 添加到桌面')),
                    const SizedBox(height: 12),
                    Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          Text('通语企业服务',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                          TextButton(
                              onPressed: onSurfaceSwitch,
                              child: Text(platform ? '客服工作台登录' : '平台管理员登录',
                                  style: const TextStyle(fontSize: 12))),
                        ]),
                  ]),
              ),
            )),
          )),
              ]),
            ),
        ]);
      }),
    );
  }
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
              minHeight: (constraints.maxHeight - 112).clamp(0, double.infinity),
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
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.bolt, size: 14, color: Color(0xFF7EA8FF)),
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
    final radius = narrow ? 40.0 : 14.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RelayTheme.actionGradient,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: RelayTheme.popShadow(),
      ),
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: Colors.white,
          elevation: 0,
          minimumSize: Size.fromHeight(narrow ? 44 : 46),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        child: busy
            ? const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white)),
                SizedBox(width: 10),
                Text('正在登录…'),
              ])
            : Text(label),
      ),
    );
  }
}
