-- 空闲会话自动结束的扫描走的是
--   where status <> 'RESOLVED' and last_message_at <= $1 order by last_message_at。
-- 已有索引都带 tenant_id 或按 updated_at 排，没法直接跳到「最早还没结束」的那批，
-- 每分钟一轮会退化成全表扫。补一条只覆盖未结束会话的部分索引。
create index if not exists idx_conversation_idle_close
    on conversation(last_message_at)
    where status <> 'RESOLVED';
