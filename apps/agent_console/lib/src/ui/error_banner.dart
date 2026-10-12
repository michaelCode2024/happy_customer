import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// An inline failure notice.
///
/// It carries the server's own wording, which is written for the person reading
/// it ("企业已停用", "平台管理令牌无效"), so it is shown verbatim rather than
/// translated into a friendlier phrase that would hide the actual cause.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({
    super.key,
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.error_outline,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, color: theme.colorScheme.onErrorContainer),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// Copies a value to the clipboard and confirms it. Used for the ids and
/// generated passwords an operator has to hand to someone else.
Future<void> copyToClipboard(
  BuildContext context,
  String value,
  String label,
) async {
  try {
    await Clipboard.setData(ClipboardData(text: value));
  } catch (_) {
    if (!context.mounted) return;
    // 嵌入浏览器可能限制剪贴板；仍提供可选中的完整内容，不让复制操作无响应。
    await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text('手动复制$label'),
              content: SizedBox(
                  width: 560,
                  child: SingleChildScrollView(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        const Text('当前浏览器限制了剪贴板访问，请选中下面的内容复制。'),
                        const SizedBox(height: 16),
                        SelectableText(value),
                      ]))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'))
              ],
            ));
    return;
  }
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('$label已复制'), duration: const Duration(seconds: 2)),
  );
}
