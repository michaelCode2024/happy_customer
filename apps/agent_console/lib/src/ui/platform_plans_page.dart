import 'package:flutter/material.dart';
import 'package:relaydesk_agent_console/src/platform/platform_controller.dart';
import 'package:relaydesk_agent_console/src/ui/product_brand.dart';
import 'package:relaydesk_agent_console/src/ui/workspace_layout.dart';

/// 套餐对比与营销卖点，对齐现有 TRIAL / STARTER / GROWTH / ENTERPRISE。
///
/// 年费与对外报价一致；企业开通和服务期限仍由平台管理员确认。
class PlatformPlansPage extends StatelessWidget {
  const PlatformPlansPage({super.key, required this.controller});

  final PlatformController controller;

  static const _plans = <_PlanOffer>[
    _PlanOffer(
      code: 'TRIAL',
      name: '体验版',
      badge: '免费试用',
      price: '¥0',
      period: '14 天',
      seats: '2 坐席',
      messages: '1,000 条/月',
      history: '历史消息持续保留',
      highlight: false,
      features: [
        '网页客服组件',
        '实时文字 / 图片 / 文件',
        '会话分配与待接待队列',
        '基础数据统计',
        '知识库检索',
        // 与其它档位条数对齐，避免功能区高低差过大。
        '适合接入验证与内部试用',
      ],
    ),
    _PlanOffer(
      code: 'STARTER',
      name: '专业版',
      badge: '中小团队',
      price: '¥2,000',
      period: '/年',
      seats: '1 坐席',
      messages: '5,000 条/月',
      history: '历史消息持续保留',
      highlight: false,
      features: [
        '体验版全部能力',
        '群聊与音视频通话',
        '多客服入口',
        '快捷回复与标签',
        '应用接入（脚本 / iframe）',
        'Webhook 回调',
      ],
    ),
    _PlanOffer(
      code: 'GROWTH',
      name: '旗舰版',
      badge: '推荐',
      price: '¥3,000',
      period: '/年',
      seats: '3 坐席',
      messages: '50,000 条/月',
      history: '历史消息持续保留',
      highlight: true,
      features: [
        '专业版全部能力',
        '已读 / 送达回执（各版本均支持）',
        'AI 辅助回复与转人工',
        '自动回复与渠道管理',
        '语音消息与内部备注（各版本均支持）',
        '知识检索与协作处理',
      ],
    ),
    _PlanOffer(
      code: 'ENTERPRISE',
      name: '企业版',
      badge: '顶配',
      price: '¥5,000',
      period: '/年',
      seats: '10 坐席',
      messages: '1,000,000 条/月',
      history: '历史消息持续保留',
      highlight: false,
      features: [
        '旗舰版全部能力',
        '独立企业空间与权限',
        '服务端身份票据接入',
        '专属对接支持',
        '按企业独立统计用量',
        '企业账号与权限管理',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
      children: [
        const WorkspaceHeading(
          '套餐方案',
          '套餐与企业工作台菜单联动，调整后 5 秒内更新；菜单同时受账号角色限制。',
        ),
        Text(
          '${ProductBrand.nameZh} 让接待、协作与接入在同一套工作台完成。',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        const Text('人民币计价，付费套餐按年订阅，服务周期12个月。消息和AI用量按月统计。'),
        const Card(
            child: Padding(
          padding: EdgeInsets.all(18),
          child: Text(
              '菜单开放范围\n体验版：工作概览、收件箱、数据统计、知识库、个人设置、企业管理\n专业版：增加群聊、应用接入\n旗舰版 / 企业版：增加自动回复、渠道管理与 AI 辅助\n企业管理及应用接入仅面向管理员，数据统计仍按角色授权。'),
        )),
        const SizedBox(height: 20),
        _PromoStrip(
          onOpenTenant: () => controller.selectSection(PlatformSection.tenants),
        ),
        const SizedBox(height: 28),
        // 宽屏用等高 Row，保证四张卡底边、价格、按钮同一基线；窄屏再换行。
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 1100) {
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < _plans.length; i++) ...[
                      if (i > 0) const SizedBox(width: 16),
                      Expanded(
                        child: _PlanCard(
                          plan: _plans[i],
                          onChoose: () =>
                              controller.beginPlanAssignment(_plans[i].code),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }
            if (constraints.maxWidth >= 720) {
              return Column(
                children: [
                  for (var row = 0; row < 2; row++) ...[
                    if (row > 0) const SizedBox(height: 16),
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var col = 0; col < 2; col++) ...[
                            if (col > 0) const SizedBox(width: 16),
                            Expanded(
                              child: _PlanCard(
                                plan: _plans[row * 2 + col],
                                onChoose: () => controller.beginPlanAssignment(
                                    _plans[row * 2 + col].code),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              );
            }
            return Column(
              children: [
                for (var i = 0; i < _plans.length; i++) ...[
                  if (i > 0) const SizedBox(height: 16),
                  _PlanCard(
                      plan: _plans[i],
                      onChoose: () =>
                          controller.beginPlanAssignment(_plans[i].code)),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 28),
        Text(
          '能力对比说明',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '送达和已读回执为基础消息能力。AI辅助、自动回复和身份接入按套餐配置开放；体验版免费14天。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _PromoStrip extends StatelessWidget {
  const _PromoStrip({required this.onOpenTenant});

  final VoidCallback onOpenTenant;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 卖点三列等高；「去开通企业」只放一条，避免和下方四套餐卡错位成「每列一个链接」。
    final items = const [
      ('即时接待', '网页组件分钟级接入，访客消息实时进收件箱。'),
      ('团队协作', '分配、转派、内部备注与知识库，同一会话闭环。'),
      ('AI 增效', '辅助起草回复、知识检索与自动转人工。'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 760;
              final cells = <Widget>[
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0)
                    stacked
                        ? Divider(height: 1, color: scheme.outlineVariant)
                        : VerticalDivider(
                            width: 1, color: scheme.outlineVariant),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            items[i].$1,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            items[i].$2,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ];
              return stacked
                  ? Column(children: cells)
                  : IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: cells,
                      ),
                    );
            },
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onOpenTenant,
                child: const Text('去开通企业 →'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanOffer {
  const _PlanOffer({
    required this.code,
    required this.name,
    required this.badge,
    required this.price,
    required this.period,
    required this.seats,
    required this.messages,
    required this.history,
    required this.features,
    required this.highlight,
  });

  final String code;
  final String name;
  final String badge;
  final String price;
  final String period;
  final String seats;
  final String messages;
  final String history;
  final List<String> features;
  final bool highlight;
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.onChoose});

  final _PlanOffer plan;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 边框宽度统一，高亮只改颜色/阴影，避免推荐卡比邻卡「鼓」出一圈。
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: plan.highlight
              ? scheme.primary.withOpacity(0.55)
              : scheme.outlineVariant,
          width: 1.5,
        ),
        boxShadow: [
          if (plan.highlight)
            BoxShadow(
              color: scheme.primary.withOpacity(0.08),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 28,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    plan.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: plan.highlight
                        ? scheme.primary
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    plan.badge,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: plan.highlight
                          ? scheme.onPrimary
                          : scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(plan.seats, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(plan.messages, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            plan.history,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          for (final feature in plan.features)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_circle, size: 16, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(feature, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
          // 把价格区顶到卡片底部，四张卡价格/按钮对齐。
          const Spacer(),
          const SizedBox(height: 8),
          SizedBox(
            height: 36,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  plan.price,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: const Color(0xFFE11D48),
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    plan.period,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: onChoose,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(40),
              backgroundColor:
                  plan.highlight ? scheme.primary : scheme.primaryContainer,
              foregroundColor:
                  plan.highlight ? scheme.onPrimary : scheme.onPrimaryContainer,
            ),
            child: const Text('分配给企业'),
          ),
        ],
      ),
    );
  }
}
