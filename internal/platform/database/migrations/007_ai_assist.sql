-- Assistant calls and token accounting.
--
-- ai_interaction was written for one thing: the automatic bot answer, which
-- always belongs to a conversation. The assistant (summary, suggestion, tone
-- rewrite, translation) is an operator tool that runs with or without a thread
-- open, so the conversation reference becomes optional and the row gains the
-- task name. Token counts are recorded because they are the only honest way for
-- a tenant to see what the model budget was spent on; a price list TongYu
-- does not control would be a guess.
alter table ai_interaction alter column conversation_id drop not null;
alter table ai_interaction add column if not exists task varchar(30);
alter table ai_interaction add column if not exists prompt_tokens integer not null default 0;
alter table ai_interaction add column if not exists completion_tokens integer not null default 0;
alter table ai_interaction add column if not exists total_tokens integer not null default 0;
alter table ai_interaction add column if not exists agent_id uuid references agent(id) on delete set null;

-- Consumption reports group by task over a date range, which is the one query an
-- operator actually runs against this table.
create index if not exists idx_ai_interaction_tenant_task
    on ai_interaction(tenant_id, task, created_at desc);

comment on column ai_interaction.task is 'SUGGEST / SUMMARIZE / SENTIMENT / TRANSLATE / POLISH / NEXT_ACTION, or null for an automatic bot answer';
comment on column ai_interaction.agent_id is 'the operator the assistant ran for; null for automatic answers';
