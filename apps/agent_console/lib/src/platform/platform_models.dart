/// Wire models for the RelayDesk operations console.
///
/// The operations API crosses tenants, which is exactly what the agent console
/// must never do, so these types are deliberately separate from `models.dart`:
/// nothing here is reachable from the workbench, and nothing there is reachable
/// from here.
library;

import 'package:relaydesk_agent_console/src/api/models.dart';

/// Coerces a JSON array of strings, dropping anything that is not one. The
/// feature list is decoration on the about panel: a shape change there must not
/// take the whole screen down with it.
Iterable<String> asStringList(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  return value.whereType<String>();
}

/// A plan in the commercial sense: what a tenant bought, and how much of it is
/// left. [planStatus] is the billing state (`ACTIVE`, `PAST_DUE`, `CANCELED`) and
/// is separate from the tenant's own [TenantSummary.status] (`ACTIVE`,
/// `SUSPENDED`): an account can be suspended for abuse while its billing is
/// perfectly current.
class TenantSummary {
  const TenantSummary({
    required this.id,
    required this.name,
    required this.slug,
    required this.status,
    required this.createdAt,
    required this.plan,
    required this.planStatus,
    required this.seatLimit,
    required this.monthlyMessageLimit,
    required this.trialEndsAt,
    required this.agents,
    required this.inboxes,
    required this.conversations,
    required this.openConversations,
  });

  factory TenantSummary.fromJson(Map<String, dynamic> json) => TenantSummary(
        id: asString(json['id']),
        name: asString(json['name']),
        slug: asString(json['slug']),
        status: asString(json['status']),
        createdAt: asDate(json['createdAt']),
        plan: asString(json['plan']),
        planStatus: asString(json['planStatus']),
        seatLimit: asInt(json['seatLimit']),
        monthlyMessageLimit: asInt(json['monthlyMessageLimit']),
        trialEndsAt: asDate(json['trialEndsAt']),
        agents: asInt(json['agents']),
        inboxes: asInt(json['inboxes']),
        conversations: asInt(json['conversations']),
        openConversations: asInt(json['openConversations']),
      );

  final String id;
  final String name;
  final String slug;
  final String status;
  final DateTime? createdAt;
  final String plan;
  final String planStatus;
  final int seatLimit;
  final int monthlyMessageLimit;
  final DateTime? trialEndsAt;
  final int agents;
  final int inboxes;
  final int conversations;
  final int openConversations;

  bool get isSuspended => status == 'SUSPENDED';

  /// How many seats are unused, floored at zero: a tenant that grew past its
  /// plan (an enterprise downgrade) should read as "full", not as a negative.
  int get seatsAvailable {
    final left = seatLimit - agents;
    return left < 0 ? 0 : left;
  }
}

/// One row of the tenant detail's 30-day usage table.
class TenantUsageDay {
  const TenantUsageDay({
    required this.date,
    required this.conversationsStarted,
    required this.messagesIn,
    required this.messagesOut,
    required this.aiAnswered,
    required this.aiHandoff,
  });

  factory TenantUsageDay.fromJson(Map<String, dynamic> json) => TenantUsageDay(
        date: asString(json['date']),
        conversationsStarted: asInt(json['conversationsStarted']),
        messagesIn: asInt(json['messagesIn']),
        messagesOut: asInt(json['messagesOut']),
        aiAnswered: asInt(json['aiAnswered']),
        aiHandoff: asInt(json['aiHandoff']),
      );

  final String date;
  final int conversationsStarted;
  final int messagesIn;
  final int messagesOut;
  final int aiAnswered;
  final int aiHandoff;

  int get total => messagesIn + messagesOut;
}

class TenantSubscription {
  const TenantSubscription({
    required this.plan,
    required this.status,
    required this.seatLimit,
    required this.monthlyMessageLimit,
    required this.trialEndsAt,
  });

  factory TenantSubscription.fromJson(Map<String, dynamic> json) =>
      TenantSubscription(
        plan: asString(json['plan']),
        status: asString(json['status']),
        seatLimit: asInt(json['seatLimit']),
        monthlyMessageLimit: asInt(json['monthlyMessageLimit']),
        trialEndsAt: asDate(json['trialEndsAt']),
      );

  static const TenantSubscription empty = TenantSubscription(
    plan: '',
    status: '',
    seatLimit: 0,
    monthlyMessageLimit: 0,
    trialEndsAt: null,
  );

  final String plan;
  final String status;
  final int seatLimit;
  final int monthlyMessageLimit;
  final DateTime? trialEndsAt;
}

/// A seat inside a tenant, as seen from outside it.
class TenantAgent {
  const TenantAgent({
    required this.id,
    required this.email,
    required this.displayName,
    required this.role,
    required this.status,
    required this.presence,
  });

