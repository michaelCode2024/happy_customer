import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relaydesk_agent_console/src/api/models.dart';
import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/state/session_controller.dart';
import 'package:relaydesk_agent_console/src/state/workbench_controller.dart';
import 'package:relaydesk_agent_console/src/ui/visitor_sidebar.dart';
import 'package:relaydesk_agent_console/src/ui/stats_page.dart';
import 'package:relaydesk_agent_console/src/ui/platform_page.dart';
import 'package:relaydesk_agent_console/src/ui/groups_page.dart';
import 'package:relaydesk_agent_console/src/ui/knowledge_page.dart';
import 'package:relaydesk_agent_console/src/platform/platform_controller.dart';
import 'package:relaydesk_agent_console/src/state/credential_store.dart';
import 'fake_platform_api.dart';

// 仅使用内存 API 复现，无网络请求或生产写入。
class AuditApi extends RelayDeskApi {
  AuditApi() : super(server: 'http://127.0.0.1:1');
  final note = Completer<VisitorNote>();
  final calls = <Completer<StatsOverview>>[];
  final olderMessages = Completer<Map<String, dynamic>>();
  @override
  Future<List<KnowledgeEntry>> knowledge({String query = ''}) async => [];
  @override
  Future<List<Map<String, dynamic>>> knowledgeCategories() async => [];
  @override
  Future<Map<String, dynamic>> adminGet(String path) async => {'items': []};
  @override
  Future<Map<String, dynamic>> assistFeedbackSummary() async => {};
  @override
  Future<Map<String, dynamic>> groupRequest(String method, String path,
      {Map<String, dynamic>? body}) async {
    if (path.contains('before=')) return olderMessages.future;
    return {'items': <Map<String, dynamic>>[]};
  }

  @override
  Future<VisitorProfile> visitor(String id) async =>
      VisitorProfile.fromJson({'id': id, 'displayName': '客户$id'});
  @override
  Future<List<VisitorNote>> notes(String id) async => [];
  @override
  Future<List<Conversation>> visitorConversations(String id) async => [];
  @override
  Future<VisitorNote> addNote(String id, String content) => note.future;
  @override
  Future<StatsOverview> stats({int days = 14}) {
    final result = Completer<StatsOverview>();
    calls.add(result);
    return result.future;
  }
}

class AuditSession extends SessionController {
  AuditSession(this.client);
  final RelayDeskApi client;
  @override
  RelayDeskApi get api => client;
  @override
  AgentProfile? get agent =>
      AgentProfile.fromJson({'id': 'self', 'role': 'SUPERVISOR'});
}

class AuditWorkbench extends WorkbenchController {
  AuditWorkbench(RelayDeskApi api) : super(api: api);
  String visitorId = 'A';
  void change(String id) {
    visitorId = id;
    notifyListeners();
  }

  @override
  ConversationDetail? get detail => ConversationDetail.fromJson({
        'conversation': {'id': visitorId, 'visitorId': visitorId},
        'visitor': {'id': visitorId, 'displayName': '客户$visitorId'},
      });
}

StatsOverview overview(int days, int value) => StatsOverview.fromJson({
      'scope': 'tenant',
      'days': days,
      'openConversations': value,
    });
