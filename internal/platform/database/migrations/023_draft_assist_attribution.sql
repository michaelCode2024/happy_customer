-- 页面刷新或切换设备后，仍能将实际发送关联到此前采纳的 AI 草稿。
alter table message_draft add column if not exists assist_interaction_id uuid references ai_interaction(id) on delete set null;