  factory TenantAgent.fromJson(Map<String, dynamic> json) => TenantAgent(
        id: asString(json['id']),
        email: asString(json['email']),
        displayName: asString(json['displayName']),
        role: asString(json['role']),
        status: asString(json['status']),
        presence: asString(json['presence']),
      );

  final String id;
  final String email;
  final String displayName;
  final String role;
  final String status;
  final String presence;

  bool get isOnline => presence == 'ONLINE';

  /// The two synthetic accounts every tenant gets. They are real rows with a
  /// disabled password, so an operator seeing them in the list needs to be told
  /// they are not seats anyone can sign in with.
  bool get isSystemAccount =>
      email == 'bot@relaydesk.local' || email == 'integration@relaydesk.local';
}

class TenantInbox {
  const TenantInbox({
    required this.id,
    required this.name,
    required this.publicKey,
    required this.status,
  });

  factory TenantInbox.fromJson(Map<String, dynamic> json) => TenantInbox(
        id: asString(json['id']),
        name: asString(json['name']),
        publicKey: asString(json['publicKey']),
        status: asString(json['status']),
      );

  final String id;
  final String name;
  final String publicKey;
  final String status;
}

/// Everything the tenant detail pane shows.
class TenantDetail {
  const TenantDetail({
    required this.id,
    required this.name,
    required this.slug,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.subscription,
    required this.agents,
    required this.inboxes,
    required this.usage,
  });

  factory TenantDetail.fromJson(Map<String, dynamic> json) => TenantDetail(
        id: asString(json['id']),
        name: asString(json['name']),
        slug: asString(json['slug']),
        status: asString(json['status']),
        createdAt: asDate(json['createdAt']),
        updatedAt: asDate(json['updatedAt']),
        subscription: TenantSubscription.fromJson(
          asMap(json['subscription']),
        ),
        agents: asMapList(json['agents']).map(TenantAgent.fromJson).toList(),
        inboxes: asMapList(json['inboxes']).map(TenantInbox.fromJson).toList(),
        usage: asMapList(json['usage']).map(TenantUsageDay.fromJson).toList(),
      );

  final String id;
  final String name;
  final String slug;
  final String status;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final TenantSubscription subscription;
  final List<TenantAgent> agents;
  final List<TenantInbox> inboxes;

  /// Newest first, which is the order the server returns.
  final List<TenantUsageDay> usage;

  bool get isSuspended => status == 'SUSPENDED';
}

/// The headline counters on the overview screen.
class PlatformOverview {
  const PlatformOverview({
    required this.tenants,
    required this.activeTenants,
    required this.agents,
    required this.conversations,
    required this.openConversations,
    required this.messagesToday,
    required this.planDistribution,
    required this.topTenants,
    required this.instance,
    required this.realtimeConnections,
    required this.aiProvider,
    required this.serverTime,
  });

  factory PlatformOverview.fromJson(Map<String, dynamic> json) =>
      PlatformOverview(
        tenants: asInt(json['tenants']),
        activeTenants: asInt(json['activeTenants']),
        agents: asInt(json['agents']),
        conversations: asInt(json['conversations']),
        openConversations: asInt(json['openConversations']),
        messagesToday: asInt(json['messagesToday']),
        planDistribution: asMapList(json['planDistribution'])
            .map(PlanCount.fromJson)
            .toList(),
        topTenants:
            asMapList(json['topTenants']).map(TopTenant.fromJson).toList(),
        instance: asString(json['instance']),
        realtimeConnections: asInt(json['realtimeConnections']),
        aiProvider: asString(json['aiProvider']),
        serverTime: asDate(json['serverTime']),
      );

  final int tenants;
  final int activeTenants;
  final int agents;
  final int conversations;
  final int openConversations;
  final int messagesToday;
  final List<PlanCount> planDistribution;
  final List<TopTenant> topTenants;

  /// Which instance served the request. With LISTEN/NOTIFY as the realtime bus
  /// this is informational, but during an incident it is the first thing worth
  /// knowing about a load-balanced deployment.
  final String instance;
  final int realtimeConnections;
  final String aiProvider;
  final DateTime? serverTime;

  int get suspendedTenants => tenants - activeTenants;
}

class PlanCount {
  const PlanCount({required this.plan, required this.tenants});

  factory PlanCount.fromJson(Map<String, dynamic> json) => PlanCount(
        plan: asString(json['plan']),
        tenants: asInt(json['tenants']),
      );

  final String plan;
  final int tenants;
}

class TopTenant {
  const TopTenant({
    required this.tenantId,
    required this.name,
    required this.slug,
    required this.status,
    required this.conversations7d,
    required this.agents,
  });

