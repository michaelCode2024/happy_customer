-- 通知独立于会话回执，按企业和坐席隔离；刷新和换设备不会丢失未读状态。
create table if not exists agent_notification (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references tenant(id) on delete cascade,
 agent_id uuid not null references agent(id) on delete cascade,
 conversation_id uuid not null references conversation(id) on delete cascade,
 message_id uuid references message(id) on delete cascade,
 kind text not null default 'MESSAGE',
 title text not null,
 created_at timestamptz not null default now(),
 read_at timestamptz,
 unique(agent_id,message_id)
);
create index if not exists idx_agent_notification_unread on agent_notification(agent_id,created_at desc) where read_at is null;
create table if not exists push_subscription (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references tenant(id) on delete cascade,
 agent_id uuid not null references agent(id) on delete cascade,
 session_id uuid not null references agent_session(id) on delete cascade,
 endpoint text not null unique,
 p256dh text not null,
 auth text not null,
 updated_at timestamptz not null default now()
);
create table if not exists push_delivery (
 notification_id uuid not null references agent_notification(id) on delete cascade,
 subscription_id uuid not null references push_subscription(id) on delete cascade,
 attempts integer not null default 0,
 next_attempt_at timestamptz not null default now(),
 completed_at timestamptz,
 primary key(notification_id,subscription_id)
);
-- VAPID 私钥仅保留服务端数据库，客户端仅取得公钥。
create table if not exists push_identity (id boolean primary key default true check(id),private_key text not null,public_key text not null);
