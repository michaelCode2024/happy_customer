import 'pwa_panel.dart';
import 'package:tongyu_agent_console/src/util/host_session.dart';
import '../util/message_alert_stub.dart'
    if (dart.library.html) '../util/message_alert_web.dart';
import 'package:tongyu_agent_console/src/util/group_window_stub.dart'
    if (dart.library.html) 'package:tongyu_agent_console/src/util/group_window_web.dart';
import 'package:tongyu_agent_console/src/ui/groups_page.dart';
import 'notification_center.dart';
import '../util/push_bridge_stub.dart'
    if (dart.library.html) '../util/push_bridge_web.dart';
import '../util/website.dart';
import 'dart:async';
import 'package:tongyu_agent_console/src/ui/overview_page.dart';
import 'package:tongyu_agent_console/src/ui/brand.dart';

import 'package:flutter/material.dart';

import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/realtime/console_socket.dart';
import 'package:tongyu_agent_console/src/state/session_controller.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/ui/chat_panel.dart';
import 'package:tongyu_agent_console/src/ui/conversation_list.dart';
import 'package:tongyu_agent_console/src/ui/reception_guidance.dart';
import 'package:tongyu_agent_console/src/ui/integration_page.dart';
import 'package:tongyu_agent_console/src/ui/knowledge_page.dart';
import 'package:tongyu_agent_console/src/ui/settings_page.dart';
import 'package:tongyu_agent_console/src/ui/tenant_admin_page.dart';
import 'package:tongyu_agent_console/src/ui/stats_page.dart';
import 'package:tongyu_agent_console/src/ui/visitor_sidebar.dart';
import 'package:tongyu_agent_console/src/ui/conversation_context_panel.dart';
import 'package:tongyu_agent_console/src/util/attachment_picker.dart';
import 'package:tongyu_agent_console/src/util/voice_player.dart';

