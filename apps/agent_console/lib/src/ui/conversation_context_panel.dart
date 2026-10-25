import 'package:tongyu_agent_console/src/ui/design_a.dart';
import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/ui/assist_feedback_actions.dart';

import 'package:tongyu_agent_console/src/api/api_exception.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/ui/visitor_sidebar.dart';

/// 右侧上下文与当前会话绑定；隐藏的标签页保留结果，切换会话时销毁旧草稿。
class ConversationContextPanel extends StatefulWidget {
  const ConversationContextPanel({
    super.key,
    required this.workbench,
    required this.onAdopt,
    this.initialTab = 1,
    this.activeTabNotifier,
  });

  final WorkbenchController workbench;
  final ValueChanged<AssistResult> onAdopt;
  final int initialTab;
  final ValueNotifier<int>? activeTabNotifier;

  @override
  State<ConversationContextPanel> createState() =>
      _ConversationContextPanelState();
}

class _ConversationContextPanelState extends State<ConversationContextPanel> {
  late int _tab;

  @override
  void initState() {
    super.initState();
    _tab = widget.activeTabNotifier?.value ?? widget.initialTab;
    widget.activeTabNotifier?.addListener(_onTabNotifierChanged);
  }

  @override
  void didUpdateWidget(covariant ConversationContextPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeTabNotifier != widget.activeTabNotifier) {
      oldWidget.activeTabNotifier?.removeListener(_onTabNotifierChanged);
      widget.activeTabNotifier?.addListener(_onTabNotifierChanged);
      if (widget.activeTabNotifier != null) {
        _tab = widget.activeTabNotifier!.value;
      }
    }
  }

  @override
  void dispose() {
    widget.activeTabNotifier?.removeListener(_onTabNotifierChanged);
    super.dispose();
  }

  void _onTabNotifierChanged() {
    if (widget.activeTabNotifier != null &&
        widget.activeTabNotifier!.value != _tab) {
      setState(() => _tab = widget.activeTabNotifier!.value);
    }
  }

  void _switchTab(int index) {
    setState(() => _tab = index);
    if (widget.activeTabNotifier != null &&
        widget.activeTabNotifier!.value != index) {
      widget.activeTabNotifier!.value = index;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(children: [
      SizedBox(
          height: 48,
          child: Row(children: [
            for (var i = 0; i < 2; i++)
              Expanded(
                  child: InkWell(
                key: ValueKey(i == 0 ? 'context-tab-profile' : 'context-tab-ai'),
                onTap: () => _switchTab(i),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      border: Border(
                          bottom: BorderSide(
                    color: _tab == i ? scheme.primary : scheme.outlineVariant,
                    width: _tab == i ? 2 : 1,
                  ))),
                  child: Text(i == 0 ? '客户资料' : 'AI 助手',
                      style: TextStyle(
                        color: _tab == i
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      )),
                ),
              )),
          ])),
      Expanded(
          child: IndexedStack(index: _tab, children: [
        VisitorSidebar(workbench: widget.workbench, showHeader: false),
        ListenableBuilder(
            listenable: widget.workbench,
            builder: (context, _) {
              final id = widget.workbench.selectedId;
              if (id == null)
                return const SingleChildScrollView(
                    padding: EdgeInsets.all(20),
                    child: Column(
                        children: [TongYuAiWelcome(), Text('选择会话，开始智能辅助')]));
              return AiReceptionPanel(
                key: ValueKey(id),
                api: widget.workbench.api,
                conversationId: id,
                messages: widget.workbench.messages,
                onAdopt: widget.onAdopt,
              );
            }),
      ])),
    ]);
  }
}

class AiReceptionPanel extends StatefulWidget {
  const AiReceptionPanel(
      {super.key,
      required this.api,
      required this.conversationId,
      required this.messages,
      required this.onAdopt});
  final TongYuApi api;
  final String conversationId;
  final List<ChatMessage> messages;
  final ValueChanged<AssistResult> onAdopt;

  @override
  State<AiReceptionPanel> createState() => _AiReceptionPanelState();
}

