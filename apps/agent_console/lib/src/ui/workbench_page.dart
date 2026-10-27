import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
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
import 'package:tongyu_agent_console/src/util/app_platform.dart';
import 'package:tongyu_agent_console/src/util/app_update.dart';
import 'dart:async';
import 'package:tongyu_agent_console/src/ui/overview_page.dart';
import 'package:tongyu_agent_console/src/ui/brand.dart';

import 'package:flutter/material.dart';

import 'package:tongyu_agent_console/src/api/models.dart';
import 'package:tongyu_agent_console/src/realtime/console_socket.dart';
import 'package:tongyu_agent_console/src/state/session_controller.dart';
import 'package:tongyu_agent_console/src/state/workbench_controller.dart';
import 'package:tongyu_agent_console/src/ui/browser_back_page_route.dart';
import 'package:tongyu_agent_console/src/ui/chat_panel.dart';
import 'package:tongyu_agent_console/src/ui/conversation_list.dart';
import 'package:tongyu_agent_console/src/ui/mobile_conversation_view.dart';
import 'package:flutter/foundation.dart';
import 'package:tongyu_agent_console/src/ui/mobile_workbench_nav.dart';
import 'package:tongyu_agent_console/src/ui/reception_guidance.dart';
import 'package:tongyu_agent_console/src/ui/automation_page.dart';
import 'package:tongyu_agent_console/src/ui/integration_page.dart';
import 'package:tongyu_agent_console/src/ui/knowledge_page.dart';
import 'package:tongyu_agent_console/src/ui/settings_page.dart';
import 'package:tongyu_agent_console/src/ui/tenant_admin_page.dart';
import 'package:tongyu_agent_console/src/ui/stats_page.dart';
import 'package:tongyu_agent_console/src/ui/visitor_sidebar.dart';
import 'package:tongyu_agent_console/src/ui/conversation_context_panel.dart';
import 'package:tongyu_agent_console/src/util/attachment_picker.dart';
import 'package:tongyu_agent_console/src/util/browser_history.dart';
import 'package:tongyu_agent_console/src/util/voice_player.dart';

/// The console's top-level sections.
enum WorkbenchSection {
  overview,
  conversations,
  groups,
  stats,
  knowledge,
  integrations,
  /// 关键词 / 欢迎语等自动回复；需套餐 automation + 主管。
  automation,
  /// H5/App 渠道与图文菜单；需套餐 channels + 主管。
  channels,
  enterprise,
  settings,
  /// 手机底栏「更多」枢纽页；宽屏侧栏不展示此项。
  more,
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

  /// 手机「更多」点进的二级页路由；与 section 切换分开，避免外层返回条 + 路由 pop 叠两次动画。
  BrowserBackPageRoute<void>? _moreChildRoute;

  /// 「更多」二级页与边缘手势 / 系统返回共用：按钮 pop 与 popstate 都只退一层，不直跳首页。
  final _moreBrowserHistory = BrowserHistoryGate();
  StreamSubscription<void>? _moreBrowserBack;

  /// True while the customer record is open as a pushed page on a narrow window.
  bool _profileOpen = false;
  final _assistDraft = ValueNotifier<AssistResult?>(null);
  final _contextPanelTab = ValueNotifier<int>(1);
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

  bool _hasSection(WorkbenchSection section) =>
      _sections(widget.session.agent).any((s) => s.section == section);

  bool _has(String feature) => _features[feature] == true;

  Set<String> _autoAcceptInboxIdsOf(SessionController session) => {
        for (final inbox in session.inboxes)
          if (inbox.autoAccept) inbox.id,
      };