/// The console's top-level sections.
enum WorkbenchSection {
  overview,
  conversations,
  groups,
  stats,
  knowledge,
  integrations,
  enterprise,
  settings
}

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

  /// 登录后直接进客户消息，避免首页绕一圈才开始干活。
  WorkbenchSection _section = WorkbenchSection.conversations;

  /// True while the customer record is open as a pushed page on a narrow window.
  bool _profileOpen = false;
  final _assistDraft = ValueNotifier<AssistResult?>(null);
  Timer? _planRefresh;
  StreamSubscription<String>? _notificationNavigation;
  Map<String, dynamic> _features = {};
  bool _loadingPlan = false;
  Future<void> _refreshPlan() async {
    if (_loadingPlan) return;
    _loadingPlan = true;
    try {
      final result = await widget.session.api.entitlements();
      if (mounted)
        setState(() =>
            _features = Map<String, dynamic>.from(result['features'] as Map));
    } catch (_) {
      // The API rechecks the plan on every protected operation.
    } finally {
      _loadingPlan = false;
    }
  }

  bool _has(String feature) => _features[feature] == true;

  @override
  void initState() {
    super.initState();
    initializeMessageAlerts();
    _notificationNavigation = notificationConversationEvents().listen((id) {
      if (mounted && RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id))
        _openNotificationConversation(id);
    });
    _workbench = WorkbenchController(
      api: widget.session.api,
      selfId: widget.session.agent?.id ?? '',
    );
    _picker = widget.picker ?? ImageAttachmentPicker();
    unawaited(_refreshPlan());
    _planRefresh =
        Timer.periodic(const Duration(seconds: 5), (_) => _refreshPlan());
    _workbench.onGroupUpdated = checkIncomingCall;
    _workbench.connectRealtime();
    unawaited(_openInitialConversation());
    unawaited(_workbench.loadReferenceData());
  }

  Future<void> _openInitialConversation() async {
    await _workbench.refreshConversations();
    final id = hostConversationId ?? await initialNotificationConversation();
    if (mounted && id != null) await _workbench.select(id);
  }

  void _openNotificationConversation(String id) {
    setState(() => _section = WorkbenchSection.conversations);
    unawaited(_workbench.select(id));
  }

  final Set<String> noticedCalls = {};
  bool incomingDialog = false;
  Future<void> checkIncomingCall(String id) async {
    if (!_has('groups') || incomingDialog || groupCallPanelIsOpen || !mounted)
      return;
    try {
      final response =
          await widget.session.api.groupRequest('GET', '/$id/calls');
      if (groupCallPanelIsOpen || !mounted) return;
      final calls = (response['items'] as List).cast<Map<String, dynamic>>();
      for (final call in calls) {
        if (call['state'] != 'RINGING' ||
            call['recipientKind'] != 'agent' ||
            call['recipientId'] != widget.session.agent?.id ||
            noticedCalls.contains(call['id'])) {
          continue;
        }
        noticedCalls.add(call['id'] as String);
        incomingDialog = true;
        if (!mounted) return;
        await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
                    title: const Text('语音来电'),
                    content: Text('${call['callerName']} 邀请你进行语音通话'),
                    actions: [
                      TextButton(
                          onPressed: () async {
                            try {
                              await widget.session.api.groupRequest(
                                  'POST', '/$id/calls/${call['id']}',
                                  body: {'action': 'decline'});
                              if (ctx.mounted) Navigator.pop(ctx);
                            } catch (e) {
                              if (mounted)
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(e.toString())));
                            }
                          },
                          child: const Text('拒接')),
                      FilledButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _openGroupCall(id);
                          },
                          child: const Text('打开通话'))
                    ]));
        incomingDialog = false;
        return;
      }
      final conference =
          await widget.session.api.groupRequest('GET', '/$id/rooms');
      if (!mounted || groupCallPanelIsOpen) return;
      final room = conference['room'] as Map<String, dynamic>?;
      if (room != null && noticedCalls.add('room-${room['id']}')) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(room['mediaKind'] == 'VIDEO' ? '群视频通话已发起' : '群语音通话已发起'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
              label: '打开通话', onPressed: () => _openGroupCall(id)),
        ));
      }
    } catch (_) {
      incomingDialog = false;
    }
  }

  void _openGroupCall(String id) {
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => Dialog(
            insetPadding: const EdgeInsets.all(12),
            child: SizedBox(
                width: 900,
                height: 720,
                child: Column(children: [
                  Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      child: Row(children: [
                        const Expanded(
                            child: Text('群聊与音视频通话',
                                style: TextStyle(fontWeight: FontWeight.w600))),
                        IconButton(
                            tooltip: '关闭通话面板',
                            onPressed: () => Navigator.pop(ctx),
                            icon: const Icon(Icons.close))
                      ])),
                  Expanded(
                      child: groupCallPanel(id, widget.session.api.token,
                          widget.session.agent!.id))
                ]))));
  }

  @override
  void dispose() {
    _notificationNavigation?.cancel();
    _planRefresh?.cancel();
    _assistDraft.dispose();
    _workbench.dispose();
    // The player is a process-wide singleton, so it is released rather than
    // disposed: signing out and back in must not hand the new session a dead
    // audio backend.
    unawaited(VoicePlayer.instance.release());
    super.dispose();
  }

  /// 菜单按「接待 → 开通 → 账号」分组，文案用白话，避免一排看不懂的功能名。
  List<_SectionSpec> _sections(AgentProfile? agent) {
    final canReport = agent?.canViewReports ?? false;
    final admin = agent?.role == 'SUPERVISOR';
    return <_SectionSpec>[
      const _SectionSpec(
        section: WorkbenchSection.conversations,
        label: '客户消息',
        group: '日常接待',
        icon: Icons.forum_outlined,
        selectedIcon: Icons.forum,
      ),
      if (_has('groups'))
        const _SectionSpec(
          section: WorkbenchSection.groups,
          label: '群聊',
          group: '日常接待',
          icon: Icons.groups_outlined,
          selectedIcon: Icons.groups,
        ),
      const _SectionSpec(
        section: WorkbenchSection.overview,
        label: '工作概览',
        group: '日常接待',
        icon: Icons.home_outlined,
        selectedIcon: Icons.home_rounded,
      ),
      const _SectionSpec(
        section: WorkbenchSection.knowledge,
        label: '知识库',
        group: '日常接待',
        icon: Icons.menu_book_outlined,
        selectedIcon: Icons.menu_book,
      ),
      if (canReport)
        const _SectionSpec(
          section: WorkbenchSection.stats,
          label: '数据统计',
          group: '日常接待',
          icon: Icons.insights_outlined,
          selectedIcon: Icons.insights,
        ),
      if (admin && _has('integrations'))
        const _SectionSpec(
          section: WorkbenchSection.integrations,
          label: '接入管理',
          group: '企业管理',
          icon: Icons.code_rounded,
          selectedIcon: Icons.code,
        ),
      if (admin)
        const _SectionSpec(
          section: WorkbenchSection.enterprise,
          label: '企业管理',
          group: '企业管理',
          icon: Icons.people_outline,
          selectedIcon: Icons.people,
        ),
      const _SectionSpec(
        section: WorkbenchSection.settings,
        label: '个人设置',
        group: '个人设置',
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
      ),
    ];
  }

  /// 手机底栏只留 3～4 个主入口，其余进「更多」，避免十几个 Tab 挤成一团。
  List<_SectionSpec> _phoneDestinations(List<_SectionSpec> sections) {
    final primary = <WorkbenchSection>[
      WorkbenchSection.conversations,
      if (sections.any((s) => s.section == WorkbenchSection.groups))
        WorkbenchSection.groups,
      WorkbenchSection.overview,
    ];
    return [
      for (final section in primary)
        sections.firstWhere((s) => s.section == section),
    ];
  }

  Future<void> _openMoreSections(List<_SectionSpec> sections) async {
    final extras = sections
        .where((s) =>
            s.section != WorkbenchSection.conversations &&
            s.section != WorkbenchSection.groups &&
            s.section != WorkbenchSection.overview)
        .toList();
    if (extras.isEmpty) return;
    final picked = await showModalBottomSheet<WorkbenchSection>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  '更多功能',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              for (final spec in extras)
                ListTile(
                  leading: Icon(spec.icon, color: scheme.primary),
                  title: Text(spec.label),
                  subtitle: Text(
                    spec.group,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  onTap: () => Navigator.pop(ctx, spec.section),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (picked != null && mounted) {
      setState(() => _section = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.session, _workbench]),
      builder: (context, _) {
        _workbench.readingThread = _section == WorkbenchSection.conversations;
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
            // 传递实际剩余宽度，避免展开侧栏后仍按整屏宽度强行显示客户资料。
            final content = ReceptionGuidance(
              workbench: _workbench,
              onShowQueue: () {
                setState(() => _section = WorkbenchSection.conversations);
                if (width < 980) _workbench.clearSelection();
                unawaited(_workbench.showReceptionQueue());
              },
              onOpen: (conversation) {
                setState(() => _section = WorkbenchSection.conversations);
                _workbench.dismissReceptionNotice();
                unawaited(_workbench.select(conversation.id));
              },
              // 图标轨固定 72。接待区铺满剩余宽度，不再套一层圆角留白。
              child: _bodyFor(useRail ? width - 72 : width),
            );
            final body = Column(children: [
              if (!isHostedConsole)
                PwaPanel(
                    api: widget.session.api,
                    onReconnect: () async {
                      await _workbench.refreshConversations();
                      await _workbench.reloadSelected();
                    }),
              Expanded(child: content),
            ]);
            if (!useRail) {
              // 彩站宿主已有消息页和底部导航；打开会话时让出空间显示消息历史。
              final hostedThread = isHostedConsole &&
                  _section == WorkbenchSection.conversations &&
                  _workbench.selectedId != null;
              final phone = _phoneDestinations(sections);
              final phoneIndex =
                  phone.indexWhere((spec) => spec.section == _section);
              return Scaffold(
                // 这两个页面已有自己的工具栏，窄屏不再重复占用一行标题。
                appBar:
                    hostedThread || _section != WorkbenchSection.conversations
                        ? null
                        : _compactAppBar(agent),
                body: body,
                bottomNavigationBar: hostedThread
                    ? null
                    : NavigationBar(
                        selectedIndex:
                            phoneIndex >= 0 ? phoneIndex : phone.length,
                        onDestinationSelected: (index) {
                          if (index >= phone.length) {
                            unawaited(_openMoreSections(sections));
                            return;
                          }
                          setState(() => _section = phone[index].section);
                        },
                        destinations: <Widget>[
                          for (final spec in phone)
                            NavigationDestination(
                              icon: Icon(spec.icon),
                              selectedIcon: Icon(spec.selectedIcon),
                              label: spec.label,
                            ),
                          const NavigationDestination(
                            icon: Icon(Icons.more_horiz),
                            selectedIcon: Icon(Icons.more_horiz),
                            label: '更多',
                          ),
                        ],
                      ),
              );
            }
            return Scaffold(
              body: Row(children: [
                ListenableBuilder(
                    listenable: _workbench,
                    builder: (context, _) => ConsoleIconRail(
                          selectedIndex: sections
                              .indexWhere((spec) => spec.section == _section),
                          onSelected: (index) => setState(
                              () => _section = sections[index].section),
                          items: [
                            for (final spec in sections)
                              WorkspaceNavItem(
                                  spec.label,
                                  _section == spec.section
                                      ? spec.selectedIcon
                                      : spec.icon,
                                  count: spec.section ==
                                          WorkbenchSection.conversations
                                      ? _workbench.unread
                                      : 0)
                          ],
                          footer: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                NotificationCenter(
                                    api: widget.session.api,
                                    onConversation:
                                        _openNotificationConversation),
                                if (canOpenWebsite)
                                  IconButton(
                                      tooltip: '手机客户端下载',
                                      onPressed: openDownloads,
                                      icon: const Icon(Icons.phone_android,
                                          size: 20)),
                              ]),
                          avatar: InkWell(
                            onTap: () => setState(
                                () => _section = WorkbenchSection.settings),
                            child: _RailLeading(agent: agent, extended: false),
                          ),
                        )),
                Expanded(
                    child: Column(children: [
                  Container(
                      height: 62,
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          border: Border(
                              bottom: BorderSide(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant))),
                      child: Row(children: [
                        Text(widget.session.tenant?.name ?? '工作空间',
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant)),
                        const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Text('/')),
                        Expanded(
                            child: Text(
                                sections
                                    .firstWhere((s) => s.section == _section)
                                    .label,
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600))),
                        _ConnectionBadge(workbench: _workbench),
                        messageSoundButton(),
                        const SizedBox(width: 8),
                        Text(agent?.displayName ?? '',
                            style: const TextStyle(fontSize: 12))
                      ])),
                  Expanded(child: body),
                ])),
              ]),
            );
          },
        );
      },
    );
  }

  Widget _bodyFor(double width) {
    switch (_section) {
      case WorkbenchSection.groups:
        // 和客户消息一样铺满剩余宽度，不再套一层圆角留白。
        return GroupsPage(session: widget.session);
      case WorkbenchSection.overview:
        final admin = widget.session.agent?.role == 'SUPERVISOR';
        return OverviewPage(
          workbench: _workbench,
          name: widget.session.agent?.displayName ?? '',
          isAdmin: admin,
          onInbox: () =>
              setState(() => _section = WorkbenchSection.conversations),
          onKnowledge: () =>
              setState(() => _section = WorkbenchSection.knowledge),
          onIntegrations: admin && _has('integrations')
              ? () => setState(() => _section = WorkbenchSection.integrations)
              : null,
          onEnterprise: admin
              ? () => setState(() => _section = WorkbenchSection.enterprise)
              : null,
        );
      case WorkbenchSection.stats:
        return StatsPage(session: widget.session, workbench: _workbench);
      case WorkbenchSection.knowledge:
        return KnowledgePage(
            session: widget.session, workbench: _workbench, canAI: _has('ai'));
      case WorkbenchSection.settings:
        return SettingsPage(
          session: widget.session,
          themeMode: widget.themeMode,
          onThemeModeChanged: widget.onThemeModeChanged,
        );
      case WorkbenchSection.integrations:
        return IntegrationPage(
          api: widget.session.api,
          canIdentity: _has('identity'),
        );
      case WorkbenchSection.enterprise:
        return TenantAdminPage(
            api: widget.session.api,
            tenantSlug: widget.session.tenant?.slug ?? '',
            onMemberSaved: () async {
              await widget.session.refreshProfile();
              await _workbench.loadAgents();
            });
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
    final inlineProfile = width >= 1040 && !_profileOpen;
    final sideBySide = width >= 760;

    if (!sideBySide) {
      // Phone: the queue and the thread take turns, which is what the back
      // affordance in the thread's own app bar is for.
      return MobileConversationFlow(
        workbench: _workbench,
        list: list,
        picker: _picker,
        session: widget.session,
      );
    }

    final chat = ChatPanel(
      workbench: _workbench,
      picker: _picker,
      assistDraft: _assistDraft,
      showInlineAssist: !inlineProfile,
      onOpenProfile: width >= 1120
          ? () => setState(() => _profileOpen = !_profileOpen)
          : () => _openProfile(),
    );

    // 企点式三栏：会话列表 | 聊天 | 客户资料，竖分割线贴边。
    return Row(
      children: <Widget>[
        SizedBox(
          width: width >= 1200 ? 278 : 260,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Theme.of(context).colorScheme.surface
                  : const Color(0xFFFAFBFD),
              border: Border(
                right: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            child: list,
          ),
        ),
        Expanded(
            child: ColoredBox(
          color: Theme.of(context).colorScheme.surface,
          child: _ProfileScope(
            open: width < 1120 && _profileOpen,
            onClose: () => setState(() => _profileOpen = false),
            workbench: _workbench,
            child: chat,
          ),
        )),
        if (inlineProfile) ...<Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                left: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            child: SizedBox(
              width: width >= 1200 ? 326 : 310,
              child: ConversationContextPanel(
                workbench: _workbench,
                onAdopt: (text) {
                  _assistDraft.value = null;
                  _assistDraft.value = text;
                },
              ),
            ),
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
              const Text('客户会话'),
              const SizedBox(width: 10),
              if (_workbench.queued > 0)
                Text(
                  '${_workbench.queued} 位待领取',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              const Spacer(),
              _ConnectionBadge(workbench: _workbench),
              NotificationCenter(
                  api: widget.session.api,
                  onConversation: _openNotificationConversation),
              messageSoundButton(),
            ],
          ),
        ),
      );
    }
    return AppBar(title: Text(_sectionTitle(_section)));
  }

  static String _sectionTitle(WorkbenchSection section) => switch (section) {
        WorkbenchSection.groups => '群聊',
        WorkbenchSection.overview => '工作概览',
        WorkbenchSection.conversations => '客户会话',
        WorkbenchSection.stats => '数据统计',
        WorkbenchSection.knowledge => '知识库',
        WorkbenchSection.integrations => '接入管理',
        WorkbenchSection.settings => '我的设置',
        WorkbenchSection.enterprise => '企业管理',
      };
}

