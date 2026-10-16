import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';

/// 保存失败时不宣称已采纳，反馈只表示草稿质量，不表示客户问题解决。
class AssistFeedbackActions extends StatefulWidget {
  const AssistFeedbackActions(
      {super.key,
      required this.api,
      required this.result,
      required this.onAdopt,
      this.canAdopt = true});
  final TongYuApi api;
  final AssistResult result;
  final ValueChanged<AssistResult> onAdopt;
  final bool canAdopt;
  @override
  State<AssistFeedbackActions> createState() => _AssistFeedbackActionsState();
}

class _AssistFeedbackActionsState extends State<AssistFeedbackActions> {
  bool _busy = false;
  String? _feedback;
  String? _error;
  Future<void> _act(String action) async {
    if (_busy) return;
    final result = widget.result;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (result.interactionId.isNotEmpty) {
        await widget.api.assistFeedback(result.interactionId, action);
      }
      if (!mounted || result != widget.result) return;
      if (action == 'ADOPT') {
        if (!widget.canAdopt) return;
        widget.onAdopt(result);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已插入输入框，请确认后发送')));
      } else {
        setState(() => _feedback = action);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '反馈未保存，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(spacing: 8, runSpacing: 4, children: [
              OutlinedButton.icon(
                  onPressed:
                      _busy || !widget.canAdopt ? null : () => _act('ADOPT'),
                  icon: const Icon(Icons.edit_outlined, size: 15),
                  label: const Text('插入输入框')),
              if (widget.result.interactionId.isNotEmpty) ...[
                TextButton(
                    onPressed: _busy ? null : () => _act('HELPFUL'),
                    child: Text(_feedback == 'HELPFUL' ? '已反馈：有用' : '有用')),
                TextButton(
                    onPressed: _busy ? null : () => _act('NEEDS_WORK'),
                    child: Text(_feedback == 'NEEDS_WORK' ? '已反馈：需改进' : '需改进')),
              ],
            ]),
            if (_error != null)
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]);
}
