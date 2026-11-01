-- 接入管理页每次打开都要回答「这个客服入口最近有没有访客接入」，
-- 走的是 select max(last_seen_at) from visitor where tenant_id=$1 and inbox_id=$2。
-- 005 建的 visitor(tenant_id, last_seen_at desc) 缺 inbox_id，取单个入口的
-- 最大值仍要回表扫完整个租户的访客。补一条带入口的索引，让这次查询能直接
-- 定位到该入口的最后一行。
create index if not exists idx_visitor_inbox_last_seen
    on visitor(tenant_id, inbox_id, last_seen_at desc);
