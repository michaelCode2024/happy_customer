-- AI knowledge base, bot routing and analytics materialization.

create extension if not exists pg_trgm;

create table knowledge_category (
    id uuid primary key,
    tenant_id uuid not null references tenant(id) on delete cascade,
    name varchar(80) not null,
    sort_order integer not null default 0,
    created_at timestamptz not null default now()
);
create unique index uk_knowledge_category on knowledge_category(tenant_id, lower(name));

create table knowledge_entry (
    id uuid primary key,
    tenant_id uuid not null references tenant(id) on delete cascade,
    category_id uuid references knowledge_category(id) on delete set null,
    title varchar(200) not null,
    content text not null,
    question_examples text not null default '',
    status varchar(20) not null check (status in ('ACTIVE', 'DISABLED')),
    hit_count bigint not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create index idx_knowledge_entry_tenant on knowledge_entry(tenant_id, status);
create index idx_knowledge_entry_search on knowledge_entry
    using gin (to_tsvector('simple', title || ' ' || content));
create index idx_knowledge_entry_trgm on knowledge_entry
    using gin ((title || ' ' || content) gin_trgm_ops);

-- Per-inbox AI behaviour: bot-first reply, quiet hours, human takeover.
create table ai_setting (
    inbox_id uuid primary key references inbox(id) on delete cascade,
    tenant_id uuid not null references tenant(id) on delete cascade,
    enabled boolean not null default false,
    greeting text,
    handoff_message text not null default '正在为你转接人工客服，请稍候。',
    confidence_threshold numeric(3, 2) not null default 0.35,
    updated_at timestamptz not null default now()
);

-- One row per automatic (or blocked) bot answer, so operators can audit the bot
-- and measure the deflection rate.
create table ai_interaction (
    id uuid primary key,
    tenant_id uuid not null references tenant(id) on delete cascade,
    conversation_id uuid not null references conversation(id) on delete cascade,
    question_message_id uuid references message(id) on delete set null,
    answer_message_id uuid references message(id) on delete set null,
    provider varchar(80) not null,
    score numeric(5, 4) not null default 0,
    answered boolean not null default false,
    reason varchar(40),
    latency_ms integer not null default 0,
    sources text[] not null default '{}',
    created_at timestamptz not null default now()
);
create index idx_ai_interaction_tenant on ai_interaction(tenant_id, created_at desc);
create index idx_ai_interaction_conversation on ai_interaction(conversation_id, created_at desc);

-- CSAT survey sent when an agent resolves a conversation.
create table conversation_rating (
    conversation_id uuid primary key references conversation(id) on delete cascade,
    tenant_id uuid not null references tenant(id) on delete cascade,
    score smallint not null check (score between 1 and 5),
    comment text,
    created_at timestamptz not null default now()
);
create index idx_conversation_rating_tenant on conversation_rating(tenant_id, created_at desc);

-- Idle / slow-response alerts for supervisors.
create table conversation_event (
    id uuid primary key,
    tenant_id uuid not null references tenant(id) on delete cascade,
    conversation_id uuid not null references conversation(id) on delete cascade,
    event_type varchar(40) not null,
    actor_type varchar(20),
    actor_id uuid,
    detail jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);
create index idx_conversation_event_conversation on conversation_event(conversation_id, created_at desc);
create index idx_conversation_event_tenant on conversation_event(tenant_id, created_at desc);

-- Per-tenant routing rules (round robin, load balanced, or fixed agent).
create table routing_rule (
    id uuid primary key,
    tenant_id uuid not null references tenant(id) on delete cascade,
    inbox_id uuid references inbox(id) on delete cascade,
    strategy varchar(30) not null check (strategy in ('ROUND_ROBIN', 'LOAD_BALANCED', 'FIXED')),
    fixed_agent_id uuid references agent(id) on delete set null,
    working_hours jsonb not null default '{}'::jsonb,
    max_concurrent integer not null default 5,
    enabled boolean not null default true,
    created_at timestamptz not null default now()
);
create index idx_routing_rule_tenant on routing_rule(tenant_id, enabled);

-- Denormalised counter cache for the operations dashboard so dashboards never
-- scan the message table.
create table tenant_daily_stat (
    tenant_id uuid not null references tenant(id) on delete cascade,
    stat_date date not null,
    conversations_started integer not null default 0,
    conversations_closed integer not null default 0,
    messages_in integer not null default 0,
    messages_out integer not null default 0,
    ai_answered integer not null default 0,
    ai_handoff integer not null default 0,
    first_response_seconds bigint not null default 0,
    first_response_samples integer not null default 0,
    rating_sum integer not null default 0,
    rating_count integer not null default 0,
    primary key (tenant_id, stat_date)
);

-- Audit trail for privileged operations.
create table audit_log (
    id uuid primary key,
    tenant_id uuid references tenant(id) on delete cascade,
    actor_type varchar(20) not null,
    actor_id uuid,
    action varchar(80) not null,
    target_type varchar(40),
    target_id uuid,
    ip inet,
    detail jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);
create index idx_audit_log_tenant on audit_log(tenant_id, created_at desc);

-- Platform level: which tenants exist, their plan and their quotas.
create table tenant_subscription (
    tenant_id uuid primary key references tenant(id) on delete cascade,
    plan varchar(30) not null check (plan in ('TRIAL', 'STARTER', 'GROWTH', 'ENTERPRISE')),
    status varchar(20) not null check (status in ('ACTIVE', 'PAST_DUE', 'CANCELED')),
    seat_limit integer not null default 3,
    monthly_message_limit integer not null default 5000,
    trial_ends_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- Offline messages captured while no agent is available.
alter table conversation add column source varchar(20) not null default 'WEB';
create index idx_conversation_source on conversation(tenant_id, source);

-- First response timing powers the SLA widget on the operations dashboard.
alter table conversation add column first_response_at timestamptz;

-- JWT-style agent tokens embed a session id; this table makes force-logout work.
alter table agent_session add column user_agent varchar(300);
