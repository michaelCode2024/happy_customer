import 'package:tongyu_agent_console/src/ui/design_a.dart';
import 'package:tongyu_agent_console/src/ui/workspace_layout.dart';
import 'package:tongyu_agent_console/src/util/labels.dart';
import 'package:tongyu_agent_console/src/ui/support_assets_page.dart';
import 'package:flutter/material.dart';

import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/state/session_controller.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';

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
    this.canAI = true,
  });

  final SessionController session;
  final WorkbenchController workbench;
  final bool canAI;

  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  final _search = TextEditingController();
  final _question = TextEditingController();

  List<Map<String, dynamic>> _categories = [];
  String _categoryFilter = '';
  String _statusFilter = '';
  int _tab = 0;
  bool _mobileBench = false;
  String? _expandedEntry;
  int _loadGeneration = 0;
  final List<String> _testHistory = [];
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
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final values = await Future.wait<Object>([
        widget.workbench.api.knowledge(query: _search.text),
        widget.workbench.api.knowledgeCategories()
      ]);
      final entries = values[0] as List<KnowledgeEntry>;
      if (generation != _loadGeneration) return;
      _categories = values[1] as List<Map<String, dynamic>>;
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
      if (generation != _loadGeneration) return;
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
    _rememberQuestion(question);
    setState(() {
      _hits = null;
      _answer = null;
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
    _rememberQuestion(question);
    setState(() {
      _hits = null;
      _answer = null;
      _testing = true;
      _testError = null;
    });
    try {
      final answer = await widget.workbench.api.previewAnswer(question);
      final hits = answer.reason == 'AI_DISABLED'
          ? await widget.workbench.api.previewRetrieval(question)
          : answer.sources;
      if (!mounted) {
        return;
      }
      setState(() {
        _answer = answer;
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

  Future<bool> _edit(
      {KnowledgeEntry? existing, String initialQuestion = ''}) async {
    List<Map<String, dynamic>> categories;
    try {
      categories = await widget.workbench.api.knowledgeCategories();
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("读取分类失败：$error")));
      return false;
    }
    if (!mounted) return false;
    final saved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _KnowledgeDialog(
            existing: existing,
            initialQuestion: initialQuestion,
            categories: categories,
            onSave: (draft) async {
              if (existing == null) {
                await widget.workbench.api.createKnowledge(
                    title: draft.title,
                    content: draft.content,
                    questionExamples: draft.examples,
                    sourceQuestion: initialQuestion,
                    categoryId: draft.categoryId);
              } else {
                await widget.workbench.api.updateKnowledge(
                    id: existing.id,
                    title: draft.title,
                    content: draft.content,
                    questionExamples: draft.examples,
                    categoryId: draft.categoryId);
              }
            }));
    if (saved == true && mounted) await _load();
    return saved == true;
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

  void _rememberQuestion(String question) {
    _testHistory.remove(question);
    _testHistory.insert(0, question);
    if (_testHistory.length > 5) _testHistory.removeLast();
  }

  List<KnowledgeEntry> get _visibleEntries => _entries
      .where((e) =>
          (_categoryFilter.isEmpty ||
              (_categoryFilter == 'uncategorized'
                  ? e.categoryId.isEmpty
                  : e.categoryId == _categoryFilter)) &&
          (_statusFilter.isEmpty || e.status == _statusFilter))
      .toList();
  String _categoryLabel(String id) {
    for (final c in _categories) {
      if (c['id'] == id) return asString(c['name']);
    }
    return '未分类';
  }

  Future<void> _toggleEntry(KnowledgeEntry e) async {
    try {
      await widget.workbench.api.updateKnowledge(
          id: e.id, status: e.status == 'ACTIVE' ? 'DISABLED' : 'ACTIVE');
      await _load();
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('更新失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canEdit = widget.session.agent?.canManageKnowledge ?? false;
    return Scaffold(
        backgroundColor: Colors.transparent,
        body: LayoutBuilder(builder: (context, viewport) {
          final content =
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            WorkspacePageHeader(
              title: '知识库',
              description: '让 AI 从准确的企业知识中找到答案',
              icon: Icons.menu_book_outlined,
              actions: [
                OutlinedButton.icon(
                    onPressed: _loading ? null : _load,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('刷新')),
                if (canEdit)
                  FilledButton.icon(
                      onPressed: () => _edit(),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('新增知识')),
              ],
            ),
            LayoutBuilder(
                builder: (context, box) => _tab != 0 || box.maxWidth < 900
                    ? const SizedBox.shrink()
                    : const Padding(
                        padding: EdgeInsets.fromLTRB(28, 0, 28, 20),
                        child: TongYuHero(
                            compact: true,
                            title: '你的团队经验，值得一个更好的家。',
                            description: '把产品说明、接入指引与常见问答整理在一起，为每一次回答提供依据。',
                            eyebrow: 'KNOWLEDGE / 团队知识'))),
            WorkspaceTabs(
                labels: ['知识管理', if (canEdit) '分类与批量导入', if (canEdit) '未解决问题'],
                selectedIndex: _tab,
                onSelected: (index) {
                  setState(() => _tab = index);
                  if (index == 0) _load();
                }),
            if (_tab == 0) _metrics(theme),
            if (_tab == 0 && _categories.isNotEmpty) _categoryCards(theme),
            Expanded(
                child: _tab != 0
                    ? SupportAssetsPage(
                        key: ValueKey(_tab),
                        api: widget.workbench.api,
                        knowledge: true,
                        embedded: true,
                        onGapAdd: (q) => _edit(initialQuestion: q),
                        onGapTest: (q) {
                          setState(() {
                            _tab = 0;
                            _mobileBench = true;
                            _question.text = q;
                          });
                          _runRetrieval();
                        },
                        initialKnowledgeTab: _tab == 2 ? 1 : 0)
                    : LayoutBuilder(builder: (context, c) {
                        final list = _buildList(theme, canEdit),
                            bench = _buildBench(theme);
                        if (c.maxWidth < 880) {
                          return Column(children: [
                            Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 0, 16, 10),
                                child: Row(children: [
                                  ChoiceChip(
                                      label: const Text('知识管理'),
                                      selected: !_mobileBench,
                                      onSelected: (_) =>
                                          setState(() => _mobileBench = false)),
                                  const SizedBox(width: 8),
                                  ChoiceChip(
                                      label: const Text('回答测试'),
                                      selected: _mobileBench,
                                      onSelected: (_) =>
                                          setState(() => _mobileBench = true))
                                ])),
                            Expanded(
                                child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        16, 0, 16, 16),
                                    child: _mobileBench
                                        ? SingleChildScrollView(child: bench)
                                        : list))
                          ]);
                        }
                        return Padding(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                            child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 7, child: list),
                                  const SizedBox(width: 20),
                                  Expanded(
                                      flex: 4,
                                      child:
                                          SingleChildScrollView(child: bench))
                                ]));
                      }))
          ]);
          return viewport.maxWidth >= 900
              ? SingleChildScrollView(
                  child: SizedBox(
                      height:
                          viewport.maxHeight < 1000 ? 1000 : viewport.maxHeight,
                      child: content))
              : content;
        }));
  }

  Widget _metrics(ThemeData theme) => LayoutBuilder(builder: (context, box) {
        final metrics = [
          ('知识条目', '${_entries.length}', Icons.menu_book_outlined),
          (
            '已启用',
            '${_entries.where((e) => e.status == 'ACTIVE').length}',
            Icons.check_circle_outline
          ),
          (
            '缺少相似问法',
            '${_entries.where((e) => e.questionExamples.isEmpty).length}',
            Icons.edit_note_outlined
          ),
          ('内容分类', '${_categories.length}', Icons.category_outlined),
        ];
        return Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: box.maxWidth < 900
                ? Wrap(spacing: 10, runSpacing: 8, children: [
                    for (final m in metrics) _summary(theme, m.$1, m.$2)
                  ])
                : Row(children: [
                    for (var i = 0; i < metrics.length; i++) ...[
                      if (i > 0) const SizedBox(width: 14),
                      Expanded(
                          child: WorkspaceKpiCard(
                              label: metrics[i].$1,
                              value: metrics[i].$2,
                              icon: metrics[i].$3)),
                    ]
                  ]));
      });

  Widget _categoryCards(ThemeData theme) =>
      LayoutBuilder(builder: (context, box) {
        if (box.maxWidth < 900) return const SizedBox.shrink();
        return SizedBox(
            height: 104,
            child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                scrollDirection: Axis.horizontal,
                itemCount: _categories.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final c = _categories[index],
                      id = asString(_categories[index]['id']);
                  final count =
                      _entries.where((e) => e.categoryId == id).length;
                  return SizedBox(
                      width: 210,
                      child: Material(
                          color: _categoryFilter == id
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.surface,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(
                                  color: theme.colorScheme.outlineVariant)),
                          child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () => setState(() => _categoryFilter =
                                  _categoryFilter == id ? '' : id),
                              child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Row(children: [
                                    Icon(Icons.folder_open_outlined,
                                        color: theme.colorScheme.primary),
                                    const SizedBox(width: 12),
                                    Expanded(
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                          Text(asString(c['name']),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w600)),
                                          const SizedBox(height: 5),
                                          Text('$count 篇 · 查看知识 ↗',
                                              style: theme.textTheme.bodySmall),
                                        ])),
                                  ])))));
                }));
      });

  Widget _summary(ThemeData theme, String title, String value) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(title, style: theme.textTheme.bodySmall),
        const SizedBox(width: 10),
        Text(value,
            style: theme.textTheme.titleSmall
                ?.copyWith(color: theme.colorScheme.primary))
      ]));

  Widget _buildList(ThemeData theme, bool canEdit) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: <Widget>[
          Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 4),
              child: Row(children: [
                const Icon(Icons.article_outlined, size: 18),
                const SizedBox(width: 8),
                Text('知识条目', style: theme.textTheme.titleSmall),
                const Spacer(),
                Text('${_visibleEntries.length} 条',
                    style: theme.textTheme.bodySmall),
              ])),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      hintText: '搜索标题或内容',
                      prefixIcon: Icon(Icons.search, size: 18),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _load(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '搜索',
                  onPressed: _load,
                  icon: const Icon(Icons.search, size: 20),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: LayoutBuilder(builder: (context, constraints) {
              final category = DropdownButtonFormField<String>(
                value: [
                  '',
                  'uncategorized',
                  ..._categories.map((c) => asString(c['id']))
                ].contains(_categoryFilter)
                    ? _categoryFilter
                    : '',
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: '知识分类',
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部分类')),
                  const DropdownMenuItem(
                      value: 'uncategorized', child: Text('未分类')),
                  for (final c in _categories)
                    DropdownMenuItem(
                        value: asString(c['id']),
                        child: Text(asString(c['name'])))
                ],
                onChanged: (v) => setState(() => _categoryFilter = v ?? ''),
              );
              final status = DropdownButtonFormField<String>(
                value: _statusFilter,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: '启用状态',
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
                items: const [
                  DropdownMenuItem(value: '', child: Text('全部状态')),
                  DropdownMenuItem(value: 'ACTIVE', child: Text('已启用')),
                  DropdownMenuItem(value: 'DISABLED', child: Text('已停用'))
                ],
                onChanged: (v) => setState(() => _statusFilter = v ?? ''),
              );
              return Row(children: [
                Expanded(child: category),
                const SizedBox(width: 12),
                Expanded(child: status)
              ]);
            }),
          ),
          if (!canEdit)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                '只读权限 · 点击标题查看全文，点击测试检查回答。',
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
                          child:
                              Text('加载失败：$_error', textAlign: TextAlign.center),
                        ),
                      )
                    : _visibleEntries.isEmpty
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
                                    '添加产品说明和常见问答，作为 AI 推荐回复的参考。',
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
                            itemCount: _visibleEntries.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1, indent: 16),
                            itemBuilder: (context, index) {
                              final entry = _visibleEntries[index];
                              final expanded = _expandedEntry == entry.id;
                              return Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        InkWell(
                                            onTap: () => setState(() =>
                                                _expandedEntry =
                                                    expanded ? null : entry.id),
                                            child: Row(children: [
                                              Icon(Icons.article_outlined,
                                                  color:
                                                      theme.colorScheme.primary,
                                                  size: 20),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                  child: Text(entry.title,
                                                      style: theme.textTheme
                                                          .titleSmall)),
                                              Icon(expanded
                                                  ? Icons.expand_less
                                                  : Icons.expand_more)
                                            ])),
                                        const SizedBox(height: 8),
                                        Wrap(
                                            spacing: 12,
                                            runSpacing: 4,
                                            children: [
                                              Text(
                                                  _categoryLabel(
                                                      entry.categoryId),
                                                  style: theme
                                                      .textTheme.labelSmall),
                                              Text(
                                                  entry.status == 'ACTIVE'
                                                      ? '已启用'
                                                      : '已停用',
                                                  style: theme
                                                      .textTheme.labelSmall
                                                      ?.copyWith(
                                                          color: entry.status ==
                                                                  'ACTIVE'
                                                              ? Colors.green
                                                              : theme
                                                                  .colorScheme
                                                                  .outline)),
                                              Text('检索命中 ${entry.hitCount} 次',
                                                  style: theme
                                                      .textTheme.labelSmall),
                                              if (entry.updatedAt != null)
                                                Text(
                                                    '更新 ${entry.updatedAt!.toLocal().toString().split(' ').first}',
                                                    style: theme
                                                        .textTheme.labelSmall)
                                            ]),
                                        const SizedBox(height: 8),
                                        if (expanded)
                                          SelectableText(entry.content)
                                        else
                                          Text(entry.content,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                      color: theme.colorScheme
                                                          .onSurfaceVariant)),
                                        if (expanded) ...[
                                          const SizedBox(height: 12),
                                          Text('相似问法',
                                              style:
                                                  theme.textTheme.labelMedium),
                                          const SizedBox(height: 6),
                                          if (entry.questionExamples.isEmpty)
                                            const Text('尚未填写相似问法，建议补充客户常用表达。'),
                                          Wrap(
                                              spacing: 6,
                                              runSpacing: 6,
                                              children: [
                                                for (final q
                                                    in entry.questionExamples)
                                                  ActionChip(
                                                      label: Text(q),
                                                      onPressed: () =>
                                                          _fillQuestion(q))
                                              ])
                                        ],
                                        Wrap(spacing: 6, children: [
                                          TextButton.icon(
                                              onPressed: () {
                                                setState(() =>
                                                    _expandedEntry = entry.id);
                                                _fillQuestion(entry.title);
                                              },
                                              icon: const Icon(
                                                  Icons.science_outlined,
                                                  size: 16),
                                              label: const Text('测试此知识')),
                                          if (canEdit) ...[
                                            TextButton(
                                                onPressed: () =>
                                                    _edit(existing: entry),
                                                child: const Text('编辑')),
                                            TextButton(
                                                onPressed: () =>
                                                    _toggleEntry(entry),
                                                child: Text(
                                                    entry.status == 'ACTIVE'
                                                        ? '停用'
                                                        : '启用')),
                                            IconButton(
                                                tooltip: '删除知识',
                                                onPressed: () => _delete(entry),
                                                icon: const Icon(
                                                    Icons.delete_outline,
                                                    size: 18))
                                          ]
                                        ])
                                      ]));
                            },
                          ),
          ),
        ],
      ),
    );
  }

  void _fillQuestion(String value) {
    if (_testing) return;
    _question.text = value;
    setState(() {
      _mobileBench = true;
      _hits = null;
      _answer = null;
      _testError = null;
    });
  }

  Widget _buildBench(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Center(child: TongYuArtwork(ai: true, size: 145)),
          const SizedBox(height: 10),
          Text('让好知识，遇见好答案。',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Icon(Icons.auto_awesome_outlined,
                  size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('AI 回答测试', style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '模拟真实提问，检查回答内容与知识来源。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _question,
            enabled: !_testing,
            onChanged: (_) => setState(() {
              _answer = null;
              _hits = null;
              _testError = null;
            }),
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              alignLabelWithHint: true,
              filled: true,
              labelText: '模拟客户提问',
              hintText: '例如：网站嵌入支持手机访问吗？',
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _testing ? null : _runRetrieval,
                icon: const Icon(Icons.search, size: 18),
                label: const Text('仅检索'),
              ),
              FilledButton.icon(
                onPressed: _testing || !widget.canAI ? null : _runAnswer,
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
          const SizedBox(height: 8),
          Text(
              widget.canAI
                  ? '仅检索不会调用模型；生成回答会使用 AI 额度。'
                  : '当前套餐未开放 AI 生成，可以使用知识检索。',
              style: theme.textTheme.labelSmall),
          if (_testHistory.isNotEmpty)
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (final q in _testHistory)
                ActionChip(
                    label: Text(q),
                    onPressed: _testing ? null : () => _fillQuestion(q))
            ]),
          if (_hits == null && !_testing && _answer == null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 20),
              padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
              decoration: BoxDecoration(
                  color:
                      theme.colorScheme.surfaceContainerHighest.withAlpha(65),
                  borderRadius: BorderRadius.circular(16)),
              child: Column(children: [
                Icon(Icons.chat_bubble_outline,
                    size: 28, color: theme.colorScheme.outline),
                const SizedBox(height: 12),
                Text('测试结果将显示在这里', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                const Text('查看回答内容、引用来源和转人工判断。', textAlign: TextAlign.center)
              ]),
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
                _answer!.answer.isEmpty
                    ? aiReasonLabel(_answer!.reason)
                    : _answer!.answer,
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
                    label: Text(aiReasonLabel(_answer!.reason)),
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
                    color:
                        theme.colorScheme.surfaceContainerHighest.withAlpha(90),
                    borderRadius: BorderRadius.circular(16),
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
                            '相关度 ${hit.score.toStringAsFixed(2)}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        hit.content,
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
    this.categoryId = '',
    required this.content,
    required this.examples,
  });

  final String title, categoryId;
  final String content;
  final List<String> examples;
}