class _AiReceptionPanelState extends State<AiReceptionPanel> {
  final _results = <String, AssistResult>{};
  final _errors = <String, String>{};
  final _busy = <String>{};
  final _versions = <String, String>{};

  // 回执变化不使草稿过期；新增、编辑、撤回文本会改变依据，必须重新确认。
  String get _version => widget.messages
      .where((m) => m.messageType == 'TEXT')
      .map((m) => '${m.id}:${m.content}:${m.deletedAt}')
      .join('|');

  String get _question {
    for (final m in widget.messages.reversed) {
      if (m.senderType == 'VISITOR' &&
          m.messageType == 'TEXT' &&
          m.deletedAt == null) return m.content;
    }
    return '';
  }

  bool _stale(String task) =>
      _results.containsKey(task) && _versions[task] != _version;

  Future<void> _run(String task) async {
    if (_busy.contains(task) || _question.isEmpty) return;
    final id = widget.conversationId;
    final version = _version;
    setState(() {
      _busy.add(task);
      _errors.remove(task);
    });
    try {
      final result = await widget.api
          .assist(task: task, conversationId: id, question: _question);
      if (!mounted || widget.conversationId != id) return;
      if (!result.available || result.text.trim().isEmpty) {
        throw const FormatException('AI 未生成有效内容，请重试或联系管理员');
      }
      setState(() {
        _results[task] = result;
        _versions[task] = version;
      });
    } catch (error) {
      if (!mounted || widget.conversationId != id) return;
      setState(() => _errors[task] = error is ApiException
          ? error.message
          : error is FormatException
              ? error.message
              : '生成失败，请稍后重试');
    } finally {
      if (mounted && widget.conversationId == id) {
        setState(() => _busy.remove(task));
      }
    }
  }

  void _generate() {
    _run('SUMMARIZE');
    _run('SUGGEST');
  }

