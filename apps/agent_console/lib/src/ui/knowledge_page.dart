import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/state/session_controller.dart';
import 'package:relaydesk_agent_console/src/state/workbench_controller.dart';

/// The AI knowledge base.
///
/// This screen is split into two halves on purpose. The left half is the
/// content the AI reads; the right half is a live test bench that answers "what
/// would the AI say to this question?" — first by retrieval alone (free) and
/// then, on demand, through the model. Without that bench a tenant is editing
/// the knowledge base blind.
class KnowledgePage extends StatefulWidget {
  const KnowledgePage({
    super.key,
    required this.session,
    required this.workbench,
  });

  final SessionController session;
  final WorkbenchController workbench;

  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  final _search = TextEditingController();
  final _question = TextEditingController();

  List<KnowledgeEntry> _entries = const <KnowledgeEntry>[];
  bool _loading = true;
  String? _error;

  List<KnowledgeHit>? _hits;
  KnowledgeAnswer? _answer;
  bool _testing = false;
  String? _testError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _question.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.workbench.api.knowledge(query: _search.text);
      if (!mounted) {
        return;
      }
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  /// Retrieval only. This is the cheap check: it shows which entries matched and
  /// with what score, so a bad answer can be traced to bad content rather than
  /// blamed on the model.
  Future<void> _runRetrieval() async {
    final question = _question.text.trim();
    if (question.isEmpty) {
      return;
    }
    setState(() {
      _testing = true;
      _testError = null;
      _answer = null;
    });
    try {
      final hits = await widget.workbench.api.previewRetrieval(question);
      if (!mounted) {
        return;
      }
      setState(() {
        _hits = hits;
        _testing = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _testError = '$error';
        _testing = false;
      });
    }
  }

  /// A full answer, which spends a model call. Kept behind its own button so a
  /// tenant never burns quota by typing in the box.
  Future<void> _runAnswer() async {
    final question = _question.text.trim();
    if (question.isEmpty) {
      return;
    }
    setState(() {
      _testing = true;
      _testError = null;
    });
    try {
      final answer = await widget.workbench.api.previewAnswer(question);
      if (!mounted) {
        return;
      }
      setState(() {
        _answer = answer;
        _hits = answer.sources;
        _testing = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _testError = '$error';
        _testing = false;
      });
    }
  }