  @override
  void initState() {
    super.initState();
    initializeMessageAlerts();
    // 边缘滑动 / 浏览器后退：只卸当前「更多」二级页，与顶栏返回同一条 Navigator 栈。
    _moreBrowserBack = _moreBrowserHistory.listen(_onMoreBrowserBack);
    _notificationNavigation = notificationConversationEvents().listen((id) {
      if (mounted && RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id))
        _openNotificationConversation(id);
    });
    _workbench = WorkbenchController(
      api: widget.session.api,
      selfId: widget.session.agent?.id ?? '',
      autoAcceptInboxIds: _autoAcceptInboxIdsOf(widget.session),
    );
    _picker = widget.picker ?? ImageAttachmentPicker();
    unawaited(_refreshPlan());
    _planRefresh =
        Timer.periodic(const Duration(seconds: 5), (_) => _refreshPlan());
    _workbench.onGroupUpdated = checkIncomingCall;
    _workbench.connectRealtime();
    unawaited(_openInitialConversation());
    unawaited(_workbench.loadReferenceData());
    unawaited(_loadMenuConfig());
    // 安卓安装包：版本检查 + 本机轮询提醒/角标（非云推送；杀进程不管）。
    // iOS 只用 PWA 通道，不走这里。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(promptAndroidAppUpdateIfNeeded(
        context,
        serverBase: widget.session.api.server,
      ));
      if (runningOnAndroid) {
        unawaited(enableBackgroundPush(widget.session.api));
      }
    });
  }

  @override
  void didUpdateWidget(covariant WorkbenchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 入口「自动接单」可能在企业管理页改过，每次重建都同步到工作台。
    _workbench.setAutoAcceptInboxIds(_autoAcceptInboxIdsOf(widget.session));
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
    _moreBrowserBack?.cancel();
    _moreBrowserHistory.drain();
    _planRefresh?.cancel();
    _assistDraft.dispose();
    _contextPanelTab.dispose();
    _workbench.dispose();
    // The player is a process-wide singleton, so it is released rather than
    // disposed: signing out and back in must not hand the new session a dead
    // audio backend.
    unawaited(VoicePlayer.instance.release());
    super.dispose();
  }

  bool _onMoreBrowserBack() {
    if (!mounted) return false;
    final route = _moreChildRoute;
    if (route != null && route.isCurrent) {
      // 边缘手势已播过系统返回动画，这里瞬时收层；顶栏按钮仍走带动画的 pop。
      // 禁止 removeRoute（Web 上会跳过收尾并留下点不中的层）。
      route.popFromBrowser();
      return true;
    }
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.maybePop();
      return true;
    }
    return false;
  }

  Map<String, String> _customMenuLabels = {};
  Map<String, bool> _customMenuEnabled = {};
  Map<String, String> _customMenuRoles = {};

  Future<void> _loadMenuConfig() async {
    final slug = widget.session.tenant?.slug ?? 'default';
    final prefs = await SharedPreferences.getInstance();
    final labelsStr = prefs.getString('tongyu.menu_labels_$slug');
    final enabledStr = prefs.getString('tongyu.menu_enabled_$slug');
    final rolesStr = prefs.getString('tongyu.menu_roles_$slug');
    if (labelsStr != null) {
      try {
        final decoded = jsonDecode(labelsStr) as Map<String, dynamic>;
        _customMenuLabels = decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (_) {}
    }
    if (enabledStr != null) {
      try {
        final decoded = jsonDecode(enabledStr) as Map<String, dynamic>;
        _customMenuEnabled = decoded.map((k, v) => MapEntry(k, v == true));
      } catch (_) {}
    }
    if (rolesStr != null) {
      try {
        final decoded = jsonDecode(rolesStr) as Map<String, dynamic>;
        _customMenuRoles = decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveMenuConfig() async {
    final slug = widget.session.tenant?.slug ?? 'default';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tongyu.menu_labels_$slug', jsonEncode(_customMenuLabels));
    await prefs.setString('tongyu.menu_enabled_$slug', jsonEncode(_customMenuEnabled));
    await prefs.setString('tongyu.menu_roles_$slug', jsonEncode(_customMenuRoles));
  }

  void _showMenuConfigDialog() {
    final agent = widget.session.agent;
    final baseSpecs = _rawSections(agent, ignoreRoleFilter: true);
    final tempLabels = Map<String, String>.from(_customMenuLabels);
    final tempEnabled = Map<String, bool>.from(_customMenuEnabled);
    final tempRoles = Map<String, String>.from(_customMenuRoles);

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final scheme = Theme.of(ctx).colorScheme;
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.tune_rounded, size: 20),
                SizedBox(width: 8),
                Text('自定义左侧导航与权限控制', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ],
            ),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '管理员可配置各菜单项的展示名称、启用状态，以及访问权限控制（全员可见 / 仅主管可见）：',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final spec in baseSpecs)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: Row(
                                children: [
                                  Icon(spec.icon, size: 18, color: scheme.onSurfaceVariant),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    flex: 3,
                                    child: TextFormField(
                                      initialValue: tempLabels[spec.id] ?? spec.label,
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                        border: OutlineInputBorder(),
                                      ),
                                      style: const TextStyle(fontSize: 12),
                                      onChanged: (val) {
                                        tempLabels[spec.id] = val.trim();
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // 权限选择下拉框：全员 / 仅主管
                                  Expanded(
                                    flex: 2,
                                    child: DropdownButtonFormField<String>(
                                      value: tempRoles[spec.id] ?? (spec.role ?? 'ALL'),
                                      isDense: true,
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                        border: OutlineInputBorder(),
                                      ),
                                      style: TextStyle(fontSize: 12, color: scheme.onSurface),
                                      items: const [
                                        DropdownMenuItem(value: 'ALL', child: Text('全员可见', style: TextStyle(fontSize: 11))),
                                        DropdownMenuItem(value: 'SUPERVISOR', child: Text('仅主管', style: TextStyle(fontSize: 11))),
                                      ],
                                      onChanged: (v) {
                                        if (v != null) {
                                          setDlgState(() {
                                            tempRoles[spec.id] = v;
                                          });
                                        }
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Checkbox(
                                    value: tempEnabled[spec.id] ?? true,
                                    onChanged: (v) {
                                      setDlgState(() {
                                        tempEnabled[spec.id] = v ?? true;
                                      });
                                    },
                                  ),
                                  const Text('启用', style: TextStyle(fontSize: 12)),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setState(() {
                    _customMenuLabels.clear();
                    _customMenuEnabled.clear();
                    _customMenuRoles.clear();
                  });
                  _saveMenuConfig();
                  Navigator.of(ctx).pop();
                },
                child: const Text('恢复默认'),
              ),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _customMenuLabels = tempLabels;
                    _customMenuEnabled = tempEnabled;
                    _customMenuRoles = tempRoles;
                  });
                  _saveMenuConfig();
                  Navigator.of(ctx).pop();
                },
                child: const Text('保存配置'),
              ),
            ],
          );
        },
      ),
    );
  }

  List<_SectionSpec> _rawSections(AgentProfile? agent, {bool ignoreRoleFilter = false}) {
    final canReport = agent?.canViewReports ?? false;
    final admin = agent?.role == 'SUPERVISOR';
    return <_SectionSpec>[
      const _SectionSpec(
        id: 'messages',
        section: WorkbenchSection.conversations,
        label: '客户消息',
        group: '日常接待',
        icon: Icons.forum_outlined,
        selectedIcon: Icons.forum,
      ),
      if (_has('groups') || ignoreRoleFilter)
        const _SectionSpec(
          id: 'groups',
          section: WorkbenchSection.groups,
          label: '群聊',
          group: '日常接待',
          icon: Icons.groups_outlined,
          selectedIcon: Icons.groups,
        ),
      const _SectionSpec(
        id: 'overview',
        section: WorkbenchSection.overview,
        label: '工作台',
        group: '日常接待',
        icon: Icons.grid_view_outlined,
        selectedIcon: Icons.grid_view_rounded,
      ),
      const _SectionSpec(
        id: 'knowledge',
        section: WorkbenchSection.knowledge,
        label: '知识库',
        group: '日常接待',
        icon: Icons.menu_book_outlined,
        selectedIcon: Icons.menu_book,
      ),
      if (canReport || ignoreRoleFilter)
        const _SectionSpec(
          id: 'stats',
          section: WorkbenchSection.stats,
          label: '数据统计',
          group: '日常接待',
          icon: Icons.insights_outlined,
          selectedIcon: Icons.insights,
          role: 'SUPERVISOR',
        ),
      if ((admin && _has('integrations')) || ignoreRoleFilter)
        const _SectionSpec(
          id: 'integrations',
          section: WorkbenchSection.integrations,
          label: '接入管理',
          group: '企业管理',
          icon: Icons.code_rounded,
          selectedIcon: Icons.code,
          role: 'SUPERVISOR',
          feature: 'integrations',
        ),
      // 与套餐 entitlements 对齐：旗舰/企业版才开放；欢迎语在「打开客服回复」。
      if ((admin && _has('automation')) || ignoreRoleFilter)
        const _SectionSpec(
          id: 'automation',
          section: WorkbenchSection.automation,
          label: '自动回复',
          group: '企业管理',
          icon: Icons.smart_toy_outlined,
          selectedIcon: Icons.smart_toy,
          role: 'SUPERVISOR',
          feature: 'automation',
        ),
      if ((admin && _has('channels')) || ignoreRoleFilter)
        const _SectionSpec(
          id: 'channels',
          section: WorkbenchSection.channels,
          label: '渠道管理',
          group: '企业管理',
          icon: Icons.devices_outlined,
          selectedIcon: Icons.devices,
          role: 'SUPERVISOR',
          feature: 'channels',
        ),
      if (admin || ignoreRoleFilter)
        const _SectionSpec(
          id: 'enterprise',
          section: WorkbenchSection.enterprise,
          label: '企业管理',
          group: '企业管理',
          icon: Icons.domain_outlined,
          selectedIcon: Icons.domain_rounded,
          role: 'SUPERVISOR',
        ),
      const _SectionSpec(
        id: 'settings',
        section: WorkbenchSection.settings,
        label: '设置',
        group: '个人设置',
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
      ),
    ];
  }

  /// 菜单按「接待 → 开通 → 账号」分组，并支持管理员自定义配置（名称、启用状态与角色权限过滤）。
  List<_SectionSpec> _sections(AgentProfile? agent) {
    final raw = _rawSections(agent);
    final isSupervisor = agent?.role == 'SUPERVISOR';
    return raw
        .where((s) => _customMenuEnabled[s.id] ?? true)
        .where((s) {
          // 权限控制：如果管理员配置了特定角色，优先以配置为准；否则按默认角色限制
          final requiredRole = _customMenuRoles[s.id] ?? (s.role ?? 'ALL');
          if (requiredRole == 'SUPERVISOR' && !isSupervisor) {
            return false;
          }
          return true;
        })
        .map((s) {
          final customLabel = _customMenuLabels[s.id];
          return (customLabel != null && customLabel.isNotEmpty)
              ? s.copyWith(label: customLabel)
              : s;
        })
        .toList();
  }

  /// 手机底栏只留 3～4 个主入口，其余进「更多」页，避免十几个 Tab 挤成一团。
  List<_SectionSpec> _phoneDestinations(List<_SectionSpec> sections) {
    // 手机底栏：消息 / 工作台 / 知识（有权限时）/ 更多。
    final primary = <WorkbenchSection>[
      WorkbenchSection.conversations,
      WorkbenchSection.overview,
      if (sections.any((s) => s.section == WorkbenchSection.knowledge))
        WorkbenchSection.knowledge,
    ];
    return [
      for (final section in primary)
        sections.firstWhere((s) => s.section == section),
    ];
  }

  /// 不在底栏主入口里的功能，归入「更多」页。
  List<_SectionSpec> _moreExtras(List<_SectionSpec> sections) => sections
      .where((s) =>
          s.section != WorkbenchSection.conversations &&
          s.section != WorkbenchSection.overview &&
          s.section != WorkbenchSection.knowledge)
      .toList();

  /// 关掉「更多」压着的二级页（切底栏或再次进枢纽前先卸掉）。
  void _popMoreChildIfAny() {
    final route = _moreChildRoute;
    if (route == null) return;
    if (route.isCurrent) {
      // 与手势/顶栏同一条 pop 收尾，顺带 sync History；禁止 removeRoute。
      route.navigator?.maybePop();
    } else {
      _moreChildRoute = null;
    }
  }

  /// 手机从「更多」进二级：只 push 一层，系统/页头/边缘手势返回都只退这一层。
  void _openMoreChild(WorkbenchSection section) {
    if (section == WorkbenchSection.more) return;
    // 已有二级时先卸完再开，避免旧页 whenComplete 的 History sync 误伤新页。
    if (_moreChildRoute != null) {
      _popMoreChildIfAny();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openMoreChild(section);
      });
      return;
    }
    final page = _moreChildPage(section);
    final route = BrowserBackPageRoute<void>(
      settings: RouteSettings(name: '/more/${section.name}'),
      builder: (_) => page,
    );
    _moreChildRoute = route;
    // 压一条 History，边缘滑动才进 Flutter 栈，而不是浏览器直接退到站外首页。
    _moreBrowserHistory.push('more/${section.name}');
    Navigator.of(context).push(route).whenComplete(() {
      if (_moreChildRoute == route) _moreChildRoute = null;
      _moreBrowserHistory.syncAfterLocalPop();
    });
  }

  /// 二级页本体；自带 AppBar 的直接推，没有的包一层带返回的壳。
  Widget _moreChildPage(WorkbenchSection section) {
    switch (section) {
      case WorkbenchSection.groups:
        return Scaffold(
          appBar: AppBar(title: const Text('群聊')),
          body: GroupsPage(session: widget.session),
        );
      case WorkbenchSection.stats:
        return StatsPage(session: widget.session, workbench: _workbench);
      case WorkbenchSection.settings:
        return SettingsPage(
          session: widget.session,
          themeMode: widget.themeMode,
          onThemeModeChanged: widget.onThemeModeChanged,
        );
      case WorkbenchSection.integrations:
        return Scaffold(
          appBar: AppBar(title: const Text('接入管理')),
          body: IntegrationPage(
            api: widget.session.api,
            canIdentity: _has('identity'),
          ),
        );
      case WorkbenchSection.automation:
        return AutomationPage(api: widget.session.api);
      case WorkbenchSection.channels:
        return AutomationPage(api: widget.session.api, channels: true);
      case WorkbenchSection.enterprise:
        return TenantAdminPage(
          api: widget.session.api,
          tenantSlug: widget.session.tenant?.slug ?? '',
          onMemberSaved: () async {
            await widget.session.refreshProfile();
            await _workbench.loadAgents();
          },
        );
      case WorkbenchSection.overview:
      case WorkbenchSection.conversations:
      case WorkbenchSection.knowledge:
      case WorkbenchSection.more:
        return const SizedBox.shrink();
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
        // 「更多」枢纽不在侧栏菜单里，单独放行。
        if (_section != WorkbenchSection.more &&
            !sections.any((spec) => spec.section == _section)) {
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
              // 图标轨固定 58（对齐 Stitch B）。接待区铺满剩余宽度，不再套一层圆角留白。
              child: _bodyFor(useRail ? width - 78 : width),
            );
            final body = Column(children: [
              if (!isHostedConsole)
                PwaPanel(
                    api: widget.session.api,
                    hideUpdateBanner: false,
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
              final hasKnowledge =
                  sections.any((s) => s.section == WorkbenchSection.knowledge);
              // 主入口以外（含「更多」枢纽本身）都高亮第四项。
              final onMoreTab =
                  phoneIndex < 0 || _section == WorkbenchSection.more;
              final moreTabIndex = hasKnowledge ? 3 : 2;

              return Scaffold(
                // 窄屏使用原生风格移动应用栏
                appBar:
                    hostedThread || _section != WorkbenchSection.conversations
                        ? null
                        : _compactAppBar(agent),
                body: body,
                bottomNavigationBar: hostedThread
                    ? null
                    : MobileBottomNavBar(
                        currentIndex:
                            onMoreTab ? moreTabIndex : phoneIndex,
                        unreadCount: _workbench.unread,
                        showKnowledge: hasKnowledge,
                        onTap: (index) {
                          // 先卸掉「更多」二级路由，避免底栏切换后还压着旧页。
                          _popMoreChildIfAny();
                          if (index < phone.length) {
                            setState(() => _section = phone[index].section);
                          } else {
                            setState(() => _section = WorkbenchSection.more);
                          }
                        },
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
                                if (agent?.role == 'SUPERVISOR')
                                  IconButton(
                                    tooltip: '配置侧栏菜单',
                                    onPressed: _showMenuConfigDialog,
                                    icon: const Icon(Icons.tune_rounded, size: 20),
                                  ),
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
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
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
                                fontSize: 13,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant)),
                        const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text('/', style: TextStyle(color: Color(0xFFBDC7D6), fontSize: 13))),
                        Expanded(
                            child: Text(
                                sections
                                    .firstWhere((s) => s.section == _section)
                                    .label,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600))),
                        _ConnectionBadge(workbench: _workbench),
                        const SizedBox(width: 4),
                        NotificationCenter(
                          api: widget.session.api,
                          onConversation: (id) async {
                            setState(() => _section = WorkbenchSection.conversations);
                            await _workbench.select(id);
                          },
                        ),
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
      case WorkbenchSection.more:
        final extras = _moreExtras(_sections(widget.session.agent));
        return MobileMoreHubPage(
          agentName: widget.session.agent?.displayName,
          tenantName: widget.session.tenant?.name,
          // 网页版把「系统更新」放在更多页顶，避免埋进设置 → 外观与通知才找得到。
          header: kIsWeb
              ? PwaPanel(
                  api: widget.session.api,
                  settingsOnly: true,
                  onReconnect: () async {
                    await _workbench.refreshConversations();
                    await _workbench.reloadSelected();
                  },
                )
              : null,
          entries: [
            for (final spec in extras)
              MobileMoreEntry(
                label: spec.label,
                group: spec.group,
                icon: spec.icon,
                onTap: () => _openMoreChild(spec.section),
              ),
          ],
        );
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
      case WorkbenchSection.automation:
        return AutomationPage(api: widget.session.api);
      case WorkbenchSection.channels:
        return AutomationPage(api: widget.session.api, channels: true);
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
    // 窄屏采用专为触控与单手操作优化的 MobileConversationListView
    final isMobile = width < 760;
    final list = isMobile
        ? MobileConversationListView(
            workbench: _workbench,
            session: widget.session,
            onOpenKnowledge: _hasSection(WorkbenchSection.knowledge)
                ? () => setState(() => _section = WorkbenchSection.knowledge)
                : null,
          )
        : ConversationListPanel(
            workbench: _workbench,
            session: widget.session,
            onOpenKnowledge: _hasSection(WorkbenchSection.knowledge)
                ? () => setState(() => _section = WorkbenchSection.knowledge)
                : null,
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

    void toggleProfile({int? tab}) {
      if (tab != null) {
        _contextPanelTab.value = tab;
      }
      if (width >= 1120) {
        // 宽屏模式：如果已经处于同一标签则折叠；若已折叠或切换标签则展开
        setState(() {
          if (_profileOpen) {
            _profileOpen = false;
          } else if (tab != null && _contextPanelTab.value != tab) {
            _contextPanelTab.value = tab;
          } else {
            _profileOpen = true;
          }
        });
      } else {
        setState(() => _profileOpen = true);
      }
    }

    void openAiAssist() {
      _contextPanelTab.value = 1;
      if (width >= 1120) {
        // 确保右侧栏展开（inlineProfile 为 true 时表示自然展示）
        if (_profileOpen) {
          setState(() => _profileOpen = false);
        }
      } else {
        setState(() => _profileOpen = true);
      }
    }

    final chat = ChatPanel(
      workbench: _workbench,
      picker: _picker,
      assistDraft: _assistDraft,
      showInlineAssist: false,
      onOpenProfile: () => toggleProfile(tab: 0),
      onOpenAiAssist: openAiAssist,
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
            activeTabNotifier: _contextPanelTab,
            onAdopt: (text) {
              _assistDraft.value = null;
              _assistDraft.value = text;
            },
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
                activeTabNotifier: _contextPanelTab,
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

  PreferredSizeWidget _compactAppBar(AgentProfile? agent) {
    if (_section == WorkbenchSection.conversations) {
      return MobileTopAppBar(
        session: widget.session,
        workbench: _workbench,
        title: '客户会话',
        onNotificationConversation: _openNotificationConversation,
        onShowQueue: () {
          _workbench.clearSelection();
          unawaited(_workbench.showReceptionQueue());
        },
        onTapAvatar: () => setState(() => _section = WorkbenchSection.settings),
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
        WorkbenchSection.automation => '自动回复',
        WorkbenchSection.channels => '渠道管理',
        WorkbenchSection.settings => '我的设置',
        WorkbenchSection.enterprise => '企业管理',
        WorkbenchSection.more => '更多',
      };
}

class _SectionSpec {
  const _SectionSpec({
    required this.id,
    required this.section,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    this.group = '',
    this.role,
    this.feature,
    this.enabled = true,
  });

  final String id;
  final WorkbenchSection section;
  final String label;
  final String group;
  final IconData icon;
  final IconData selectedIcon;
  final String? role;
  final String? feature;
  final bool enabled;

  _SectionSpec copyWith({
    String? label,
    bool? enabled,
  }) {
    return _SectionSpec(
      id: id,
      section: section,
      label: label ?? this.label,
      group: group,
      icon: icon,
      selectedIcon: selectedIcon,
      role: role,
      feature: feature,
      enabled: enabled ?? this.enabled,
    );
  }
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
  BrowserBackPageRoute<void>? _threadRoute;
  BrowserBackPageRoute<void>? _profileRoute;
  final _browserHistory = BrowserHistoryGate();
  StreamSubscription<void>? _browserBack;

  @override
  void initState() {
    super.initState();
    widget.workbench.addListener(_selectionChanged);
    // iPhone 主屏幕 PWA 边缘滑动走 popstate；与左上角返回共用同一条 Navigator 栈。
    _browserBack = _browserHistory.listen(_onBrowserBack);
    _selectionChanged();
  }

  @override
  void dispose() {
    widget.workbench.removeListener(_selectionChanged);
    final route = _threadRoute;
    _threadRoute = null;
    // 切底栏卸会话时先吐干净 History，避免留下幽灵条目，下次边缘滑动直接退出到首页。
    _browserHistory.drain();
    _browserBack?.cancel();
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // dispose 阶段用 pop 收尾；仍在栈上才卸，避免对已 pop 路由二次操作。
        if (route.isActive) route.navigator?.maybePop();
      });
    }
    super.dispose();
  }

  bool _onBrowserBack() {
    if (!mounted) return false;
    // 边缘手势已播过系统返回动画，这里瞬时收层；页内按钮返回仍走带动画的 pop。
    final profile = _profileRoute;
    if (profile != null && profile.isCurrent) {
      profile.popFromBrowser();
      return true;
    }
    final route = _threadRoute;
    if (route != null && route.isCurrent) {
      route.popFromBrowser();
      return true;
    }
    // 其它子层（弹窗等）：只退当前 Navigator 顶层。
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.maybePop();
      return true;
    }
    return false;
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
      final conversationId = widget.workbench.selectedId!;
      final route = BrowserBackPageRoute<void>(
          settings: RouteSettings(name: '/conversation/$conversationId'),
          builder: (routeContext) => Scaffold(
                body: ChatPanel(
                  workbench: widget.workbench,
                  picker: widget.picker,
                  showInlineAssist: false,
                  onBack: () => Navigator.of(routeContext).maybePop(),
                  onOpenProfile: () {
                    // 客户资料也压一层历史，边缘滑动先关资料再回列表。
                    _browserHistory.push('profile/$conversationId');
                    final profileRoute = BrowserBackPageRoute<void>(
                      settings: RouteSettings(
                          name: '/conversation/$conversationId/profile'),
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('客户资料')),
                        body: VisitorSidebar(workbench: widget.workbench),
                      ),
                    );
                    _profileRoute = profileRoute;
                    Navigator.of(routeContext)
                        .push(profileRoute)
                        .whenComplete(() {
                      if (_profileRoute == profileRoute) _profileRoute = null;
                      _browserHistory.syncAfterLocalPop();
                    });
                  },
                ),
              ));
      _threadRoute = route;
      // 真正的导航路由 + History，系统返回 / 边缘滑动 / 页面返回行为一致。
      _browserHistory.push('conversation/$conversationId');
      Navigator.of(context).push(route);
      route.completed.whenComplete(() {
        _threadRoute = null;
        _browserHistory.syncAfterLocalPop();
        if (mounted) widget.workbench.clearSelection();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.brightness == Brightness.dark
          ? scheme.surface
          : const Color(0xFFF4F7FF),
      child: widget.list,
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
    this.activeTabNotifier,
    this.onAdopt,
  });

  final bool open;
  final VoidCallback onClose;
  final WorkbenchController workbench;
  final Widget child;
  final ValueNotifier<int>? activeTabNotifier;
  final ValueChanged<AssistResult>? onAdopt;

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
                          tooltip: '关闭',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: onClose,
                        ),
                      ),
                      Expanded(
                        child: ConversationContextPanel(
                          workbench: workbench,
                          activeTabNotifier: activeTabNotifier,
                          onAdopt: onAdopt ?? (_) {},
                        ),
                      ),
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