  void _openSource(KnowledgeHit source) {
    showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(source.title),
              content: SizedBox(
                  width: 560,
                  child: SingleChildScrollView(
                      child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('本次推荐使用的知识内容',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 16),
                      SelectableText(source.content),
                    ],
                  ))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'))
              ],
            ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final suggestion = _results['SUGGEST'];
    return ListView(padding: const EdgeInsets.all(16), children: [
      const TongYuAiWelcome(compact: true),
      const SizedBox(height: 14),
      FilledButton.icon(
          onPressed: _busy.isNotEmpty || _question.isEmpty ? null : _generate,
          icon: const Icon(Icons.auto_awesome_outlined, size: 16),
          label: Text(_busy.isNotEmpty
              ? '正在生成辅助…'
              : _results.isEmpty
                  ? '生成会话辅助'
                  : '更新会话辅助')),
      // 摘要和推荐独立返回，来源随推荐返回；整个面板只显示一个等待状态。
      if (_busy.isNotEmpty) ...[
        const SizedBox(height: 10),
        const LinearProgressIndicator(minHeight: 2),
        const SizedBox(height: 8),
        Text(
            _busy.length > 1
                ? '正在整理会话并起草回复…'
                : _busy.contains('SUGGEST')
                    ? '正在结合知识库起草回复…'
                    : '正在整理会话摘要…',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
      if (_question.isEmpty)
        const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('收到访客文本消息后，即可生成摘要和推荐回复。',
                style: TextStyle(fontSize: 12, color: Colors.grey))),
      const SizedBox(height: 14),
      const Divider(height: 28),
      _section('会话摘要', 'SUMMARIZE', Icons.subject_rounded),
      const SizedBox(height: 12),
      _content('SUMMARIZE', '提炼客户诉求、已确认事实和待办事项'),
      const Divider(height: 28),
      _section('推荐回复', 'SUGGEST', Icons.chat_bubble_outline_rounded),
      const SizedBox(height: 12),
      Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: scheme.primaryContainer.withOpacity(0.32),
              border: Border.all(color: scheme.primary.withOpacity(0.22)),
              borderRadius: BorderRadius.circular(8)),
          child: _content('SUGGEST', '结合知识库起草回复，由你确认后发送')),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (suggestion != null)
          AssistFeedbackActions(
              key: ValueKey(suggestion),
              api: widget.api,
              result: suggestion,
              canAdopt: !_busy.contains('SUGGEST') && !_stale('SUGGEST'),
              onAdopt: widget.onAdopt),
        TextButton.icon(
            onPressed: _busy.contains('SUGGEST') || _question.isEmpty
                ? null
                : () => _run('SUGGEST'),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重新生成')),
      ]),
      const Divider(height: 28),
      const Text('知识来源',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      const Text('展示本次检索提供给 AI 的参考内容',
          style: TextStyle(fontSize: 11, color: Colors.grey)),
      const SizedBox(height: 12),
      if (suggestion == null)
        const Text('生成推荐回复后显示知识来源',
            style: TextStyle(color: Colors.grey, fontSize: 12))
      else if (suggestion.sourceDetails.isEmpty)
        Text(
            suggestion.sources.isEmpty
                ? '未检索到相关知识，请核实后回复，或补充知识库。'
                : '参考：${suggestion.sources.join('、')}（当前服务暂不提供正文）',
            style: const TextStyle(color: Colors.grey, fontSize: 12))
      else
        ...suggestion.sourceDetails.map((source) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: scheme.surface,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: scheme.outlineVariant)),
                child: ListTile(
                    dense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    leading:
                        Icon(Icons.description_outlined, color: scheme.primary),
                    title: Text(source.title,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle:
                        const Text('查看参考正文', style: TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.open_in_new, size: 16),
                    onTap: () => _openSource(source)),
              ),
            )),
      const SizedBox(height: 24),
      const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.info_outline, size: 15, color: Colors.grey),
        SizedBox(width: 8),
        Expanded(
            child: Text('AI 生成内容仅供参考，确认后再发送给客户。',
                style:
                    TextStyle(fontSize: 12, color: Colors.grey, height: 1.6))),
      ]),
    ]);
  }

  Widget _section(String title, String task, IconData icon) => Row(children: [
        Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700))),
        if (task == 'SUMMARIZE')
          IconButton(
              tooltip: '更新摘要',
              visualDensity: VisualDensity.compact,
              onPressed: _busy.contains(task) || _question.isEmpty
                  ? null
                  : () => _run(task),
              icon: const Icon(Icons.refresh, size: 17)),
      ]);

  Widget _content(String task, String empty) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_results[task] != null)
          _resultPreview(task)
        else
          Text(empty,
              style: const TextStyle(
                  fontSize: 12, color: Colors.grey, height: 1.8)),
        if (_errors[task] != null) ...[
          const SizedBox(height: 8),
          Text(_errors[task]!,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.error, fontSize: 12)),
          TextButton(
              onPressed: _busy.contains(task) ? null : () => _run(task),
              child: const Text('重试')),
        ],
        if (_stale(task))
          const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('会话已有新内容，请更新后使用。',
                  style: TextStyle(fontSize: 12, color: Color(0xFFB7791F)))),
      ]);

  // 默认限制占用行数，避免一条长建议把知识来源挤出视口；采纳仍使用完整正文。
  Widget _resultPreview(String task) =>
      LayoutBuilder(builder: (context, constraints) {
        final text =
            _results[task]!.text.trim().replaceAll(RegExp(r'\n\s*\n'), '\n');
        final style = Theme.of(context)
            .textTheme
            .bodySmall!
            .copyWith(fontSize: 13, height: 1.65);
        final lines = task == 'SUMMARIZE' ? 4 : 5;
        final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            maxLines: lines)
          ..layout(maxWidth: constraints.maxWidth);
        final overflow = painter.didExceedMaxLines;
        painter.dispose();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text,
              style: style, maxLines: lines, overflow: TextOverflow.ellipsis),
          if (overflow)
            TextButton(
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact),
                onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                          title:
                              Text(task == 'SUMMARIZE' ? '完整会话摘要' : '完整推荐回复'),
                          content: SizedBox(
                              width: 560,
                              child: SingleChildScrollView(
                                  child: SelectableText(_results[task]!.text))),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('关闭'))
                          ],
                        )),
                child: const Text('查看全文')),
        ]);
      });
}
