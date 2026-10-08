import 'dart:async';

import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/realtime/console_socket.dart';
import 'package:relaydesk_agent_console/src/state/session_controller.dart';
import 'package:relaydesk_agent_console/src/state/workbench_controller.dart';
import 'package:relaydesk_agent_console/src/ui/chat_panel.dart';
import 'package:relaydesk_agent_console/src/ui/conversation_list.dart';
import 'package:relaydesk_agent_console/src/ui/knowledge_page.dart';
import 'package:relaydesk_agent_console/src/ui/settings_page.dart';
import 'package:relaydesk_agent_console/src/ui/stats_page.dart';
import 'package:relaydesk_agent_console/src/ui/visitor_sidebar.dart';
import 'package:relaydesk_agent_console/src/util/attachment_picker.dart';
import 'package:relaydesk_agent_console/src/util/voice_player.dart';

/// The console's top-level sections.
enum WorkbenchSection { conversations, stats, knowledge, settings }

/// The signed-in shell: a rail of sections, the conversation queue, the open
/// thread and the customer record.
///
/// The layout is driven by width rather than by platform, because the same build
/// runs in a browser, on a desktop and on a phone. Three panes need genuine room
/// (a queue, a thread and a profile side by side), so the customer record only
/// sits inline on a wide window and becomes a pushed page below that; on a phone
/// even the queue and the thread take turns. Everything stays reachable at every
/// size, which is the property that matters — an agent on a phone during a
/// commute must not lose access to the customer's history.
class WorkbenchPage extends StatefulWidget {
  const WorkbenchPage({
    super.key,
    required this.session,
    this.picker,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
  });

  final SessionController session;

