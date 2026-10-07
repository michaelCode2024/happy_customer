create table agent (
    id uuid primary key,
    tenant_id uuid not null references tenant(id),
    email varchar(200) not null,
    display_name varchar(120) not null,
    password_hash text not null,
    role varchar(20) not null check (role in ('OWNER', 'ADMIN', 'AGENT')),
    status varchar(20) not null check (status in ('ACTIVE', 'DISABLED')),
    max_concurrent integer not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create unique index uk_agent_email on agent(tenant_id, lower(email));

create table agent_inbox (
    agent_id uuid not null references agent(id) on delete cascade,
    inbox_id uuid not null references inbox(id) on delete cascade,
    primary key (agent_id, inbox_id)
);

create table agent_session (
    id uuid primary key,
    agent_id uuid not null references agent(id) on delete cascade,
    token_hash bytea not null unique,
    created_at timestamptz not null default now(),
    expires_at timestamptz not null
);
create index idx_agent_session_agent on agent_session(agent_id);
create index idx_agent_session_expiry on agent_session(expires_at);

create table agent_presence (
    agent_id uuid primary key references agent(id) on delete cascade,
    status varchar(20) not null check (status in ('ONLINE', 'AWAY', 'OFFLINE')),
    last_seen_at timestamptz not null default now()
);

alter table visitor add column custom_attributes jsonb not null default '{}'::jsonb;
alter table visitor add column last_seen_at timestamptz;

alter table inbox add column auto_assign boolean not null default true;
alter table inbox add column welcome_message text;
alter table inbox add column offline_message text;
alter table inbox add column updated_at timestamptz not null default now();

alter table conversation add column assignee_id uuid references agent(id);
alter table conversation add column assigned_at timestamptz;
alter table conversation add column closed_at timestamptz;
alter table conversation add column priority smallint not null default 0;
alter table conversation add column last_message_at timestamptz not null default now();
alter table conversation add column last_message_preview varchar(200);
alter table conversation add column agent_unread integer not null default 0;
alter table conversation add column visitor_unread integer not null default 0;
create index idx_conversation_assignee on conversation(tenant_id, assignee_id, status, last_message_at desc);
create index idx_conversation_queue on conversation(tenant_id, inbox_id, last_message_at desc)
    where assignee_id is null and status <> 'RESOLVED';

create table conversation_read (
    conversation_id uuid not null references conversation(id) on delete cascade,
    reader_type varchar(10) not null check (reader_type in ('VISITOR', 'AGENT')),
    reader_id uuid not null,
    last_read_sequence bigint not null default 0,
    updated_at timestamptz not null default now(),
    primary key (conversation_id, reader_type, reader_id)
);

create table canned_response (
    id uuid primary key,
    tenant_id uuid not null references tenant(id),
    inbox_id uuid references inbox(id) on delete cascade,
    title varchar(120) not null,
    content text not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create index idx_canned_response_tenant on canned_response(tenant_id);

create table tag (
    id uuid primary key,
    tenant_id uuid not null references tenant(id),
    name varchar(40) not null,
    color varchar(16) not null default '#356ae6',
    created_at timestamptz not null default now()
);
create unique index uk_tag_name on tag(tenant_id, lower(name));

create table conversation_tag (
    conversation_id uuid not null references conversation(id) on delete cascade,
    tag_id uuid not null references tag(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (conversation_id, tag_id)
);

create table visitor_note (
    id uuid primary key,
    tenant_id uuid not null references tenant(id),
    visitor_id uuid not null references visitor(id) on delete cascade,
    author_agent_id uuid references agent(id) on delete set null,
    content text not null,
    created_at timestamptz not null default now()
);
create index idx_visitor_note_visitor on visitor_note(visitor_id, created_at desc);

create table api_key (
    id uuid primary key,
    tenant_id uuid not null references tenant(id) on delete cascade,
    name varchar(120) not null,
    key_prefix varchar(16) not null,
    key_hash bytea not null unique,
    status varchar(20) not null check (status in ('ACTIVE', 'REVOKED')),
    created_at timestamptz not null default now(),
    last_used_at timestamptz
);
create index idx_api_key_tenant on api_key(tenant_id);

create table webhook_endpoint (
    id uuid primary key,
    tenant_id uuid not null references tenant(id) on delete cascade,
    url text not null,
    secret text not null,
    events text[] not null,
    status varchar(20) not null check (status in ('ACTIVE', 'DISABLED')),
    created_at timestamptz not null default now()
);
create index idx_webhook_endpoint_tenant on webhook_endpoint(tenant_id);

create table webhook_delivery (
    id uuid primary key,
    endpoint_id uuid not null references webhook_endpoint(id) on delete cascade,
    tenant_id uuid not null references tenant(id) on delete cascade,
    event_type varchar(60) not null,
    payload jsonb not null,
    attempts integer not null default 0,
    status varchar(20) not null check (status in ('PENDING', 'SUCCEEDED', 'FAILED')),
    response_status integer,
    last_error text,
    next_attempt_at timestamptz not null default now(),
    created_at timestamptz not null default now(),
    delivered_at timestamptz
);
create index idx_webhook_delivery_due on webhook_delivery(next_attempt_at)
    where status = 'PENDING';
create index idx_webhook_delivery_tenant on webhook_delivery(tenant_id, created_at desc);

create table attachment (
    id uuid primary key,
    tenant_id uuid not null references tenant(id) on delete cascade,
    conversation_id uuid not null references conversation(id) on delete cascade,
    message_id uuid references message(id) on delete cascade,
    uploader_type varchar(10) not null check (uploader_type in ('VISITOR', 'AGENT', 'SYSTEM')),
    uploader_id uuid,
    file_name varchar(255) not null,
    content_type varchar(150) not null,
    size_bytes bigint not null,
    storage_key text not null,
    created_at timestamptz not null default now()
);
create index idx_attachment_conversation on attachment(conversation_id);
create index idx_attachment_message on attachment(message_id);

alter table message add column metadata jsonb;
