import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:relaydesk_agent_console/src/api/api_exception.dart';
import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';

/// 坐席 AI 辅助条：会话摘要、回复建议、翻译、情感、润色、下一步。
///
/// 关键约束：这里产出的都是草稿，需坐席手动「采纳」后才进入输入框发送。
/// 它与自动回复严格分离——自动回复是对客承诺，助手只是给坐席的参考。
class AiAssistPanel extends StatefulWidget {
  const AiAssistPanel({
    super.key,
    required this.api,
    required this.conversationId,
    required this.messages,
    required this.onAdopt,
  });

  final RelayDeskApi api;
  final String conversationId;
  final List<ChatMessage> messages;
  final void Function(String) onAdopt;

  @override
  State<AiAssistPanel> createState() => _AiAssistPanelState();
}

class _AiAssistPanelState extends State<AiAssistPanel> {
  bool _open = false;
  bool _busy = false;
  String? _activeTask;
  AssistResult? _result;
  String? _error;

  // 中文标签 + 服务端任务名。顺序即按钮顺序。
  static const List<(String, String)> _tasks = <(String, String)>[
    ('SUMMARIZE', '摘要'),
    ('SUGGEST', '建议回复'),
    ('TRANSLATE', '翻译'),
    ('SENTIMENT', '情感'),
    ('POLISH', '润色'),
    ('NEXT_ACTION', '下一步'),
  ];

  // 这两类结果可直接「采纳」到输入框；其余仅作参考。
  static const Set<String> _adoptable = <String>{'SUGGEST', 'POLISH'};

  @override
  void didUpdateWidget(covariant AiAssistPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换到另一个会话时，丢弃上一个会话的草稿结果，避免串台。
    if (oldWidget.conversationId != widget.conversationId) {
      _result = null;
      _error = null;
      _activeTask = null;
    }
  }

  String get _question {
    // 取最后一条访客文本消息作为建议 / 情感 / 翻译的素材。
    for (int i = widget.messages.length - 1; i >= 0; i--) {
      final message = widget.messages[i];
      if (message.senderType == 'VISITOR' && message.messageType == 'TEXT') {
        return message.content;
      }
    }
    return '';
  }

  Future<void> _run(String task) async {
    if (_busy) return;
    final conversationId = widget.conversationId;
    setState(() {
      _busy = true;
      _activeTask = task;
      _error = null;
    });
    try {
      final result = await widget.api.assist(
        task: task,
        conversationId: conversationId,
        question: _question,
      );
      if (!mounted || widget.conversationId != conversationId) return;
      setState(() => _result = result);
    } on ApiException catch (e) {
      if (mounted && widget.conversationId == conversationId)
        setState(() => _error = e.message);
    } catch (e) {
      if (mounted && widget.conversationId == conversationId)
        setState(() => _error = '请求失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Color _sentimentColor(String label) {
    switch (label) {
      case 'POSITIVE':
        return Colors.green.shade600;
      case 'NEGATIVE':
        return Colors.red.shade600;
      case 'NEUTRAL':
        return Colors.orange.shade700;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelOf = <String, String>{
      for (final (task, label) in _tasks) task: label,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withOpacity(0.22),
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withOpacity(0.4)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 收缩态：单行"AI 助手”触发展开。只在会话有消息时才出现。
          ListTile(
            visualDensity: VisualDensity.compact,
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'AI 助手',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            subtitle: _result != null
                ? Text('${labelOf[_result!.task] ?? _result!.task} · 采纳后可继续编辑')
                : null,
            trailing: _busy && _activeTask != null
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    _open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    color: scheme.onSurfaceVariant,
                  ),
            onTap: () => setState(() => _open = !_open),
          ),
          if (_open) ...<Widget>[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (task, label) in _tasks)
                    _ActionChip(
                      label: label,
                      loading: _busy && _activeTask == task,
                      onTap: _busy ? null : () => _run(task),
                    ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.error_outline, size: 16, color: scheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_error!,
                          style: TextStyle(color: scheme.error, fontSize: 13)),
                    ),
                  ],
                ),
              ),
            if (_result != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ResultCard(
                  result: _result!,
                  labelOf: labelOf,
                  onAdopt: widget.onAdopt,
                  onDismiss: () => setState(() => _result = null),
                  onSentimentColor: _sentimentColor,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.label,
    required this.onTap,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(
            color: onTap == null
                ? Colors.transparent
                : Theme.of(context).colorScheme.primary.withOpacity(0.5),
          ),
          borderRadius: BorderRadius.circular(16),
          color: loading
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.primary.withOpacity(0.08),
        ),
        child: loading
            ? const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(label, style: const TextStyle(fontSize: 13)),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.result,
    required this.labelOf,
    required this.onAdopt,
    required this.onDismiss,
    required this.onSentimentColor,
  });

  final AssistResult result;
  final Map<String, String> labelOf;
  final void Function(String) onAdopt;
  final VoidCallback onDismiss;
  final Color Function(String) onSentimentColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = labelOf[result.task] ?? result.task;
    final empty = result.text.trim().isEmpty;

    if (empty && !result.available) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text('当前租户未配置 AI，或模型未返回内容。',
            style: Theme.of(context).textTheme.bodySmall),
      );
    }
    if (empty) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text('没有可生成的内容（上下文可能为空）。',
            style: Theme.of(context).textTheme.bodySmall),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant.withOpacity(0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13)),
                const Spacer(),
                if (result.task == 'SENTIMENT' && result.label.isNotEmpty)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: onSentimentColor(result.label).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${result.label}${result.score != 0 ? ' ${(result.score * 100).round()}%' : ''}',
                      style: TextStyle(
                        fontSize: 12,
                        color: onSentimentColor(result.label),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: '收起',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDismiss,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(result.text,
                style: const TextStyle(fontSize: 13, height: 1.5)),
            if (result.sources.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Text('参考：${result.sources.join('、')}',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                TextButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制'),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: result.text));
                  },
                ),
                if (_AiAssistPanelState._adoptable.contains(result.task))
                  TextButton.icon(
                    icon: const Icon(Icons.arrow_downward, size: 16),
                    label: const Text('采纳到输入框'),
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    onPressed: () => onAdopt(result.text),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
