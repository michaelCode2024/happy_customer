import 'package:flutter/material.dart';

/// 网页与客户端共用选择界面，提醒播放和存储仍由各端处理。
class MessageSoundCard extends StatelessWidget {
  const MessageSoundCard(
      {super.key,
      required this.enabled,
      required this.choice,
      required this.onEnabled,
      required this.onChoice,
      required this.onTest,
      this.status});
  final bool enabled;
  final String choice;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<String> onChoice;
  final VoidCallback onTest;
  final String? status;

  static const options = [
    ('sender', '播报发送者', '张先生给你发来了新消息', Icons.record_voice_over_outlined),
    ('tone', '经典提示音', '简短铃声，轻量提醒', Icons.music_note_outlined),
    ('message', '新消息播报', '你有新的消息来了', Icons.chat_bubble_outline),
    ('customer', '客户消息播报', '有客户消息，请及时查看', Icons.support_agent_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.outlineVariant)),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: colors.primary.withOpacity(.09),
                      borderRadius: BorderRadius.circular(12)),
                  child: Icon(Icons.notifications_active_outlined,
                      color: colors.primary)),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('消息声音',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(enabled ? '已开启 · 收到新消息时播放' : '已关闭 · 开启后可选择提醒方式',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant)),
                  ])),
              Switch(value: enabled, onChanged: onEnabled),
            ]),
            const SizedBox(height: 20),
            Text('提醒方式', style: theme.textTheme.labelLarge),
            const SizedBox(height: 10),
            LayoutBuilder(builder: (context, constraints) {
              final width = constraints.maxWidth >= 560
                  ? (constraints.maxWidth - 12) / 2
                  : constraints.maxWidth;
              return Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: options.map((option) {
                    final selected = option.$1 == choice;
                    return SizedBox(
                        width: width,
                        child: Opacity(
                          opacity: enabled ? 1 : .45,
                          child: Material(
                            color: selected
                                ? colors.primary.withOpacity(.07)
                                : colors.surface,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                    color: selected
                                        ? colors.primary
                                        : colors.outlineVariant,
                                    width: selected ? 1.5 : 1)),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: enabled ? () => onChoice(option.$1) : null,
                              child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Row(children: [
                                    Icon(option.$4,
                                        size: 22,
                                        color: selected
                                            ? colors.primary
                                            : colors.onSurfaceVariant),
                                    const SizedBox(width: 12),
                                    Expanded(
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                          Text(option.$2,
                                              style: theme.textTheme.bodyMedium
                                                  ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w600)),
                                          const SizedBox(height: 4),
                                          Text(option.$3,
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                      color: colors
                                                          .onSurfaceVariant)),
                                        ])),
                                    const SizedBox(width: 8),
                                    Icon(
                                        selected
                                            ? Icons.check_circle
                                            : Icons.circle_outlined,
                                        size: 20,
                                        color: selected
                                            ? colors.primary
                                            : colors.outlineVariant),
                                  ])),
                            ),
                          ),
                        ));
                  }).toList());
            }),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
                onPressed: enabled ? onTest : null,
                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                label: const Text('试听当前提醒')),
            if (status != null)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(status!, style: theme.textTheme.bodySmall)),
            const SizedBox(height: 12),
            Text('设置自动保存 · 连续消息合并提醒\n首次使用请先点击页面；语音不可用时自动使用铃声。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant, height: 1.6)),
          ]),
    );
  }
}
