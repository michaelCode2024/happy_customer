import 'package:flutter/material.dart';

/// 工作台顶栏横幅。声音通知、版本更新、待接待共用这一条，只换底色。
enum DeskBarTone { amber, info }

class DeskBar extends StatelessWidget {
  const DeskBar({
    super.key,
    required this.message,
    required this.tone,
    this.detail,
    this.messageKey,
    this.actionLabel,
    this.actionKey,
    this.onAction,
    this.onClose,
    this.busy = false,
  });

  final String message;
  final String? detail;
  final Key? messageKey;
  final DeskBarTone tone;
  final String? actionLabel;
  final Key? actionKey;
  final VoidCallback? onAction;
  final VoidCallback? onClose;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final amber = tone == DeskBarTone.amber;
    final background = amber ? const Color(0xFFFFF4D6) : const Color(0xFFEFF4FF);
    final foreground = amber ? const Color(0xFF7A4E00) : const Color(0xFF0C1D40);
    final line = amber ? const Color(0xFFF0DBB8) : const Color(0xFFD3E0FD);
    final action = actionLabel;
    return Material(
      color: background,
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: line)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    key: messageKey,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: foreground,
                    ),
                  ),
                  if (detail != null && detail!.isNotEmpty)
                    Text(
                      detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: foreground.withValues(alpha: .75),
                      ),
                    ),
                ],
              ),
            ),
            if (action != null) ...[
              const SizedBox(width: 8),
              amber
                  ? FilledButton(
                      key: actionKey,
                      onPressed: busy ? null : onAction,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFE8A317),
                        foregroundColor: const Color(0xFF3D2A00),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(busy ? '正在打开…' : action),
                    )
                  : TextButton(
                      key: actionKey,
                      onPressed: busy ? null : onAction,
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF3263FF),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(
                        action,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
            ],
            if (onClose != null)
              IconButton(
                tooltip: '不再提示',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                iconSize: 16,
                color: foreground,
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded),
              ),
          ],
        ),
      ),
    );
  }
}
