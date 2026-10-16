import 'package:flutter/material.dart';
import 'package:tongyu_agent_console/src/util/labels.dart';
import 'package:tongyu_agent_console/src/api/tongyu_api.dart';
import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/ui/workspace_layout.dart';

/// 共用素材在企业内管理，消息编辑器使用同一份常用回复与标签数据。
class SupportAssetsPage extends StatefulWidget {
  const SupportAssetsPage(
      {super.key,
      required this.api,
      this.knowledge = false,
      this.embedded = false,
      this.initialKnowledgeTab = 0,
      this.onGapAdd,
      this.onGapTest});
  final TongYuApi api;
  final bool knowledge;
  final bool embedded;
  final int initialKnowledgeTab;
  final Future<bool> Function(String)? onGapAdd;
  final ValueChanged<String>? onGapTest;
  @override
  State<SupportAssetsPage> createState() => _SupportAssetsPageState();
}

class _SupportAssetsPageState extends State<SupportAssetsPage> {
  List<CannedResponse> _replies = [];
  List<TagInfo> _tags = [];
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _gaps = [];
  bool _loading = true;
  bool _showResolved = false;
  Map<String, dynamic> _feedback = {};
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.knowledge) {
        final values = await Future.wait([
          widget.api.adminGet('knowledge-categories'),
          widget.api.adminGet(
              'knowledge-gaps${_showResolved ? '?status=RESOLVED' : ''}'),
          widget.api.assistFeedbackSummary(),
        ]);
        if (!mounted) return;
        _categories = asMapList(values[0]['items']);
        _gaps = asMapList(values[1]['items']);
        _feedback = values[2];
      } else {
        final replies = await widget.api.cannedResponses();
        final tags = await widget.api.tags();
        if (!mounted) return;
        _replies = replies;
        _tags = tags;
      }
    } catch (error) {
      if (mounted) _error = '$error';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _edit(String kind,
      {String? id, String title = '', String content = ''}) async {
    final saved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _AssetEditor(
            kind: kind,
            title: title,
            content: content,
            onSave: (fields) async {
              if (kind == '常用回复') {
                if (id == null) {
                  await widget.api.createCannedResponse(
                      title: fields[0], content: fields[1]);
                } else {
                  await widget.api.updateCannedResponse(
                      id: id, title: fields[0], content: fields[1]);
                }
              } else if (kind == '标签') {
                await widget.api.adminWrite(
                    id == null ? 'POST' : 'PATCH',
                    id == null ? 'tags' : 'tags/$id',
                    {'name': fields[0], 'color': '#078579'});
              } else if (kind == '知识分类') {
                await widget.api.adminWrite('POST', 'knowledge-categories',
                    {'name': fields[0], 'sortOrder': 0});
              } else {
                final entries =
                    fields[1].split(RegExp(r'\n\s*---\s*\n')).map((block) {
                  final lines = block.trim().split('\n');
                  return {
                    'title': lines.first.trim(),
                    'content': lines.skip(1).join('\n').trim()
                  };
                }).toList();
                if (entries.any((entry) =>
                    entry['title']!.isEmpty || entry['content']!.isEmpty)) {
                  throw Exception('每条知识需要标题和正文，条目之间使用单独一行 --- 分隔。');
                }
                final result = await widget.api.adminWrite(
                    'POST',
                    'knowledge/import',
                    {'category': fields[0], 'entries': entries});
                _notice('知识导入成功：${result['imported'] ?? entries.length} 条');
              }
            }));
    if (saved == true && mounted) await _load();
  }

  Future<void> _delete(String kind, String id) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
                title: Text('删除$kind？'),
                content: const Text('删除后无法恢复，请确认不再需要。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确认删除'))
                ]));
    if (ok != true) return;
    try {
      if (kind == '常用回复') {
        await widget.api.deleteCannedResponse(id);
      } else {
        await widget.api.adminWrite('DELETE',
            kind == '标签' ? 'tags/$id' : 'knowledge-categories/$id', {});
      }
      await _load();
    } catch (error) {
      _notice('删除失败：$error');
    }
  }

  Widget _list(String title, String description, List<Widget> rows,
          VoidCallback create) =>
      ListView(padding: const EdgeInsets.all(24), children: [
        WorkspaceHeading(title, description),
        Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
                onPressed: create,
                icon: const Icon(Icons.add),
                label: Text('添加$title'))),
        const SizedBox(height: 20),
        if (rows.isEmpty)
          const Padding(
              padding: EdgeInsets.all(32), child: Text('暂无内容，添加后即可在团队中使用。'))
        else
          ...rows,
      ]);
  Widget _row(String kind, String id, String title, String content) => Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
          leading: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(
                  kind == '标签'
                      ? Icons.sell_outlined
                      : Icons.quickreply_outlined,
                  color: Theme.of(context).colorScheme.primary)),
          title: Text(title),
          subtitle: content.isEmpty
              ? null
              : Text(content, maxLines: 3, overflow: TextOverflow.ellipsis),
          trailing: PopupMenuButton<String>(
              tooltip: '管理$kind',
              onSelected: (value) => value == 'delete'
                  ? _delete(kind, id)
                  : _edit(kind, id: id, title: title, content: content),
              itemBuilder: (_) => [
                    if (kind != '知识分类')
                      const PopupMenuItem(value: 'edit', child: Text('编辑')),
                    const PopupMenuItem(value: 'delete', child: Text('删除'))
                  ])));
  // 嵌入知识库时由外层标签唯一控制正文，避免内外两组标签各选各的。
  Widget _content(List<Widget> pages) => widget.knowledge && widget.embedded
      ? Column(children: [
          Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                  tooltip: '刷新素材',
                  onPressed: _load,
                  icon: const Icon(Icons.refresh))),
          Expanded(child: pages[widget.initialKnowledgeTab]),
        ])
      : TabBarView(children: pages);

  @override
  Widget build(BuildContext context) => DefaultTabController(
      length: 2,
      initialIndex: widget.knowledge ? widget.initialKnowledgeTab : 0,
      child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: widget.knowledge && widget.embedded
              ? null
              : AppBar(
                  toolbarHeight: widget.embedded ? 0 : kToolbarHeight,
                  title: Text(widget.knowledge ? '知识运营' : '团队素材'),
                  actions: [
                    IconButton(
                        tooltip: '刷新',
                        onPressed: _load,
                        icon: const Icon(Icons.refresh))
                  ],
                  bottom: PreferredSize(
                    preferredSize: const Size.fromHeight(48),
                    child: Row(children: [
                      Expanded(
                          child: TabBar(
                              tabs: widget.knowledge
                                  ? const [
                                      Tab(text: '分类与导入'),
                                      Tab(text: '未解决问题')
                                    ]
                                  : const [
                                      Tab(text: '常用回复'),
                                      Tab(text: '会话标签')
                                    ])),
                      if (widget.embedded)
                        IconButton(
                            tooltip: '刷新素材',
                            onPressed: _load,
                            icon: const Icon(Icons.refresh)),
                    ]),
                  )),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!),
                      OutlinedButton(onPressed: _load, child: const Text('重试'))
                    ]))
                  : _content(widget.knowledge
                      ? [
                          ListView(
                              padding: const EdgeInsets.all(24),
                              children: [
                                const WorkspaceHeading(
                                    '分类与导入', '按业务整理知识，批量导入常见问题与答案'),
                                Wrap(spacing: 12, runSpacing: 12, children: [
                                  FilledButton.icon(
                                      onPressed: () => _edit('知识分类'),
                                      icon: const Icon(Icons.add),
                                      label: const Text('添加分类')),
                                  OutlinedButton.icon(
                                      onPressed: () => _edit('批量导入'),
                                      icon: const Icon(Icons.upload_outlined),
                                      label: const Text('批量导入知识'))
                                ]),
                                const SizedBox(height: 20),
                                for (final c in _categories)
                                  _row(
                                      '知识分类',
                                      asString(c['id']),
                                      asString(c['name']),
                                      '${c['entryCount'] ?? 0} 条知识')
                              ]),
                          ListView(
                              padding: const EdgeInsets.all(24),
                              children: [
                                const WorkspaceHeading(
                                    '未解决问题', '近 30 天未被 AI 解决的问题，帮助团队补充知识'),
                                Text(
                                    '近 30 天推荐回复：生成 ${_feedback['generated'] ?? 0} · 插入 ${_feedback['adopted'] ?? 0} · 已发送 ${_feedback['sent'] ?? 0} · 修改后发送 ${_feedback['edited'] ?? 0}'),
                                const SizedBox(height: 6),
                                Text(
                                    '客服反馈：有用 ${_feedback['helpful'] ?? 0} · 需改进 ${_feedback['needsWork'] ?? 0}。插入和发送均不代表问题已解决。'),
                                SwitchListTile(
                                    title: const Text('查看已补充知识的问题'),
                                    value: _showResolved,
                                    onChanged: (value) {
                                      setState(() => _showResolved = value);
                                      _load();
                                    }),
                                if (_gaps.isEmpty) const Text('当前列表暂无问题。'),
                                for (final gap in _gaps)
                                  Card(
                                      child: ListTile(
                                          title:
                                              Text(asString(gap['question'])),
                                          trailing: _showResolved
                                              ? TextButton(
                                                  onPressed: widget.onGapTest ==
                                                          null
                                                      ? null
                                                      : () => widget.onGapTest!(
                                                          asString(
                                                              gap['question'])),
                                                  child: const Text('验证检索'))
                                              : widget.onGapAdd == null
                                                  ? null
                                                  : TextButton(
                                                      onPressed: () async {
                                                        final saved = await widget
                                                                .onGapAdd!(
                                                            asString(gap[
                                                                'question']));
                                                        if (saved && mounted) {
                                                          _notice(
                                                              '知识已保存，原问题已关联。可在已补充列表验证检索。');
                                                          await _load();
                                                        }
                                                      },
                                                      child:
                                                          const Text('补充知识')),
                                          subtitle: Text(_showResolved
                                              ? '已补充：${gap['knowledgeTitle']} · 可验证是否命中'
                                              : '出现 ${gap['count']} 次 · ${aiReasonLabel(asString(gap['reason']))}')))
                              ]),
                        ]
                      : [
                          _list(
                              '常用回复',
                              '保存常见回答，在聊天输入框一键引用',
                              [
                                for (final reply in _replies)
                                  _row('常用回复', reply.id, reply.title,
                                      reply.content)
                              ],
                              () => _edit('常用回复')),
                          _list(
                              '会话标签',
                              '统一会话分类，方便团队筛选与跟进',
                              [
                                for (final tag in _tags)
                                  _row('标签', tag.id, tag.name, '')
                              ],
                              () => _edit('标签')),
                        ])));
}

