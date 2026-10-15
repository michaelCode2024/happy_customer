-- 草稿反馈与最终发送分开统计，不能把插入输入框算成客户问题已解决。
alter table ai_interaction add column if not exists draft_text text not null default '';
alter table ai_interaction add column if not exists adopted_at timestamptz;
alter table ai_interaction add column if not exists feedback text check (feedback in ('HELPFUL','NEEDS_WORK'));
alter table ai_interaction add column if not exists feedback_at timestamptz;
alter table ai_interaction add column if not exists sent_message_id uuid references message(id) on delete set null;
alter table ai_interaction add column if not exists edited_before_send boolean;

-- 按原问题关联知识；停用或删除知识后，缺口重新进入待补充列表。
create table if not exists knowledge_gap_resolution (
 tenant_id uuid not null references tenant(id) on delete cascade,
 question_hash text not null,
 question text not null,
 knowledge_id uuid not null references knowledge_entry(id) on delete cascade,
 resolved_by uuid not null references agent(id),
 resolved_at timestamptz not null default now(),
 primary key (tenant_id, question_hash)
);
