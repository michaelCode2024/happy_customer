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
    final canManageCategories =
        widget.session.agent?.canManageKnowledge ?? false;
    final saved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _KnowledgeDialog(
            existing: existing,
            initialQuestion: initialQuestion,
            categories: categories,
            // 无分类时引导到「分类与批量导入」；关闭弹窗再切页签，避免叠层。
            onManageCategories: canManageCategories
                ? () {
                    Navigator.of(context).pop(false);
                    setState(() => _tab = 1);
                  }
                : null,
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
        backgroundColor: Theme.of(context).brightness == Brightness.dark ? Theme.of(context).scaffoldBackgroundColor : const Color(0xFFEEF2FB),
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
            WorkspaceTabs(
                labels: ['知识管理', if (canEdit) '分类与批量导入', if (canEdit) '未解决问题'],
                selectedIndex: _tab,
                onSelected: (index) {
                  setState(() => _tab = index);
                  if (index == 0) _load();
                }),
            if (_tab == 0) _compactFilterAndMetricsBar(theme),
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
                                crossAxisAlignment: CrossAxisAlignment.stretch,
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
          return content;
        }));
  }

  Widget _compactFilterAndMetricsBar(ThemeData theme) {
    final activeCount = _entries.where((e) => e.status == 'ACTIVE').length;
    final gapCount = _entries.where((e) => e.questionExamples.isEmpty).length;
    final totalCount = _entries.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
      child: LayoutBuilder(builder: (context, box) {
        final isNarrow = box.maxWidth < 800;

        final categoryChips = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _filterChip(
                theme: theme,
                label: '全部',
                count: totalCount,
                selected: _categoryFilter.isEmpty,
                onTap: () => setState(() => _categoryFilter = ''),
              ),
              for (final c in _categories) ...[
                const SizedBox(width: 8),
                _filterChip(
                  theme: theme,
                  label: asString(c['name']),
                  count: _entries
                      .where((e) => e.categoryId == asString(c['id']))
                      .length,
                  selected: _categoryFilter == asString(c['id']),
                  onTap: () {
                    final id = asString(c['id']);
                    setState(() =>
                        _categoryFilter = _categoryFilter == id ? '' : id);
                  },
                ),
              ],
              if (_entries.any((e) => e.categoryId.isEmpty)) ...[
                const SizedBox(width: 8),
                _filterChip(
                  theme: theme,
                  label: '未分类',
                  count: _entries.where((e) => e.categoryId.isEmpty).length,
                  selected: _categoryFilter == 'uncategorized',
                  onTap: () => setState(() => _categoryFilter =
                      _categoryFilter == 'uncategorized'
                          ? ''
                          : 'uncategorized'),
                ),
              ],
            ],
          ),
        );

        final miniMetrics = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFA5D6A7)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle_outline,
                      size: 11, color: Color(0xFF2E7D32)),
                  const SizedBox(width: 3),
                  Text(
                    '$activeCount',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF2E7D32),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: gapCount > 0
                    ? const Color(0xFFFFF3E0)
                    : theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: gapCount > 0
                      ? const Color(0xFFFFCC80)
                      : theme.colorScheme.outlineVariant,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    gapCount > 0
                        ? Icons.warning_amber_rounded
                        : Icons.edit_note_outlined,
                    size: 11,
                    color: gapCount > 0
                        ? const Color(0xFFE65100)
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '$gapCount',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: gapCount > 0
                          ? const Color(0xFFE65100)
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );

        if (isNarrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              categoryChips,
              const SizedBox(height: 6),
              miniMetrics,
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: categoryChips),
            const SizedBox(width: 12),
            miniMetrics,
          ],
        );
      }),
    );
  }

  Widget _filterChip({
    required ThemeData theme,
    required String label,
    required int count,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = theme.colorScheme;
    return Material(
      color:
          selected ? scheme.primary.withValues(alpha: 0.1) : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.4 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? scheme.primary : scheme.onSurface,
                ),
              ),
              const SizedBox(width: 5),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 0.5),
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primary.withValues(alpha: 0.18)
                      : scheme.onSurface.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color:
                        selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(ThemeData theme, bool canEdit) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          // 窄屏把标题与搜索/状态下拉拆成两行，避免固定宽搜索框把 Row 挤爆。
          LayoutBuilder(builder: (context, headerBox) {
            final stackTools = headerBox.maxWidth < 520;
            final titleRow = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(Icons.article_outlined,
                      size: 14, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 8),
                Text(
                  '知识条目',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                WorkspaceTag(text: '${_visibleEntries.length} 条'),
                if (!canEdit) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: '只读权限 · 点击条目可查看全文与测试',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.info_outline,
                            size: 13,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 3),
                        Text(
                          '只读',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            );
            final searchField = TextField(
              controller: _search,
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                hintText: '搜索标题或内容',
                hintStyle: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.7),
                ),
                prefixIcon: const Icon(Icons.search_rounded, size: 15),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
                suffixIcon: _search.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded, size: 14),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        onPressed: () {
                          _search.clear();
                          _load();
                        },
                      )
                    : null,
                suffixIconConstraints:
                    const BoxConstraints(minWidth: 26, minHeight: 26),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide:
                      BorderSide(color: theme.colorScheme.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(7),
                  borderSide:
                      BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              onSubmitted: (_) => _load(),
            );
            final statusDropdown = SizedBox(
              height: 32,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _statusFilter,
                    isDense: true,
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
                    icon: const Icon(Icons.arrow_drop_down, size: 18),
                    items: const [
                      DropdownMenuItem(value: '', child: Text('全部状态')),
                      DropdownMenuItem(
                          value: 'ACTIVE', child: Text('已启用')),
                      DropdownMenuItem(
                          value: 'DISABLED', child: Text('已停用')),
                    ],
                    onChanged: (v) =>
                        setState(() => _statusFilter = v ?? ''),
                  ),
                ),
              ),
            );
            final toolsRow = Row(
              children: [
                Expanded(
                  child: SizedBox(height: 32, child: searchField),
                ),
                const SizedBox(width: 8),
                statusDropdown,
              ],
            );
            return Container(
              padding: EdgeInsets.fromLTRB(14, 8, 14, stackTools ? 10 : 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.outlineVariant
                        .withValues(alpha: 0.7),
                  ),
                ),
              ),
              child: stackTools
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        titleRow,
                        const SizedBox(height: 8),
                        toolsRow,
                      ],
                    )
                  : Row(
                      children: [
                        titleRow,
                        const SizedBox(width: 12),
                        const Spacer(),
                        SizedBox(
                          width: 170,
                          height: 32,
                          child: searchField,
                        ),
                        const SizedBox(width: 8),
                        statusDropdown,
                      ],
                    ),
            );
          }),
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
                        ? const WorkspaceEmptyState(
                            icon: Icons.menu_book_outlined,
                            title: '还没有知识条目',
                            description: '添加产品说明和常见问答，作为 AI 推荐回复的参考。',
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                            itemCount: _visibleEntries.length,
                            separatorBuilder: (_, __) =>
                                Divider(height: 1, color: theme.colorScheme.outlineVariant.withOpacity(.7)),
                            itemBuilder: (context, index) {
                              final entry = _visibleEntries[index];
                              final expanded = _expandedEntry == entry.id;
                              return Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      10, 10, 10, 8),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        InkWell(
                                            borderRadius:
                                                BorderRadius.circular(6),
                                            onTap: () => setState(() =>
                                                _expandedEntry =
                                                    expanded ? null : entry.id),
                                            child: Row(children: [
                                              Container(
                                                width: 26,
                                                height: 26,
                                                decoration: BoxDecoration(
                                                    color: theme.colorScheme
                                                        .primary
                                                        .withOpacity(.07),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            7)),
                                                child: Icon(
                                                    Icons.article_outlined,
                                                    color: theme
                                                        .colorScheme.primary,
                                                    size: 14),
                                              ),
                                              const SizedBox(width: 9),
                                              Expanded(
                                                  child: Text(entry.title,
                                                      maxLines: 1,
                                                      overflow: TextOverflow
                                                          .ellipsis,
                                                      style: theme.textTheme
                                                          .titleSmall
                                                          ?.copyWith(
                                                              fontSize: 13))),
                                              WorkspaceTag(
                                                text: entry.status == 'ACTIVE'
                                                    ? '已启用'
                                                    : '已停用',
                                                tone: entry.status == 'ACTIVE'
                                                    ? const Color(0xFF31977C)
                                                    : theme.colorScheme.outline,
                                                dense: true,
                                              ),
                                              const SizedBox(width: 4),
                                              Icon(
                                                  expanded
                                                      ? Icons.expand_less_rounded
                                                      : Icons.expand_more_rounded,
                                                  size: 18,
                                                  color: theme.colorScheme
                                                      .onSurfaceVariant)
                                            ])),
                                        const SizedBox(height: 5),
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(left: 35),
                                          child: Wrap(
                                              spacing: 10,
                                              runSpacing: 3,
                                              children: [
                                                Text(
                                                    _categoryLabel(
                                                        entry.categoryId),
                                                    style: theme.textTheme
                                                        .labelSmall
                                                        ?.copyWith(
                                                            fontSize: 10.5,
                                                            color: theme
                                                                .colorScheme
                                                                .onSurfaceVariant)),
                                                Text(
                                                    '检索命中 ${entry.hitCount} 次',
                                                    style: theme.textTheme
                                                        .labelSmall
                                                        ?.copyWith(
                                                            fontSize: 10.5,
                                                            color: theme
                                                                .colorScheme
                                                                .onSurfaceVariant)),
                                                if (entry.updatedAt != null)
                                                  Text(
                                                      '更新 ${entry.updatedAt!.toLocal().toString().split(' ').first}',
                                                      style: theme.textTheme
                                                          .labelSmall
                                                          ?.copyWith(
                                                              fontSize: 10.5,
                                                              color: theme
                                                                  .colorScheme
                                                                  .onSurfaceVariant))
                                              ]),
                                        ),
                                        const SizedBox(height: 6),
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(left: 35),
                                          child: expanded
                                              ? SelectableText(entry.content,
                                                  style: const TextStyle(
                                                      fontSize: 12.5,
                                                      height: 1.6))
                                              : Text(entry.content,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      color: theme.colorScheme
                                                          .onSurfaceVariant)),
                                        ),
                                        if (expanded) ...[
                                          const SizedBox(height: 10),
                                          Padding(
                                            padding:
                                                const EdgeInsets.only(left: 35),
                                            child: Text('相似问法',
                                                style: theme
                                                    .textTheme.labelMedium
                                                    ?.copyWith(fontSize: 11.5)),
                                          ),
                                          const SizedBox(height: 5),
                                          Padding(
                                            padding:
                                                const EdgeInsets.only(left: 35),
                                            child: entry.questionExamples.isEmpty
                                                ? const Text('尚未填写相似问法，建议补充客户常用表达。',
                                                    style: TextStyle(
                                                        fontSize: 12,
                                                        color: Color(
                                                            0xFF6B7A90)))
                                                : Wrap(
                                                    spacing: 5,
                                                    runSpacing: 5,
                                                    children: [
                                                      for (final q
                                                          in entry
                                                              .questionExamples)
                                                        ActionChip(
                                                            visualDensity:
                                                                VisualDensity
                                                                    .compact,
                                                            label: Text(q,
                                                                style: const TextStyle(
                                                                    fontSize:
                                                                        11)),
                                                            onPressed: () =>
                                                                _fillQuestion(
                                                                    q))
                                                    ]),
                                          )
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Center(child: TongYuArtwork(ai: true, size: 100)),
          const SizedBox(height: 8),
          Center(
            child: Text(
              '让好知识，遇见好答案。',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Icon(Icons.auto_awesome_outlined,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 7),
              Text('AI 回答测试',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '模拟真实提问，检查回答内容与知识来源。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11.5,
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
  const _KnowledgeDialog({
    this.existing,
    this.initialQuestion = '',
    required this.onSave,
    required this.categories,
    this.onManageCategories,
  });
  final String initialQuestion;
  final List<Map<String, dynamic>> categories;
  final Future<void> Function(_KnowledgeDraft) onSave;

  /// 企业尚无分类时，跳转到知识库「分类与批量导入」。
  final VoidCallback? onManageCategories;

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
              if (widget.categories.isEmpty) ...[
                const SizedBox(height: 6),
                if (widget.onManageCategories != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _busy ? null : widget.onManageCategories,
                      icon: const Icon(Icons.category_outlined, size: 16),
                      label: const Text('还没有分类，去添加'),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  )
                else
                  Text(
                    '还没有知识分类。分类由主管在知识库中添加。',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
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