  factory TopTenant.fromJson(Map<String, dynamic> json) => TopTenant(
        tenantId: asString(json['tenantId']),
        name: asString(json['name']),
        slug: asString(json['slug']),
        status: asString(json['status']),
        conversations7d: asInt(json['conversations7d']),
        agents: asInt(json['agents']),
      );

  final String tenantId;
  final String name;
  final String slug;
  final String status;
  final int conversations7d;
  final int agents;
}

/// AI deflection for one provider over the queried window.
class AiProviderUsage {
  const AiProviderUsage({
    required this.provider,
    required this.interactions,
    required this.answered,
    required this.avgLatencyMs,
    required this.avgScore,
    required this.deflectionRate,
  });

  factory AiProviderUsage.fromJson(Map<String, dynamic> json) =>
      AiProviderUsage(
        provider: asString(json['provider']),
        interactions: asInt(json['interactions']),
        answered: asInt(json['answered']),
        avgLatencyMs: asInt(json['avgLatencyMs']),
        avgScore: asDouble(json['avgScore']),
        deflectionRate: asDouble(json['deflectionRate']),
      );

  final String provider;
  final int interactions;
  final int answered;
  final int avgLatencyMs;
  final double avgScore;
  final double deflectionRate;
}

/// Why the AI stopped answering: `ANSWERED` is a deflection, every other reason
/// is a handoff to a human.
class PlatformAiUsage {
  const PlatformAiUsage({
    required this.days,
    required this.providers,
    required this.reasons,
    required this.available,
  });

  factory PlatformAiUsage.fromJson(Map<String, dynamic> json) =>
      PlatformAiUsage(
        days: asInt(json['days']),
        providers:
            asMapList(json['providers']).map(AiProviderUsage.fromJson).toList(),
        reasons: <String, int>{
          for (final entry in asMap(json['reasons']).entries)
            entry.key: asInt(entry.value),
        },
        available: asBool(json['available']),
      );

  final int days;
  final List<AiProviderUsage> providers;
  final Map<String, int> reasons;

  /// Whether a model provider is configured at all. With none, every count is
  /// zero for a reason that has nothing to do with customer behaviour, so the
  /// screen says so rather than letting the operator read an idle instance as a
  /// broken one.
  final bool available;

  int get interactions =>
      providers.fold(0, (sum, provider) => sum + provider.interactions);

  int get answered =>
      providers.fold(0, (sum, provider) => sum + provider.answered);

  double get deflectionRate => interactions == 0 ? 0 : answered / interactions;
}

/// What the instance reports about itself, shown in the console's about panel.
class PlatformMeta {
  const PlatformMeta({
    required this.product,
    required this.version,
    required this.model,
    required this.aiProvider,
    required this.aiAvailable,
    required this.storage,
    required this.uploadMaxMB,
    required this.webhookAttempts,
    required this.platformFeatures,
  });

  factory PlatformMeta.fromJson(Map<String, dynamic> json) => PlatformMeta(
        product: asString(json['product']),
        version: asString(json['version']),
        model: asString(json['model']),
        aiProvider: asString(json['aiProvider']),
        aiAvailable: asBool(json['aiAvailable']),
        storage: asString(json['storage']),
        uploadMaxMB: asInt(json['uploadMaxMB']),
        webhookAttempts: asInt(json['webhookAttempts']),
        platformFeatures:
            asStringList(json['platformFeatures']).toList(growable: false),
      );

  final String product;
  final String version;
  final String model;
  final String aiProvider;
  final bool aiAvailable;
  final String storage;
  final int uploadMaxMB;
  final int webhookAttempts;
  final List<String> platformFeatures;
}

/// The result of provisioning a tenant.
///
/// [initialPassword] is present only when the server generated one, and it is
/// shown exactly once: the server stores a hash, so a lost value means the
/// break-glass reset, not a re-read.
class CreatedTenant {
  const CreatedTenant({
    required this.tenantId,
    required this.slug,
    required this.plan,
    required this.ownerEmail,
    required this.inboxId,
    required this.publicKey,
    required this.scriptUrl,
    required this.initialPassword,
  });

  factory CreatedTenant.fromJson(Map<String, dynamic> json) => CreatedTenant(
        tenantId: asString(json['tenantId']),
        slug: asString(json['slug']),
        plan: asString(json['plan']),
        ownerEmail: asString(json['ownerEmail']),
        inboxId: asString(json['inboxId']),
        publicKey: asString(json['publicKey']),
        scriptUrl: asString(json['scriptUrl']),
        initialPassword: asString(json['initialPassword']),
      );

  final String tenantId;
  final String slug;
  final String plan;
  final String ownerEmail;
  final String inboxId;
  final String publicKey;
  final String scriptUrl;
  final String initialPassword;
}