class _KnowledgeDialog extends StatefulWidget {
  const _KnowledgeDialog(
      {this.existing,
      this.initialQuestion = '',
      required this.onSave,
      required this.categories});
  final String initialQuestion;
  final List<Map<String, dynamic>> categories;
  final Future<void> Function(_KnowledgeDraft) onSave;

  final KnowledgeEntry? existing;

  @override
  State<_KnowledgeDialog> createState() => _KnowledgeDialogState();
}

class _KnowledgeDialogState extends State<_KnowledgeDialog> {
  bool _busy = false;
  String? _error;
  late String _category = widget.existing?.categoryId ?? '';
  late final TextEditingController _title;
  late final TextEditingController _content;
  late final TextEditingController _examples;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(
        text: widget.existing?.title ?? widget.initialQuestion);
    _content = TextEditingController(text: widget.existing?.content ?? '');
    _examples = TextEditingController(
      text: widget.existing == null
          ? widget.initialQuestion
          : widget.existing!.questionExamples.join('\n'),
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
              if (_error != null)
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              DropdownButtonFormField<String>(
                  value: widget.categories.any((c) => c['id'] == _category)
                      ? _category
                      : '',
                  decoration: const InputDecoration(labelText: '知识分类'),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('未分类')),
                    for (final c in widget.categories)
                      DropdownMenuItem(
                          value: c['id'].toString(),
                          child: Text(c['name'].toString()))
                  ],
                  onChanged: (v) => setState(() => _category = v ?? '')),
              const SizedBox(height: 12),
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
                '标题在同一个企业内唯一，重复标题请编辑原条目。',
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
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  final title = _title.text.trim();
                  final content = _content.text.trim();
                  if (title.isEmpty || content.isEmpty) {
                    setState(() => _error = "请填写标题和内容");
                    return;
                  }
                  setState(() {
                    _busy = true;
                    _error = null;
                  });
                  try {
                    await widget.onSave(
                      _KnowledgeDraft(
                        title: title,
                        categoryId: _category,
                        content: content,
                        examples: _examples.text
                            .split('\n')
                            .map((line) => line.trim())
                            .where((line) => line.isNotEmpty)
                            .toList(growable: false),
                      ),
                    );
                    if (mounted) Navigator.of(context).pop(true);
                  } catch (e) {
                    if (mounted)
                      setState(() {
                        _busy = false;
                        _error = '保存失败，请修改后重试：$e';
                      });
                  }
                },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
