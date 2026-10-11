create table chat_group_room (
 id uuid primary key, group_id uuid not null references chat_group(id) on delete cascade,
 media_kind varchar(8) not null check(media_kind in ('AUDIO','VIDEO')),
 creator_kind varchar(8) not null, creator_id uuid not null,
 state varchar(8) not null default 'ACTIVE' check(state in ('ACTIVE','ENDED')),
 created_at timestamptz not null default now()
);
create unique index chat_group_room_active on chat_group_room(group_id) where state='ACTIVE';
create table chat_group_room_member (
 room_id uuid not null references chat_group_room(id) on delete cascade,
 actor_kind varchar(8) not null, actor_id uuid not null, session_id uuid not null,
 seen_at timestamptz not null default now(), muted boolean not null default false,
 camera boolean not null default false,
 primary key(room_id,actor_kind,actor_id)
);
create table chat_group_room_signal (
 id bigserial primary key, room_id uuid not null references chat_group_room(id) on delete cascade,
 sender_session uuid not null, recipient_session uuid not null,
 payload jsonb not null, created_at timestamptz not null default now()
);
create index chat_group_room_signal_receiver on chat_group_room_signal(room_id,recipient_session,id);