  Future<void> _edit({KnowledgeEntry? existing}) async {
    final result = await showDialog<_KnowledgeDraft>(
      context: context,
      builder: (context) => _KnowledgeDialog(existing: existing),
    );
    if (result == null) {
      return;
    }
    try {
      if (existing == null) {
        await widget.workbench.api.createKnowledge(
          title: result.title,
          content: result.content,
          questionExamples: result.examples,
        );
      } else {
        await widget.workbench.api.updateKnowledge(
          id: existing.id,
          title: result.title,
          content: result.content,
          questionExamples: result.examples,
        );
      }
      await _load();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$error')),
      );
    }
  }

  Future<void> _delete(KnowledgeEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除知识条目'),
        content: Text('确定删除「${entry.title}」？AI 将不再使用这条内容。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await widget.workbench.api.deleteKnowledge(entry.id);
      await _load();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canEdit = widget.session.agent?.canManageKnowledge ?? false;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('AI 知识库'),
        backgroundColor: Colors.transparent,
        actions: <Widget>[
          if (canEdit)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.tonalIcon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新增条目'),
              ),
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth > 980;
          final list = _buildList(theme, canEdit);
          final bench = _buildBench(theme);
          if (!wide) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: <Widget>[
                SizedBox(height: 420, child: list),
                const SizedBox(height: 24),
                bench,
              ],
            );
          }
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(flex: 3, child: list),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: SingleChildScrollView(child: bench),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildList(ThemeData theme, bool canEdit) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant.withAlpha(120)),
      ),
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      hintText: '搜索标题或内容',
                      prefixIcon: Icon(Icons.search, size: 20),
                    ),
                    onSubmitted: (_) => _load(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '搜索',
                  onPressed: _load,
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ),
          if (!canEdit)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                '仅主管及以上角色可以编辑知识库，你可以浏览并测试。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 4),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text('加载失败：$_error', textAlign: TextAlign.center),
                        ),
                      )
                    : _entries.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Icon(
                                    Icons.menu_book_outlined,
                                    size: 38,
                                    color: theme.colorScheme.outline,
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    '还没有知识条目',
                                    style: theme.textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '把常见问答、产品说明、退换政策录进来，AI 就能自动回答。',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _entries.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1, indent: 16),
                            itemBuilder: (context, index) {
                              final entry = _entries[index];
                              return ListTile(
                                title: Text(
                                  entry.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                subtitle: Text(
                                  entry.content,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Tooltip(
                                      message: '被命中 ${entry.hitCount} 次',
                                      child: Text(
                                        '${entry.hitCount}',
                                        style: theme.textTheme.labelSmall?.copyWith(
                                          color: theme.colorScheme.outline,
                                        ),
                                      ),
                                    ),
                                    if (canEdit) ...<Widget>[
                                      IconButton(
                                        tooltip: '编辑',
                                        iconSize: 18,
                                        onPressed: () => _edit(existing: entry),
                                        icon: const Icon(Icons.edit_outlined),
                                      ),
                                      IconButton(
                                        tooltip: '删除',
                                        iconSize: 18,
                                        onPressed: () => _delete(entry),
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                    ],
                                  ],
                                ),
                                onTap: canEdit
                                    ? () => _edit(existing: entry)
                                    : () => _fillQuestion(entry.title),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }

  void _fillQuestion(String value) {
    _question.text = value;
    setState(() {});
  }

  Widget _buildBench(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant.withAlpha(120)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.science_outlined, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('回答测试台', style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '先做检索，确认命中的条目对不对；确认没问题再让 AI 生成回答。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _question,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '模拟客户提问',
              hintText: '例如：订单什么时候发货？',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _testing ? null : _runRetrieval,
                icon: const Icon(Icons.search, size: 18),
                label: const Text('仅检索'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _testing ? null : _runAnswer,
                icon: _testing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome, size: 18),
                label: const Text('生成回答'),
              ),
            ],
          ),
          if (_testError != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _testError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (_answer != null) ...<Widget>[
            const SizedBox(height: 16),
            Text('AI 回答', style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withAlpha(110),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                _answer!.answer.isEmpty ? '（AI 未生成内容）' : _answer!.answer,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text('置信度 ${_answer!.score.toStringAsFixed(2)}'),
                ),
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    '提供方 ${_answer!.provider.isEmpty ? '未启用' : _answer!.provider}',
                  ),
                ),
                if (_answer!.handoff)
                  const Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('会转人工'),
                  ),
                if (_answer!.reason.isNotEmpty)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(_answer!.reason),
                  ),
              ],
            ),
          ],
          if (_hits != null) ...<Widget>[
            const SizedBox(height: 16),
            Text(
              '检索命中 ${_hits!.length} 条',
              style: theme.textTheme.labelMedium,
            ),
            const SizedBox(height: 6),
            if (_hits!.isEmpty)
              Text(
                '没有命中任何条目：AI 会走转人工或兜底话术。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            for (final hit in _hits!)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withAlpha(90),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              hit.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium,
                            ),
                          ),
                          Text(
                            hit.score.toStringAsFixed(2),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hit.content,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// The editable fields of a knowledge entry.
class _KnowledgeDraft {
  const _KnowledgeDraft({
    required this.title,
    required this.content,
    required this.examples,
  });

  final String title;
  final String content;
  final List<String> examples;
}

class _KnowledgeDialog extends StatefulWidget {
  const _KnowledgeDialog({this.existing});

  final KnowledgeEntry? existing;

  @override
  State<_KnowledgeDialog> createState() => _KnowledgeDialogState();
}

class _KnowledgeDialogState extends State<_KnowledgeDialog> {
  late final TextEditingController _title;
  late final TextEditingController _content;
  late final TextEditingController _examples;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.existing?.title ?? '');
    _content = TextEditingController(text: widget.existing?.content ?? '');
    _examples = TextEditingController(
      text: (widget.existing?.questionExamples ?? const <String>[]).join('\n'),
    );
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _examples.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNew = widget.existing == null;
    return AlertDialog(
      title: Text(isNew ? '新增知识条目' : '编辑知识条目'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: '标题',
                  hintText: '例如：发货时间说明',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _content,
                minLines: 5,
                maxLines: 12,
                decoration: const InputDecoration(
                  labelText: '内容',
                  hintText: '写清楚事实与口径。AI 会基于这段内容回答，越具体越准确。',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _examples,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '客户可能的问法（每行一条）',
                  hintText: '什么时候发货\n多久能到',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '标题在同一个企业内唯一，重复标题会覆盖更新同一条内容。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final title = _title.text.trim();
            final content = _content.text.trim();
            if (title.isEmpty || content.isEmpty) {
              return;
            }
            Navigator.of(context).pop(
              _KnowledgeDraft(
                title: title,
                content: content,
                examples: _examples.text
                    .split('\n')
                    .map((line) => line.trim())
                    .where((line) => line.isNotEmpty)
                    .toList(growable: false),
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
