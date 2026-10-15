import 'package:flutter/material.dart';

/// A 方案的品牌插画仅负责呈现，不承载示例数据或替代真实业务状态。
class TongYuArtwork extends StatelessWidget {
  const TongYuArtwork({super.key, this.ai = false, this.size = 160});
  final bool ai;
  final double size;
  @override
  Widget build(BuildContext context) => Image.asset(
        'assets/images/${ai ? 'ai-assistant' : 'knowledge-hero'}.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
        excludeFromSemantics: true,
        errorBuilder: (_, __, ___) => SizedBox(
            width: size,
            height: size,
            child: Icon(ai ? Icons.auto_awesome : Icons.menu_book_outlined,
                size: size / 3, color: Theme.of(context).colorScheme.primary)),
      );
}

/// 手机采用自然高度，避免固定高度的营销区挤压表单和工作区域。
class TongYuHero extends StatelessWidget {
  const TongYuHero(
      {super.key,
      required this.title,
      required this.description,
      this.eyebrow = 'TONGYU / 团队工作空间',
      this.ai = false,
      this.compact = false,
      this.action});
  final String title, description, eyebrow;
  final bool ai, compact;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 580;
      final copy = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(eyebrow,
                style: TextStyle(
                    fontSize: 11,
                    letterSpacing: .6,
                    color: scheme.primary,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Text(title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontSize: compact ? 20 : (narrow ? 23 : 29),
                    height: 1.5,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text(description,
                style: TextStyle(
                    fontSize: 12, height: 1.9, color: scheme.onSurfaceVariant)),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ]);
      final art =
          TongYuArtwork(ai: ai, size: compact ? 110 : (narrow ? 155 : 235));
      return Container(
        width: double.infinity,
        padding: EdgeInsets.all(compact ? 18 : 28),
        decoration: BoxDecoration(
            gradient: LinearGradient(
                colors: dark
                    ? [scheme.primaryContainer.withOpacity(.4), scheme.surface]
                    : const [Color(0xFFEDF2FF), Color(0xFFE8EFFD)]),
            border: Border.all(color: scheme.primary.withOpacity(.08)),
            borderRadius: BorderRadius.circular(20)),
        child: narrow && !compact
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                copy,
                Align(alignment: Alignment.centerRight, child: art)
              ])
            : Row(children: [
                Expanded(child: copy),
                const SizedBox(width: 12),
                art
              ]),
      );
    });
  }
}

class TongYuAiWelcome extends StatelessWidget {
  const TongYuAiWelcome({super.key, this.compact = false});
  final bool compact;
  @override
  Widget build(BuildContext context) {
    if (compact) {
      final scheme = Theme.of(context).colorScheme;
      return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: scheme.primaryContainer.withOpacity(.45),
              borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            const TongYuArtwork(ai: true, size: 62),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('你的接待好搭档',
                      style: TextStyle(fontSize: 11, color: scheme.primary)),
                  const SizedBox(height: 5),
                  const Text('把整理留给助手',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('先核对，再采纳。回复由你决定。',
                      style: TextStyle(
                          fontSize: 11,
                          height: 1.6,
                          color: scheme.onSurfaceVariant)),
                ])),
          ]));
    }
    return Column(children: [
      const TongYuArtwork(ai: true, size: 142),
      Text('你的接待好搭档',
          style: TextStyle(
              fontSize: 11, color: Theme.of(context).colorScheme.primary)),
      const SizedBox(height: 8),
      const Text('专注倾听，把整理留给助手。',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 19, height: 1.5, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text('从会话中抓住重点，为你准备下一句回应。',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 12,
              height: 1.8,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: 18),
    ]);
  }
}