  /// Injectable so widget tests can drive the composer without a platform
  /// channel; production passes null and gets the real image picker.
  final AttachmentPicker? picker;

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends State<WorkbenchPage> {
  late final WorkbenchController _workbench;
  late final AttachmentPicker _picker;

  WorkbenchSection _section = WorkbenchSection.conversations;

  /// True while the customer record is open as a pushed page on a narrow window.
  bool _profileOpen = false;

  @override
  void initState() {
    super.initState();
    _workbench = WorkbenchController(
      api: widget.session.api,
      selfId: widget.session.agent?.id ?? '',
    );
    _picker = widget.picker ?? ImageAttachmentPicker();
    _workbench.connectRealtime();
    unawaited(_workbench.refreshConversations());
    unawaited(_workbench.loadReferenceData());
  }

  @override
  void dispose() {
    _workbench.dispose();
    // The player is a process-wide singleton, so it is released rather than
    // disposed: signing out and back in must not hand the new session a dead
    // audio backend.
    unawaited(VoicePlayer.instance.release());
    super.dispose();
  }

  /// Sections an agent may open. Reports and the knowledge base are gated on the
  /// role the server reported, and the server enforces the same rule, so hiding
  /// the entry point is a courtesy rather than the control.
  List<_SectionSpec> _sections(AgentProfile? agent) {
    final canReport = agent?.canViewReports ?? false;
    return <_SectionSpec>[
      const _SectionSpec(
        section: WorkbenchSection.conversations,
        label: '会话',
        icon: Icons.forum_outlined,
        selectedIcon: Icons.forum,
      ),
      if (canReport)
        const _SectionSpec(
          section: WorkbenchSection.stats,
          label: '统计',
          icon: Icons.insights_outlined,
          selectedIcon: Icons.insights,
        ),
      const _SectionSpec(
        section: WorkbenchSection.knowledge,
        label: '知识库',
        icon: Icons.menu_book_outlined,
        selectedIcon: Icons.menu_book,
      ),
      const _SectionSpec(
        section: WorkbenchSection.settings,
        label: '设置',
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final agent = widget.session.agent;
        final sections = _sections(agent);
        // A role change (or a stale stored session) can make the current section
        // illegal; falling back keeps the shell consistent with the rail.
        if (!sections.any((spec) => spec.section == _section)) {
          _section = WorkbenchSection.conversations;
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final useRail = width >= 900;
            final body = _bodyFor(width);
            if (!useRail) {
              return Scaffold(
                appBar: _compactAppBar(agent),
                body: body,
                bottomNavigationBar: NavigationBar(
                  selectedIndex:
                      sections.indexWhere((spec) => spec.section == _section),
                  onDestinationSelected: (index) =>
                      setState(() => _section = sections[index].section),
                  destinations: <Widget>[
                    for (final spec in sections)
                      NavigationDestination(
                        icon: Icon(spec.icon),
                        selectedIcon: Icon(spec.selectedIcon),
                        label: spec.label,
                      ),
                  ],
                ),
              );
            }
            final extended = width >= 1240;
            return Scaffold(
              body: Row(
                children: <Widget>[
                  NavigationRail(
                    extended: extended,
                    selectedIndex:
                        sections.indexWhere((spec) => spec.section == _section),
                    onDestinationSelected: (index) =>
                        setState(() => _section = sections[index].section),
                    leading: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: _RailLeading(agent: agent, extended: extended),
                    ),
                    trailing: Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _ConnectionBadge(workbench: _workbench),
                        ),
                      ),
                    ),
                    destinations: <NavigationRailDestination>[
                      for (final spec in sections)
                        NavigationRailDestination(
                          icon: Badge(
                            isLabelVisible: spec.section ==
                                    WorkbenchSection.conversations &&
                                _workbench.queued > 0,
                            label: Text('${_workbench.queued}'),
                            child: Icon(spec.icon),
                          ),
                          selectedIcon: Icon(spec.selectedIcon),
                          label: Text(spec.label),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: body),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _bodyFor(double width) {
    switch (_section) {
      case WorkbenchSection.stats:
        return StatsPage(session: widget.session, workbench: _workbench);
      case WorkbenchSection.knowledge:
        return KnowledgePage(session: widget.session, workbench: _workbench);
      case WorkbenchSection.settings:
        return SettingsPage(
          session: widget.session,
          themeMode: widget.themeMode,
          onThemeModeChanged: widget.onThemeModeChanged,
        );
      case WorkbenchSection.conversations:
        return _conversations(width);
    }
  }

  Widget _conversations(double width) {
    final list = ConversationListPanel(
      workbench: _workbench,
      session: widget.session,
    );
    // Three panes need genuine room. Below this the customer record is pushed on
    // top of the thread instead of shrinking it into uselessness.
    final inlineProfile = width >= 1400;
    final sideBySide = width >= 760;

    if (!sideBySide) {
      // Phone: the queue and the thread take turns, which is what the back
      // affordance in the thread's own app bar is for.
      return _CompactSwitch(
        workbench: _workbench,
        list: list,
        picker: _picker,
        session: widget.session,
      );
    }

    final chat = ChatPanel(
      workbench: _workbench,
      picker: _picker,
      onOpenProfile: inlineProfile ? null : () => _openProfile(),
    );

    return Row(
      children: <Widget>[
        SizedBox(
          width: width >= 1100 ? 340 : 300,
          child: list,
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _ProfileScope(
            open: !inlineProfile && _profileOpen,
            onClose: () => setState(() => _profileOpen = false),
            workbench: _workbench,
            child: chat,
          ),
        ),
        if (inlineProfile) ...<Widget>[
          const VerticalDivider(width: 1),
          SizedBox(
            width: 320,
            child: VisitorSidebar(workbench: _workbench),
          ),
        ],
      ],
    );
  }

  Future<void> _openProfile() async {
    setState(() => _profileOpen = true);
  }

  PreferredSizeWidget _compactAppBar(AgentProfile? agent) {
    if (_section == WorkbenchSection.conversations) {
      return AppBar(
        title: ListenableBuilder(
          listenable: _workbench,
          builder: (context, _) => Row(
            children: <Widget>[
              const Text('会话'),
              const SizedBox(width: 10),
              if (_workbench.queued > 0)
                Text(
                  '${_workbench.queued} 个待分配',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              const Spacer(),
              _ConnectionBadge(workbench: _workbench),
            ],
          ),
        ),
      );
    }
    return AppBar(title: Text(_sectionTitle(_section)));
  }

  static String _sectionTitle(WorkbenchSection section) => switch (section) {
        WorkbenchSection.conversations => '会话',
        WorkbenchSection.stats => '统计',
        WorkbenchSection.knowledge => '知识库',
        WorkbenchSection.settings => '设置',
      };
}

class _SectionSpec {
  const _SectionSpec({
    required this.section,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final WorkbenchSection section;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// The avatar and tenant name at the top of the rail.
class _RailLeading extends StatelessWidget {
  const _RailLeading({required this.agent, required this.extended});

  final AgentProfile? agent;
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = agent?.displayName ?? '';
    final avatar = CircleAvatar(
      radius: 18,
      backgroundColor: theme.colorScheme.primaryContainer,
      child: Text(
        name.isEmpty ? '?' : String.fromCharCode(name.runes.first),
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
    if (!extended) {
      return Tooltip(message: name.isEmpty ? '未登录' : name, child: avatar);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: <Widget>[
          avatar,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  name.isEmpty ? '未登录' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
                if (agent != null)
                  Text(
                    _roleLabel(agent!.role),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _roleLabel(String role) => switch (role) {
        'OWNER' => '企业所有者',
        'ADMIN' => '管理员',
        'SUPERVISOR' => '主管',
        'AGENT' => '客服坐席',
        _ => role,
      };
}

/// A small dot plus label describing the realtime channel.
///
/// It is shown permanently rather than only on failure: an agent needs to know
/// whether the console is live *before* they wonder why a message has not
/// arrived, and "connected" is information too.
class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.workbench});

  final WorkbenchController workbench;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: workbench,
      builder: (context, _) {
        final state = workbench.socketState;
        final (label, color, icon) = switch (state) {
          SocketState.open => ('已连接', Colors.green, Icons.bolt),
          SocketState.connecting => ('连接中', Colors.orange, Icons.sync),
          SocketState.closed => ('离线', theme.colorScheme.error, Icons.cloud_off),
        };
        return Tooltip(
          message: state == SocketState.open
              ? '实时通道已连接，新消息会立即出现'
              : '实时通道未连接，正在自动重试；期间仍可手动刷新',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// On a phone, shows the queue until a conversation is opened, then the thread.
class _CompactSwitch extends StatelessWidget {
  const _CompactSwitch({
    required this.workbench,
    required this.list,
    required this.picker,
    required this.session,
  });

  final WorkbenchController workbench;
  final Widget list;
  final AttachmentPicker picker;
  final SessionController session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: workbench,
      builder: (context, _) {
        final selected = workbench.selected;
        if (selected == null) {
          return list;
        }
        return ChatPanel(
          workbench: workbench,
          picker: picker,
          onOpenProfile: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (context) => VisitorSidebar(workbench: workbench),
            ),
          ),
        );
      },
    );
  }
}

/// Wraps the thread so the customer record can slide in over it on a medium
/// window without a route transition: the queue stays visible, which is the
/// whole point of the third pane on a laptop.
class _ProfileScope extends StatelessWidget {
  const _ProfileScope({
    required this.open,
    required this.onClose,
    required this.workbench,
    required this.child,
  });

  final bool open;
  final VoidCallback onClose;
  final WorkbenchController workbench;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!open) {
      return child;
    }
    return Stack(
      children: <Widget>[
        child,
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.scrim.withAlpha(60),
            child: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 336,
                child: Material(
                  elevation: 8,
                  child: Column(
                    children: <Widget>[
                      Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          tooltip: '关闭客户资料',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: onClose,
                        ),
                      ),
                      Expanded(child: VisitorSidebar(workbench: workbench)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
