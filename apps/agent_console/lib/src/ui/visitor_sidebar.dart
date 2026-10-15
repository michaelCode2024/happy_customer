import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/state/workbench_controller.dart';
import 'package:relaydesk_agent_console/src/util/format.dart';
import 'package:relaydesk_agent_console/src/ui/error_banner.dart';
import 'package:relaydesk_agent_console/src/ui/ai_assist_panel.dart';

/// The right pane: everything known about the person on the other side.
///
/// Context is what turns a reply into a good reply, and it is exactly what a
/// chat widget cannot show. This panel deliberately leads with the facts an
/// agent needs to identify the customer (name, contact, source) and keeps notes
/// at the bottom, where they are read and written during the conversation.
class VisitorSidebar extends StatefulWidget {
  const VisitorSidebar({super.key, required this.workbench, this.onAdopt});

  final WorkbenchController workbench;
  final ValueChanged<String>? onAdopt;

  @override
  State<VisitorSidebar> createState() => _VisitorSidebarState();
}

class _VisitorSidebarState extends State<VisitorSidebar> {
  final _note = TextEditingController();
  final _displayName = TextEditingController();
  List<VisitorNote> _notes = const <VisitorNote>[];
  List<Conversation> _history = const <Conversation>[];
  VisitorProfile? _profile;
  int _loadRevision = 0;
  bool _loading = false;