class _AssetEditor extends StatefulWidget {
  const _AssetEditor(
      {required this.kind,
      this.title = '',
      this.content = '',
      required this.onSave});
  final String kind, title, content;
  final Future<void> Function(List<String>) onSave;
  @override
  State<_AssetEditor> createState() => _AssetEditorState();
}

class _AssetEditorState extends State<_AssetEditor> {
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;
  late final _title = TextEditingController(text: widget.title);
  late final _content = TextEditingController(text: widget.content);
  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.kind),
          content: SizedBox(
              width: 520,
              child: Form(
                  key: _form,
                  child: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (_error != null)
                      Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    TextFormField(
                        controller: _title,
                        decoration: InputDecoration(
                            labelText:
                                widget.kind == '批量导入' ? '分类名称（可选）' : '名称 / 标题'),
                        validator: (v) =>
                            widget.kind != '批量导入' && (v ?? '').trim().isEmpty
                                ? '请输入名称'
                                : null),
                    if (widget.kind == '常用回复' || widget.kind == '批量导入') ...[
                      const SizedBox(height: 16),
                      TextFormField(
                          controller: _content,
                          minLines: 5,
                          maxLines: 12,
                          decoration: InputDecoration(
                              labelText:
                                  widget.kind == '批量导入' ? '知识内容' : '回复内容',
                              hintText: widget.kind == '批量导入'
                                  ? '每条第一行为标题，后续为答案；条目用单独一行 --- 分隔。'
                                  : null),
                          validator: (v) =>
                              (v ?? '').trim().isEmpty ? '请输入内容' : null)
                    ],
                  ])))),
          actions: [
            TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: _busy
                    ? null
                    : () async {
                        if (!_form.currentState!.validate()) return;
                        setState(() {
                          _busy = true;
                          _error = null;
                        });
                        try {
                          await widget.onSave(
                              [_title.text.trim(), _content.text.trim()]);
                          if (mounted) Navigator.pop(context, true);
                        } catch (e) {
                          if (mounted)
                            setState(() {
                              _busy = false;
                              _error = '保存失败，请修改后重试：$e';
                            });
                        }
                      },
                child: const Text('保存'))
          ]);
}