void main() {
  Future<void> sidebar(WidgetTester tester, AuditWorkbench w) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: VisitorSidebar(workbench: w))));
    await tester.pumpAndSettle();
  }

  Finder noteField() => find.byWidgetPredicate((w) =>
      w is TextField && w.decoration?.hintText?.startsWith('记录只有同事') == true);
  testWidgets('备注草稿按客户隔离，切回原客户恢复草稿', (tester) async {
    final api = AuditApi(), w = AuditWorkbench(api);
    await sidebar(tester, w);
    await tester.enterText(noteField(), '只属于客户A的订单信息');
    w.change('B');
    await tester.pumpAndSettle();
    expect(find.text('客户B'), findsWidgets);
    expect(find.text('只属于客户A的订单信息'), findsNothing);
    w.change('A');
    await tester.pumpAndSettle();
    expect(find.text('只属于客户A的订单信息'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    w.dispose();
    api.close();
  });
  testWidgets('迟到备注回包不能插入其他客户或清空新草稿', (tester) async {
    final api = AuditApi(), w = AuditWorkbench(api);
    await sidebar(tester, w);
    await tester.enterText(noteField(), '客户A已付款');
    await tester.tap(find.byTooltip('添加备注'));
    await tester.pump();
    w.change('B');
    await tester.pump();
    await tester.pump();
    await tester.enterText(noteField(), '客户B的新草稿');
    api.note.complete(VisitorNote(
        id: 'note-A',
        content: '客户A已付款',
        authorName: '审查',
        createdAt: DateTime.now()));
    await tester.pumpAndSettle();
    expect(find.text('客户B'), findsWidgets);
    expect(find.text('客户A已付款'), findsNothing);
    expect(find.text('客户B的新草稿'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    w.dispose();
    api.close();
  });
  testWidgets('统计范围快速切换时丢弃旧范围回包', (tester) async {
    final api = AuditApi(),
        w = AuditWorkbench(api),
        session = SessionController();
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
        MaterialApp(home: StatsPage(session: session, workbench: w)));
    api.calls[0].complete(overview(14, 1414));
    await tester.pumpAndSettle();
    final dropdown = find.byType(DropdownButton<int>);
    tester.widget<DropdownButton<int>>(dropdown).onChanged!(7);
    await tester.pump();
    tester.widget<DropdownButton<int>>(dropdown).onChanged!(30);
    await tester.pump();
    api.calls[2].complete(overview(30, 3030));
    await tester.pumpAndSettle();
    expect(find.text('3030'), findsOneWidget);
    api.calls[1].complete(overview(7, 7070));
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<int>>(dropdown).value, 30);
    expect(find.text('7070'), findsNothing);
    expect(find.text('3030'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    w.dispose();
    api.close();
  });
  testWidgets('平台设置切到账号安全时同步正文标签', (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = FakePlatformApi(), store = MemoryCredentialStore();
    await store.saveServer('https://audit.invalid');
    await store.savePlatformToken('local-fixture');
    final c =
        PlatformController(store: store, apiFactory: (_) => fake.buildClient());
    await c.bootstrap();
    c.selectSection(PlatformSection.about);
    await tester.pumpWidget(
        MaterialApp(home: PlatformPage(controller: c, onAgentLogin: () {})));
    await tester.pumpAndSettle();
    expect(
        DefaultTabController.of(tester.element(find.byType(TabBar))).index, 0);
    c.selectSection(PlatformSection.account);
    await tester.pumpAndSettle();
    expect(c.section, PlatformSection.account);
    expect(
        DefaultTabController.of(tester.element(find.byType(TabBar))).index, 2);
    c.selectSection(PlatformSection.about);
    await tester.pumpAndSettle();
    expect(
        DefaultTabController.of(tester.element(find.byType(TabBar))).index, 0);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('切换群聊后丢弃旧群历史分页', (tester) async {
    final api = AuditApi(), session = AuditSession(api);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: GroupsPage(session: session))));
    await tester.pump();
    await tester.pump();
    final dynamic state = tester.state(find.byType(GroupsPage));
    state.selected = 'A';
    state.messages = <Map<String, dynamic>>[
      {'id': 'latest-A', 'sequence': 110, 'content': 'A最新'}
    ];
    final pending = state.older();
    state.selected = 'B';
    state.messages = <Map<String, dynamic>>[
      {'id': 'latest-B', 'sequence': 100, 'content': 'B最新'}
    ];
    api.olderMessages.complete({
      'items': [
        {'id': 'old-A', 'sequence': 1, 'content': 'A历史'}
      ]
    });
    await pending;
    await tester.pump();
    expect(state.selected, 'B');
    expect((state.messages as List).map((m) => m['id']), equals(['latest-B']));
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    api.close();
    await tester.pump(const Duration(seconds: 5));
  });
  testWidgets('知识库嵌入页由外层标签唯一控制，不能出现两组不同选中状态', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = AuditApi(),
        session = AuditSession(api),
        w = AuditWorkbench(api);
    await tester.pumpWidget(
        MaterialApp(home: KnowledgePage(session: session, workbench: w)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未解决问题'));
    await tester.pumpAndSettle();
    expect(find.text('未解决问题'), findsNWidgets(2));
    expect(find.text('近 30 天未被 AI 解决的问题，帮助团队补充知识'), findsOneWidget);
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('批量导入知识'), findsNothing);
    await tester.tap(find.text('分类与批量导入'));
    await tester.pumpAndSettle();
    expect(find.text('批量导入知识'), findsOneWidget);
    expect(find.text('近 30 天未被 AI 解决的问题，帮助团队补充知识'), findsNothing);
    expect(find.byType(TabBar), findsNothing);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    w.dispose();
    api.close();
  });
}
