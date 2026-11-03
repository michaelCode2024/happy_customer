-- 转交后原接待人仍可回看。只记曾经接过或回复过的客服，不把整组入口成员放进来。
create table if not exists conversation_participant (
    conversation_id uuid not null references conversation(id) on delete cascade,
    agent_id uuid not null references agent(id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (conversation_id, agent_id)
);
create index if not exists idx_conversation_participant_agent
    on conversation_participant(agent_id, conversation_id);

insert into conversation_participant(conversation_id, agent_id)
select id, assignee_id from conversation where assignee_id is not null
on conflict do nothing;

insert into conversation_participant(conversation_id, agent_id)
select distinct conversation_id, sender_id from message
 where sender_type = 'AGENT' and sender_id is not null
on conflict do nothing;

insert into conversation_participant(conversation_id, agent_id)
select target_id, actor_id from audit_log
 where action = 'conversation.transfer'
   and target_type = 'conversation'
   and actor_id is not null
on conflict do nothing;

-- 0 表示不自动结束；其余只能是 15 分钟到 4 小时。默认 30，与原先的服务端默认一致。
alter table tenant
    add column if not exists conversation_auto_close_minutes integer not null default 30;

alter table tenant drop constraint if exists tenant_auto_close_minutes_check;
alter table tenant
    add constraint tenant_auto_close_minutes_check
    check (conversation_auto_close_minutes = 0
        or conversation_auto_close_minutes between 15 and 240);
