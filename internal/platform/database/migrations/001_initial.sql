create table tenant (
    id uuid primary key,
    name varchar(120) not null,
    slug varchar(80) not null unique,
    status varchar(20) not null check (status in ('ACTIVE', 'SUSPENDED')),
    created_at timestamptz not null default now()
);

create table inbox (
    id uuid primary key,
    tenant_id uuid not null references tenant(id),
    name varchar(120) not null,
    public_key varchar(80) not null unique,
    status varchar(20) not null check (status in ('ACTIVE', 'DISABLED')),
    created_at timestamptz not null default now()
);
create index idx_inbox_tenant on inbox(tenant_id);

create table visitor (
    id uuid primary key,
    tenant_id uuid not null references tenant(id),
    inbox_id uuid not null references inbox(id),
    external_id varchar(160),
    display_name varchar(120),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create unique index uk_visitor_external on visitor(inbox_id, external_id) where external_id is not null;

create table conversation (
    id uuid primary key,
    tenant_id uuid not null references tenant(id),
    inbox_id uuid not null references inbox(id),
    visitor_id uuid not null references visitor(id),
    subject varchar(200),
    status varchar(20) not null check (status in ('OPEN', 'PENDING', 'RESOLVED')),
    last_sequence bigint not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create index idx_conversation_visitor on conversation(visitor_id, updated_at desc);
create index idx_conversation_tenant_status on conversation(tenant_id, status, updated_at desc);

create table message (
    id uuid primary key,
    tenant_id uuid not null references tenant(id),
    conversation_id uuid not null references conversation(id),
    sender_type varchar(20) not null check (sender_type in ('VISITOR', 'AGENT', 'SYSTEM')),
    sender_id uuid,
    client_message_id varchar(100),
    sequence bigint not null,
    message_type varchar(20) not null check (message_type in ('TEXT', 'IMAGE', 'FILE', 'EVENT')),
    content text not null,
    created_at timestamptz not null default now(),
    unique(conversation_id, sequence)
);
create unique index uk_message_client_id on message(conversation_id, client_message_id)
    where client_message_id is not null;
create index idx_message_conversation on message(conversation_id, sequence);