class _SectionSpec {
  const _SectionSpec({
    required this.section,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    this.group = '',
  });

  final WorkbenchSection section;
  final String label;
  final String group;
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
        'SUPERVISOR' => '客服主管',
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
          SocketState.closed => (
              '离线',
              theme.colorScheme.error,
              Icons.cloud_off
            ),
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
class MobileConversationFlow extends StatefulWidget {
  const MobileConversationFlow(
      {required this.workbench,
      required this.list,
      required this.picker,
      required this.session});
  final WorkbenchController workbench;
  final Widget list;
  final AttachmentPicker picker;
  final SessionController session;
  @override
  State<MobileConversationFlow> createState() => MobileConversationFlowState();
}

class MobileConversationFlowState extends State<MobileConversationFlow> {
  bool _scheduled = false;
  Route<void>? _threadRoute;
  @override
  void initState() {
    super.initState();
    widget.workbench.addListener(_selectionChanged);
    _selectionChanged();
  }

  @override
  void dispose() {
    widget.workbench.removeListener(_selectionChanged);
    final route = _threadRoute;
    if (route != null) WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) route.navigator?.removeRoute(route);
    });
    super.dispose();
  }

  void _selectionChanged() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      if (widget.workbench.selectedId == null) {
        if (_threadRoute?.isCurrent == true) Navigator.of(context).pop();
        return;
      }
      if (_threadRoute != null) return;
      final route = MaterialPageRoute<void>(
          settings: RouteSettings(
              name: '/conversation/${widget.workbench.selectedId}'),
          builder: (routeContext) => Scaffold(
                body: ChatPanel(
                  workbench: widget.workbench,
                  picker: widget.picker,
                  showInlineAssist: false,
                  onBack: () => Navigator.of(routeContext).maybePop(),
                  onOpenProfile: () => Navigator.of(routeContext).push(
                      MaterialPageRoute<void>(
                          builder: (_) => Scaffold(
                              appBar: AppBar(title: const Text('客户资料')),
                              body: VisitorSidebar(
                                  workbench: widget.workbench)))),
                ),
              ));
      _threadRoute = route;
      // 真正的导航路由让系统返回、浏览器返回与页面返回具有同一行为。
      Navigator.of(context).push(route);
      route.completed.whenComplete(() {
        _threadRoute = null;
        if (mounted) widget.workbench.clearSelection();
      });
    });
  }

  @override
  Widget build(BuildContext context) => widget.list;
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
