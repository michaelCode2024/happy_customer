import 'package:flutter/material.dart';
import 'package:relaydesk_agent_console/src/ui/brand.dart';
import 'package:relaydesk_agent_console/src/ui/product_brand.dart';
import 'package:relaydesk_agent_console/src/util/website.dart';

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
    final platform = heroKind == LoginHeroKind.platform;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 960;
        final padding = wide ? 48.0 : 24.0;
        return Row(children: [
          if (wide) Expanded(child: _LoginHeroPanel(kind: heroKind)),
          Expanded(
              child: SafeArea(
                  child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: padding, vertical: 36),
            child: Center(
                child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (canOpenWebsite) ...[
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
                      const SizedBox(height: 28)
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
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 18),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide:
                                  BorderSide(color: scheme.outlineVariant)),
                          enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide:
                                  BorderSide(color: scheme.outlineVariant)),
                          focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                  color: scheme.primary, width: 1.5)),
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
            )),
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
    final scheme = Theme.of(context).colorScheme;
    final platform = kind == LoginHeroKind.platform;
    return Container(
      color: scheme.brightness == Brightness.dark
          ? scheme.surfaceContainerHighest
          : const Color(0xFFF8FAFF),
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
                          const TongYuBrand(showEnglish: true),
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 44),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('让每一次沟通，都有回应',
                                        style: TextStyle(
                                            fontSize: 12,
                                            letterSpacing: 2,
                                            color: scheme.primary)),
                                    const SizedBox(height: 20),
                                    Text(
                                        platform
                                            ? '企业、团队与服务，\n在这里统一管理。'
                                            : '客户服务，从容有序。\n团队协作，尽在通语。',
                                        style: const TextStyle(
                                            fontSize: 28,
                                            fontWeight: FontWeight.w700,
                                            height: 1.6)),
                                    const SizedBox(height: 18),
                                    Text(
                                        platform
                                            ? ProductBrand.platformSubtitle
                                            : '把客户会话、团队协作和知识辅助汇聚到一个工作台，让每一位客服专注于解决问题。',
                                        style: TextStyle(
                                            fontSize: 14,
                                            height: 1.9,
                                            color: scheme.onSurfaceVariant)),
                                    const SizedBox(height: 32),
                                    Container(
                                        padding: const EdgeInsets.all(22),
                                        decoration: BoxDecoration(
                                            color: scheme.surface,
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            border: Border.all(
                                                color: scheme.outlineVariant)),
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
                                                    color: scheme.primary),
                                                const SizedBox(width: 10),
                                                Text(platform ? '平台运营' : '客户会话',
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w600)),
                                                const Spacer(),
                                                Text('产品示意',
                                                    style: TextStyle(
                                                        fontSize: 11,
                                                        color: scheme
                                                            .onSurfaceVariant))
                                              ]),
                                              const SizedBox(height: 20),
                                              const Divider(),
                                              const SizedBox(height: 16),
                                              if (platform) ...[
                                                for (final label in [
                                                  '企业管理',
                                                  '团队与权限',
                                                  '服务配置'
                                                ])
                                                  Padding(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          vertical: 8),
                                                      child: Row(children: [
                                                        Icon(
                                                            Icons
                                                                .check_circle_outline,
                                                            color:
                                                                scheme.primary,
                                                            size: 18),
                                                        const SizedBox(
                                                            width: 12),
                                                        Text(label)
                                                      ])),
                                              ] else ...[
                                                Align(
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    child: _bubble(
                                                        context,
                                                        '你好，想了解一下网站客服怎么接入？',
                                                        false)),
                                                const SizedBox(height: 16),
                                                Align(
                                                    alignment:
                                                        Alignment.centerRight,
                                                    child: _bubble(
                                                        context,
                                                        '您好，可以使用网站嵌入代码或 H5 客服链接。',
                                                        true)),
                                                const SizedBox(height: 20),
                                                Text('统一接待 · 团队协作 · AI 知识辅助',
                                                    style: TextStyle(
                                                        fontSize: 12,
                                                        color: scheme
                                                            .onSurfaceVariant)),
                                              ],
                                            ])),
                                  ])),
                          Text(ProductBrand.tagline,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                        ])),
              )),
    );
  }

  Widget _bubble(BuildContext context, String text, bool reply) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
        constraints: const BoxConstraints(maxWidth: 310),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
            color: reply
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(9)),
        child: Text(text, style: const TextStyle(fontSize: 12, height: 1.8)));
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
