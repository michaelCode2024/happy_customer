-- 推送只提醒真正离开工作台的人：可见焦点单独记，不复用坐席手工设置的 ONLINE/AWAY。
alter table agent_presence add column if not exists focused_at timestamptz;

-- 投递轮询按 next_attempt_at 取待发记录，未完成的部分索引避免全表扫描。
create index if not exists idx_push_delivery_pending
    on push_delivery(next_attempt_at)
    where completed_at is null;
