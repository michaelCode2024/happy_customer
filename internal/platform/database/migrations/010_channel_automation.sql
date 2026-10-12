create table inbox_automation (
 inbox_id uuid primary key references inbox(id) on delete cascade,
 tenant_id uuid not null references tenant(id) on delete cascade,
 config jsonb not null default '{}', revision bigint not null default 1,
 updated_at timestamptz not null default now()
);
alter table conversation add column bot_paused boolean not null default false;
create table automation_delivery (
 conversation_id uuid primary key references conversation(id) on delete cascade,
 question_id uuid not null, replied_at timestamptz not null default now()
);
