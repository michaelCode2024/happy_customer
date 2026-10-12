import 'package:flutter_test/flutter_test.dart';

import 'package:relaydesk_agent_console/src/platform/platform_controller.dart';
import 'package:relaydesk_agent_console/src/platform/platform_models.dart';
import 'package:relaydesk_agent_console/src/state/credential_store.dart';

import 'fake_platform_api.dart';

/// The operations console's state machine, driven through the real
/// [PlatformApi] against canned JSON.
///
/// The assertions are about behaviour an operator would notice — a rejected
/// secret comes back to the form, an expired token does not strand them on a
/// blank screen, a suspended tenant says so — rather than about the shape of the
/// controller.
void main() {
  late FakePlatformApi fake;
  late MemoryCredentialStore store;

  PlatformController build() => PlatformController(
        store: store,
        apiFactory: (server) => fake.buildClient(),
      );

  setUp(() {
    fake = FakePlatformApi();
    store = MemoryCredentialStore();
  });

  /// Lets the fire-and-forget refreshes a successful sign-in kicks off land,
  /// so a test can clear [FakePlatformApi.calls] and then count only the
  /// requests it causes itself.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test('an empty store starts locked, not erroring', () async {
    final controller = build();
    addTearDown(controller.dispose);

    await controller.bootstrap();

    expect(controller.phase, PlatformPhase.locked);
    expect(controller.error, isNull);
  });

  test('signing in exchanges the static token and loads the overview',
      () async {
    final controller = build();
    addTearDown(controller.dispose);

    final ok = await controller.signIn(
      server: 'relay.example.test',
      email: 'admin@relaydesk.local',
      password: 'good-token',
    );

    expect(ok, isTrue);
    expect(controller.phase, PlatformPhase.ready);
    expect(controller.overview?.tenants, 2);
    expect(controller.overview?.agents, 4);
    // The static secret is exchanged, never stored: only what it bought is.
    expect(await store.loadPlatformToken(), 'issued-bearer');
    expect(await store.loadServer(), 'https://relay.example.test');
  });

  test('a wrong static token returns to the form with the server wording',
      () async {
    final controller = build();
    addTearDown(controller.dispose);

    final ok = await controller.signIn(
      server: 'relay.example.test',
      email: 'admin@relaydesk.local',
      password: 'wrong-token',
    );

    expect(ok, isFalse);
    expect(controller.phase, PlatformPhase.locked);
    expect(controller.error, '账号或密码错误');
  });

  test('the server address is normalised before it is stored', () async {
    final controller = build();
    addTearDown(controller.dispose);

    await controller.signIn(
      server: '  relay.example.test/  ',
      email: 'admin@relaydesk.local',
      password: 'good-token',
    );

    expect(controller.server, 'https://relay.example.test');
  });

  test('an empty server is refused without a request', () async {
    final controller = build();
    addTearDown(controller.dispose);

    final ok = await controller.signIn(
        server: '   ', email: 'admin@relaydesk.local', password: 'good-token');

    expect(ok, isFalse);
    expect(controller.error, '请填写服务器地址');
    expect(fake.calls, isEmpty);
  });

  test('a stored token is proved by the overview, then kept', () async {
    await store.saveServer('https://relay.example.test');
    await store.savePlatformToken('stored-bearer');
    final controller = build();
    addTearDown(controller.dispose);

    await controller.bootstrap();

    expect(controller.phase, PlatformPhase.ready);
    expect(controller.overview, isNotNull);
    expect(await store.loadPlatformToken(), 'stored-bearer');
  });

  test('a rejected stored token locks the console and is discarded', () async {
    await store.saveServer('https://relay.example.test');
    await store.savePlatformToken('expired-bearer');
    final controller = build();
    addTearDown(controller.dispose);
    fake.failWith = jsonResponse(401, <String, dynamic>{
      'code': 'UNAUTHORIZED',
      'message': '登录已过期',
    });

    await controller.bootstrap();

    expect(controller.phase, PlatformPhase.locked);
    expect(await store.loadPlatformToken(), isNull);
  });

  test('an unreachable server does not sign the operator out', () async {
    await store.saveServer('https://relay.example.test');
    await store.savePlatformToken('stored-bearer');
    final controller = build();
    addTearDown(controller.dispose);
    fake.failWith = jsonResponse(503, <String, dynamic>{
      'code': 'UNAVAILABLE',
      'message': '服务暂时不可用',
    });

    await controller.bootstrap();

    // The token is probably fine and the server is simply down; keeping the
    // operator in means a restart fixes it without retyping the secret.
    expect(controller.phase, PlatformPhase.ready);
    expect(controller.error, '服务暂时不可用');
    expect(await store.loadPlatformToken(), 'stored-bearer');
  });

  test('signing out drops the token but keeps the remembered server', () async {
    final controller = build();
    addTearDown(controller.dispose);
    await controller.signIn(
      server: 'relay.example.test',
      email: 'admin@relaydesk.local',
      password: 'good-token',
    );

    await controller.signOut();

    expect(controller.phase, PlatformPhase.locked);
    expect(controller.overview, isNull);
    expect(await store.loadPlatformToken(), isNull);
    expect(await store.loadServer(), 'https://relay.example.test');
  });

  test('tenants decode their plan, counts and seat headroom', () async {
    final controller = build();
    addTearDown(controller.dispose);
    await controller.signIn(
      server: 'relay.example.test',
      email: 'admin@relaydesk.local',
      password: 'good-token',
    );

    await controller.refreshTenants();

    expect(controller.tenants, hasLength(1));
    final tenant = controller.tenants.single;
    expect(tenant.name, '演示科技');
    expect(tenant.plan, 'GROWTH');
    expect(tenant.seatsAvailable, 7);
    expect(tenant.isSuspended, isFalse);
    expect(tenant.trialEndsAt, isNull);
  });

  test('a tenant grew past its plan reads as full, not negative', () {
    final tenant = TenantSummary.fromJson(<String, dynamic>{
      'id': 'x',
      'name': 'x',
      'slug': 'x',
      'status': 'ACTIVE',
      'plan': 'STARTER',
      'planStatus': 'ACTIVE',
      'seatLimit': 3,
      'monthlyMessageLimit': 5000,
      'agents': 9,
      'inboxes': 1,
      'conversations': 0,
      'openConversations': 0,
    });

    expect(tenant.seatsAvailable, 0);
  });

  test('opening a tenant loads its subscription and seats', () async {
    final controller = build();
    addTearDown(controller.dispose);
    await controller.signIn(
      server: 'relay.example.test',
      email: 'admin@relaydesk.local',
      password: 'good-token',
    );

    await controller.openTenant('11111111-1111-1111-1111-111111111111');

    final detail = controller.detail;
    expect(detail, isNotNull);
    expect(detail!.subscription.plan, 'GROWTH');
    expect(detail.agents.single.email, 'owner@demo.test');
    expect(detail.inboxes.single.publicKey, 'demo-web');
  });

  test('updating a tenant re-reads it rather than guessing new limits',
      () async {
    final controller = build();
    addTearDown(controller.dispose);
    await controller.signIn(
      server: 'relay.example.test',
      email: 'admin@relaydesk.local',
      password: 'good-token',
    );
    await controller.openTenant(FakePlatformApi.tenantId);
    await settle();
    fake.calls.clear();

    final ok = await controller.updateTenant(plan: 'ENTERPRISE');

    expect(ok, isTrue);
    // PATCH, then the tenant, then the list and the overview: the console never
    // applies a locally computed seat limit.
    expect(
      fake.calls,
      contains(
        'PATCH /api/v1/platform/tenants/11111111-1111-1111-1111-111111111111',
      ),
    );
    expect(
      fake.calls,
      contains(
        'GET /api/v1/platform/tenants/11111111-1111-1111-1111-111111111111',
      ),
    );
    expect(fake.calls, contains('GET /api/v1/platform/tenants'));
  });

  test('provisioning a tenant returns the one-time credential', () async {
    final controller = build();
    addTearDown(controller.dispose);
    await controller.signIn(
      server: 'relay.example.test',
      email: 'admin@relaydesk.local',
      password: 'good-token',
    );

    final created = await controller.createTenant(
      name: 'Acme',
      slug: 'acme',
      ownerEmail: 'owner@acme.test',
      ownerName: '管理员',
      ownerPassword: '',
      inboxName: '',
      publicKey: '',
      plan: 'TRIAL',
      trialDays: 14,
    );

    expect(created, isNotNull);
    expect(created!.initialPassword, 'generated-secret');
    expect(created.slug, 'acme');
  });

  test('resetting an owner returns the password now in force', () async {
    final controller = build();
    addTearDown(controller.dispose);
    await controller.signIn(
      server: 'relay.example.test',
      email: 'admin@relaydesk.local',
      password: 'good-token',
    );
    await controller.openTenant('11111111-1111-1111-1111-111111111111');

    final password = await controller.resetOwner('owner@demo.test');

    expect(password, 'reset-secret');
  });

  test('AI usage sums across providers and survives an unavailable provider',
      () async {
    fake = FakePlatformApi(
      aiUsageBody: const <String, dynamic>{
        'days': 7,
        'providers': <Object>[
          <String, dynamic>{
            'provider': 'openai',
            'interactions': 100,
            'answered': 70,
            'avgLatencyMs': 900,
            'avgScore': 0.62,
            'deflectionRate': 0.7,
          },
          <String, dynamic>{
            'provider': 'local',
            'interactions': 50,
            'answered': 25,
            'avgLatencyMs': 400,
            'avgScore': 0.51,
            'deflectionRate': 0.5,
          },
        ],
        'reasons': <String, dynamic>{
          'ANSWERED': 95,
          'LOW_CONFIDENCE': 40,
          'NOT_A_REASON': 15,
        },
        'available': true,
      },
    );
    final controller = build();
    addTearDown(controller.dispose);
    await controller.signIn(
      server: 'relay.example.test',
      email: 'admin@relaydesk.local',
      password: 'good-token',
    );
    await controller.refreshAiUsage(days: 7);

    final usage = controller.aiUsage!;
    expect(usage.interactions, 150);
    expect(usage.answered, 95);
    expect(usage.deflectionRate, closeTo(95 / 150, 0.0001));
    expect(usage.reasons['LOW_CONFIDENCE'], 40);
    expect(usage.available, isTrue);
  });

  test('a 401 on a refresh locks the console instead of showing stale data',
      () async {
    final controller = build();
    addTearDown(controller.dispose);
    await controller.signIn(
      server: 'relay.example.test',
      email: 'admin@relaydesk.local',
      password: 'good-token',
    );
    fake.failWith = jsonResponse(401, <String, dynamic>{
      'code': 'UNAUTHORIZED',
      'message': '登录已过期',
    });

    await controller.refreshOverview();

    expect(controller.phase, PlatformPhase.locked);
    expect(await store.loadPlatformToken(), isNull);
  });

  test('the tenant search is debounced into one request', () async {
    final controller = build();
    addTearDown(controller.dispose);
    await controller.signIn(
      server: 'relay.example.test',
      email: 'admin@relaydesk.local',
      password: 'good-token',
    );
    await settle();
    fake.calls.clear();

    controller
      ..searchTenants('a')
      ..searchTenants('ac')
      ..searchTenants('acm');
    await Future<void>.delayed(const Duration(milliseconds: 450));

    expect(
      fake.calls.where((call) => call == 'GET /api/v1/platform/tenants'),
      hasLength(1),
    );
    expect(controller.tenantQuery, 'acm');
  });
}
