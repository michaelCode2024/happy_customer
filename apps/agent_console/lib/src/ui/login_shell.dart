import 'package:flutter/material.dart';
import 'package:relaydesk_agent_console/src/ui/brand.dart';
import 'package:relaydesk_agent_console/src/ui/product_brand.dart';

enum LoginHeroKind { agent, platform }

/// 与工作台共享色彩；手机隐藏展示区，为表单和软键盘留出空间。
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
  final String title;
  final String subtitle;
  final Widget child;
  final String? badgeLabel;
  final LoginHeroKind heroKind;
  final VoidCallback? onSurfaceSwitch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: dark ? scheme.surface : const Color(0xFFF8FAFC),
      body: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 960;
        // 入口锚点只随视口变化，不随两套表单的字段数量变化。
        final verticalPadding = wide
            ? ((constraints.maxHeight - 580) / 2).clamp(40.0, 140.0)
            : 24.0;
        return Row(children: [
          if (wide) Expanded(child: _LoginHeroPanel(kind: heroKind)),
          Expanded(
              child: SafeArea(
                  child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
                horizontal: wide ? 48 : 24,
                vertical: verticalPadding),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - verticalPadding * 2)
                      .clamp(0, double.infinity)),
              child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!wide) ...[
                            const TongYuBrand(showEnglish: true),
                            const SizedBox(height: 28),
                          ],
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                                color: dark
                                    ? scheme.surfaceContainerHighest
                                    : const Color(0xFFEDF0F5),
                                borderRadius: BorderRadius.circular(10)),
                            child: Row(children: [
                              for (final item in const [
                                (LoginHeroKind.agent, '客服工作台登录'),
                                (LoginHeroKind.platform, '平台管理员登录')
                              ])
                                Expanded(
                                    child: Semantics(
                                        button: true,
                                        selected: item.$1 == heroKind,
                                        child: InkWell(
                                            borderRadius:
                                                BorderRadius.circular(7),
                                            onTap: item.$1 == heroKind
                                                ? null
                                                : onSurfaceSwitch,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      vertical: 12),
                                              decoration: BoxDecoration(
                                                  color: item.$1 == heroKind
                                                      ? scheme.surface
                                                      : Colors.transparent,
                                                  borderRadius:
                                                      BorderRadius.circular(7)),
                                              child: Text(item.$2,
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight:
                                                          item.$1 == heroKind
                                                              ? FontWeight.w600
                                                              : FontWeight.w400,
                                                      color: item.$1 == heroKind
                                                          ? scheme.primary
                                                          : scheme
                                                              .onSurfaceVariant)),
                                            )))),
                            ]),
                          ),
                          const SizedBox(height: 28),
                          Text(title,
                              style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSurface,
                                  letterSpacing: -0.5)),
                          const SizedBox(height: 8),
                          Text(subtitle,
                              style: TextStyle(
                                  fontSize: 13,
                                  height: 1.6,
                                  color: scheme.onSurfaceVariant)),
                          const SizedBox(height: 28),
                          Theme(
                              data: theme.copyWith(
                                  inputDecorationTheme: InputDecorationTheme(
                                filled: true,
                                fillColor: scheme.surface,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 18),
                                prefixIconColor: scheme.onSurfaceVariant,
                                suffixIconColor: scheme.onSurfaceVariant,
                                labelStyle: TextStyle(
                                    fontSize: 13,
                                    color: scheme.onSurfaceVariant),
                                hintStyle: TextStyle(
                                    fontSize: 13, color: scheme.outline),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(9),
                                    borderSide: BorderSide(
                                        color: scheme.outlineVariant)),
                                enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(9),
                                    borderSide: BorderSide(
                                        color: scheme.outlineVariant)),
                                focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(9),
                                    borderSide: BorderSide(
                                        color: scheme.primary, width: 1.5)),
                              )),
                              child: AutofillGroup(child: child)),
                          const SizedBox(height: 18),
                          TextButton.icon(
                            onPressed: () => showDialog<void>(
                                context: context,
                                builder: (context) => AlertDialog(
                                      title: const Text('登录帮助'),
                                      content: Text(heroKind ==
                                              LoginHeroKind.agent
                                          ? '企业标识由企业管理员提供。请使用管理员为你创建的用户名和密码登录。忘记密码或无法进入工作台时，请联系企业管理员。'
                                          : '此入口仅供平台管理员使用。企业客服请切换到客服工作台登录。忘记密码时，请联系平台负责人。'),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context),
                                            child: const Text('知道了'))
                                      ],
                                    )),
                            icon: const Icon(Icons.help_outline, size: 16),
                            label: const Text('需要登录帮助？',
                                style: TextStyle(fontSize: 12)),
                            style: TextButton.styleFrom(
                                foregroundColor: scheme.onSurfaceVariant),
                          ),
                        ]),
                  )),
            ),
          ))),
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
    final platform = kind == LoginHeroKind.platform;
    return Container(
      color: const Color(0xFF182334),
      child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.all(48),
                child: ConstrainedBox(
                    constraints: BoxConstraints(
                        minHeight: (constraints.maxHeight - 96)
                            .clamp(0, double.infinity)),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(children: [
                            TongYuLogoMark(size: 38),
                            SizedBox(width: 12),
                            Text(ProductBrand.nameZh,
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 24,
                                    fontWeight: FontWeight.w700)),
                            SizedBox(width: 10),
                            Text(ProductBrand.nameEn,
                                style: TextStyle(
                                    color: Color(0xFF95A3B8), fontSize: 13))
                          ]),
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 40),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        platform
                                            ? '从容管理，\n让服务有序运转。'
                                            : '让每一次对话，\n都有回应。',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 38,
                                            height: 1.4,
                                            fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 18),
                                    Text(
                                        platform
                                            ? '企业、团队与服务，在这里统一管理。'
                                            : '连接客户与团队，让沟通更简单、更专注。',
                                        style: const TextStyle(
                                            color: Color(0xFF9CAAC0),
                                            fontSize: 14,
                                            height: 1.8)),
                                    const SizedBox(height: 40),
                                    Container(
                                        padding: const EdgeInsets.all(22),
                                        decoration: BoxDecoration(
                                            color: const Color(0xFF223148),
                                            borderRadius:
                                                BorderRadius.circular(16),
                                            border: Border.all(
                                                color:
                                                    const Color(0xFF324158))),
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              Row(children: [
                                                Icon(
                                                    platform
                                                        ? Icons
                                                            .dashboard_outlined
                                                        : Icons.forum_outlined,
                                                    size: 18,
                                                    color: const Color(
                                                        0xFF9AABFF)),
                                                const SizedBox(width: 10),
                                                Text(platform ? '平台运营' : '客户会话',
                                                    style: const TextStyle(
                                                        color:
                                                            Color(0xFFD9E1ED),
                                                        fontSize: 13)),
                                                const Spacer(),
                                                const Icon(Icons.more_horiz,
                                                    color: Color(0xFF8292AA))
                                              ]),
                                              const SizedBox(height: 22),
                                              if (platform) ...[
                                                for (final label in [
                                                  '企业管理',
                                                  '团队与权限',
                                                  '服务配置'
                                                ])
                                                  Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                              bottom: 12),
                                                      child: Row(children: [
                                                        const Icon(
                                                            Icons
                                                                .check_circle_outline,
                                                            color: Color(
                                                                0xFF859BFC),
                                                            size: 18),
                                                        const SizedBox(
                                                            width: 12),
                                                        Text(label,
                                                            style: const TextStyle(
                                                                color: Color(
                                                                    0xFFCCD6E5),
                                                                fontSize: 13))
                                                      ])),
                                              ] else ...[
                                                Align(
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    child: _bubble(
                                                        '你好，我想咨询一下。', false)),
                                                const SizedBox(height: 14),
                                                Align(
                                                    alignment:
                                                        Alignment.centerRight,
                                                    child: _bubble(
                                                        '你好，很高兴为你服务。', true)),
                                                const SizedBox(height: 20),
                                                const Row(children: [
                                                  Icon(
                                                      Icons
                                                          .auto_awesome_outlined,
                                                      size: 15,
                                                      color: Color(0xFF9AABFF)),
                                                  SizedBox(width: 8),
                                                  Text('专注沟通 · 协作接待 · 智能辅助',
                                                      style: TextStyle(
                                                          color:
                                                              Color(0xFF95A3B8),
                                                          fontSize: 11))
                                                ]),
                                              ],
                                            ])),
                                  ])),
                          const Text(ProductBrand.tagline,
                              style: TextStyle(
                                  color: Color(0xFF8292AA), fontSize: 12)),
                        ])),
              )),
    );
  }

  Widget _bubble(String text, bool reply) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
            color: reply ? const Color(0xFF4263EB) : const Color(0xFF31435D),
            borderRadius: BorderRadius.circular(10)),
        child: Text(text,
            style: const TextStyle(color: Colors.white, fontSize: 12)),
      );
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
    return FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      child: busy
          ? const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 10),
              Text('正在登录…'),
            ])
          : Text(label),
    );
  }
}
