create table chat_group (
 id uuid primary key, tenant_id uuid not null references tenant(id), inbox_id uuid references inbox(id),
 name varchar(120) not null, kind varchar(20) not null check(kind in ('INTERNAL','SERVICE')),
 owner_id uuid not null references agent(id), announcement text not null default '',
 sequence bigint not null default 0, archived boolean not null default false,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table chat_group_member (
 group_id uuid not null references chat_group(id), actor_kind varchar(10) not null check(actor_kind in ('agent','widget')),
 actor_id uuid not null, name varchar(120) not null, last_read bigint not null default 0,
 primary key(group_id,actor_kind,actor_id));
create table chat_group_message (
 id uuid primary key, group_id uuid not null references chat_group(id), sequence bigint not null,
 actor_kind varchar(10) not null, actor_id uuid not null, name varchar(120) not null,
 content text not null, client_id uuid not null, created_at timestamptz not null default now(),
 unique(group_id,sequence), unique(group_id,actor_kind,actor_id,client_id));
create table chat_group_invite (
 token_hash varchar(64) primary key, group_id uuid not null references chat_group(id), expires_at timestamptz not null,
 revoked boolean not null default false);
create index chat_group_tenant on chat_group(tenant_id,updated_at desc);
create index chat_group_actor on chat_group_member(actor_kind,actor_id);
