alter table conversation add column accepted_at timestamptz;
alter table conversation add column assignment_expires_at timestamptz;
alter table conversation add column handoff_requested_at timestamptz;
-- 已有会话保持接待状态，新分配需要客服主动确认。
update conversation set accepted_at=coalesce(assigned_at,created_at) where assignee_id is not null;
alter table routing_rule add column acceptance_timeout_seconds integer not null default 60
 check (acceptance_timeout_seconds between 10 and 600);
create table reception_timeout (
 conversation_id uuid not null references conversation(id) on delete cascade,
 agent_id uuid not null references agent(id) on delete cascade,
 primary key(conversation_id,agent_id)
);
create table reception_notice (
 id bigserial primary key,
 tenant_id uuid not null references tenant(id) on delete cascade,
 conversation_id uuid not null references conversation(id) on delete cascade,
 content text not null,
 state text not null,
 delivered boolean not null default false
);
create index reception_pending on conversation(assignment_expires_at) where accepted_at is null and status<>'RESOLVED';
create index reception_queued on conversation(updated_at) where assignee_id is null and handoff_requested_at is not null and status<>'RESOLVED';
create index reception_undelivered on reception_notice(id) where not delivered;