  /// 右侧资料栏分页：0 客户资料，1 快捷回复，2 服务记录。和七鱼右栏一样，避免一屏从上滚到下。
  int _sideTab = 0;
  bool _savingNote = false;
  String? _loadedVisitorId;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    _displayName.dispose();
    super.dispose();
  }

  /// Loads the visitor record, notes and history whenever the open conversation
  /// changes to a different person.
  Future<void> _ensureLoaded(String visitorId) async {
    if (_loadedVisitorId == visitorId) {
      return;
    }
    final revision = ++_loadRevision;
    _loadedVisitorId = visitorId;
    _profile = null;
    _notes = const <VisitorNote>[];
    _history = const <Conversation>[];
    _loading = true;
    _error = null;
    try {
      final api = widget.workbench.api;
      final results = await Future.wait(<Future<Object>>[
        api.visitor(visitorId),
        api.notes(visitorId),
        api.visitorConversations(visitorId),
      ]);
      if (!mounted || revision != _loadRevision) {
        return;
      }
      setState(() {
        final profile = results[0] as VisitorProfile;
        // 使用完整客户接口返回的会话数，切换客户时忽略旧请求结果。
        _profile = profile;
        _displayName.text = profile.displayName;
        _notes = results[1] as List<VisitorNote>;
        _history = results[2] as List<Conversation>;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || revision != _loadRevision) {
        return;
      }
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _addNote() async {
    final content = _note.text.trim();
    final visitorId = _loadedVisitorId;
    if (content.isEmpty || visitorId == null || _savingNote) {
      return;
    }
    setState(() => _savingNote = true);
    try {
      final note = await widget.workbench.api.addNote(visitorId, content);
      if (!mounted) {
        return;
      }
      setState(() {
        _notes = <VisitorNote>[note, ..._notes];
        _note.clear();
        _savingNote = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '$error';
        _savingNote = false;
      });
    }
  }

  Future<void> _saveDisplayName() async {
    final visitorId = _loadedVisitorId;
    final name = _displayName.text.trim();
    if (visitorId == null || name.isEmpty) {
      return;
    }
    try {
      await widget.workbench.api
          .updateVisitor(id: visitorId, displayName: name);
      if (!mounted) {
        return;
      }
      setState(() {
        _loadedVisitorId = null;
        _profile = null;
      });
      await widget.workbench.refreshConversations(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('客户名称已更新')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.workbench,
      builder: (context, _) {
        final detailVisitor = widget.workbench.detail?.visitor;
        final visitor =
            _profile?.id == detailVisitor?.id ? _profile : detailVisitor;
        if (visitor == null) {
          return const Center(child: Text('暂无可用的客户资料'));
        }
        if (_loadedVisitorId != visitor.id) {
          // Loading is triggered from build so the panel is complete the moment
          // it appears, without the parent having to know this pane exists.
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _ensureLoaded(visitor.id),
          );
        }
        final scheme = Theme.of(context).colorScheme;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 44,
              decoration: BoxDecoration(
                border:
                    Border(bottom: BorderSide(color: scheme.outlineVariant)),
              ),
              child: Row(
                children: [
                  for (final entry in const [
                    (0, '资料'),
                    (1, '快捷'),
                    (2, '记录'),
                  ])
                    Expanded(
                      child: InkWell(
                        onTap: () => setState(() => _sideTab = entry.$1),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              entry.$2,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: _sideTab == entry.$1
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: _sideTab == entry.$1
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              height: 2,
                              width: _sideTab == entry.$1 ? 28 : 0,
                              color: scheme.primary,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
                children: <Widget>[
                  if (_sideTab == 0) ...[
                    _header(context, visitor),
                    if (widget.workbench.selected?.tags.isNotEmpty ??
                        false) ...[
                      const SizedBox(height: 12),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final tag in widget.workbench.selected!.tags)
                          Chip(
                              label: Text(tag),
                              visualDensity: VisualDensity.compact),
                      ]),
                    ],
                    const SizedBox(height: 16),
                    _facts(context, visitor),
                    if (visitor.attributes.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 18),
                      _sectionTitle(context, '自定义属性'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: <Widget>[
                          for (final entry in visitor.attributes.entries)
                            Chip(
                              label: Text(
                                '${entry.key}: ${_renderValue(entry.value)}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 18),
                    _sectionTitle(context, '显示名称'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _displayName,
                      decoration: InputDecoration(
                        labelText: '昵称',
                        suffixIcon: IconButton(
                          tooltip: '保存',
                          icon: const Icon(Icons.check),
                          onPressed: _saveDisplayName,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    _sectionTitle(context, '内部备注', count: _notes.length),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _note,
                      minLines: 2,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: '记录只有同事可见的信息：订单号、承诺、投诉背景…',
                        suffixIcon: IconButton(
                          tooltip: '添加备注',
                          icon: _savingNote
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.add_comment_outlined),
                          onPressed: _addNote,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _error!,
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                        ),
                      ),
                    if (_loading && _notes.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                    for (final note in _notes) _NoteRow(note: note),
                  ],
                  if (_sideTab == 1) ...[
                    if (widget.workbench.cannedForSelection.isEmpty &&
                        (widget.onAdopt == null ||
                            widget.workbench.messages.isEmpty))
                      Text(
                        '暂无快捷回复',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    for (final reply in widget.workbench.cannedForSelection)
                      Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            title: Text(reply.content,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall),
                            trailing: IconButton(
                                tooltip: '复制快捷回复',
                                icon: const Icon(Icons.copy_outlined, size: 16),
                                onPressed: () => copyToClipboard(
                                    context, reply.content, '快捷回复')),
                          )),
                    if (widget.onAdopt != null &&
                        widget.workbench.messages.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: AiAssistPanel(
                          api: widget.workbench.api,
                          conversationId: widget.workbench.selected!.id,
                          messages: widget.workbench.messages,
                          onAdopt: widget.onAdopt!,
                        ),
                      ),
                  ],
                  if (_sideTab == 2) ...[
                    _sectionTitle(context, '历史会话', count: _history.length),
                    const SizedBox(height: 8),
                    if (_history.isEmpty)
                      Text(
                        '暂无历史会话',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    for (final conversation in _history)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${relativeTime(conversation.lastMessageAt ?? conversation.createdAt)} · '
                          '${_statusLabel(conversation.status)}',
                        ),
                        onTap: conversation.id == widget.workbench.selectedId
                            ? null
                            : () => widget.workbench.select(conversation.id),
                        trailing: conversation.id == widget.workbench.selectedId
                            ? const Icon(Icons.arrow_left, size: 16)
                            : null,
                      ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _header(BuildContext context, VisitorProfile visitor) {
    final theme = Theme.of(context);
    return Column(children: [
      Container(
          width: 54,
          height: 54,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: HSLColor.fromAHSL(
                      1, avatarHue(visitor.id).toDouble(), .30, .92)
                  .toColor(),
              borderRadius: BorderRadius.circular(18)),
          child: Text(initials(visitor.label),
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: HSLColor.fromAHSL(
                          1, avatarHue(visitor.id).toDouble(), .24, .48)
                      .toColor()))),
      const SizedBox(height: 10),
      Text(visitor.label,
          textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      SelectableText(
          visitor.externalId.isEmpty
              ? '客户编号 · ${shortId(visitor.id)}'
              : 'ID · ${visitor.externalId}',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 14),
    ]);
  }

  Widget _facts(BuildContext context, VisitorProfile visitor) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: <Widget>[
          _factRow(context, Icons.mail_outline, '邮箱', visitor.email),
          _factRow(context, Icons.phone_outlined, '电话', visitor.phone),
          _factRow(
            context,
            Icons.schedule_outlined,
            '最后活跃',
            relativeTime(visitor.lastSeenAt),
          ),
          _factRow(
            context,
            Icons.forum_outlined,
            '会话数',
            '${visitor.conversationCount}',
          ),
          _factRow(
            context,
            Icons.star_outline,
            '平均评分',
            visitor.ratingAverage == null
                ? '暂无'
                : visitor.ratingAverage!.toStringAsFixed(1),
          ),
        ],
      ),
    );
  }

  Widget _factRow(
      BuildContext context, IconData icon, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 15, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '—' : value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title, {int? count}) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Text(
          title,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (count != null && count > 0) ...<Widget>[
          const SizedBox(width: 6),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  /// Renders a JSON attribute value without assuming its shape: tenant-defined
  /// attributes are arbitrary, and a nested object still has to render.
  static String _renderValue(Object? value) {
    if (value == null) {
      return '—';
    }
    if (value is String || value is num || value is bool) {
      return '$value';
    }
    if (value is List) {
      return value.map(_renderValue).join('、');
    }
    if (value is Map) {
      return value.entries
          .map((entry) => '${entry.key}=${_renderValue(entry.value)}')
          .join(', ');
    }
    return '$value';
  }

  static String _statusLabel(String status) => switch (status) {
        'OPEN' => '进行中',
        'PENDING' => '等待中',
        'RESOLVED' => '已解决',
        _ => status,
      };
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.note});

  final VisitorNote note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                note.authorName.isEmpty ? '同事' : note.authorName,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                relativeTime(note.createdAt),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          SelectableText(note.content, style: theme.textTheme.bodySmall),
          const SizedBox(height: 6),
          Divider(
              height: 1,
              color: theme.colorScheme.outlineVariant.withAlpha(120)),
        ],
      ),
    );
  }
}
