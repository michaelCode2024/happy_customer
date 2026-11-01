-- 入口级宽限期：会话结束后访客在时限内再发言复活原会话（延续上下文与原接待人），
-- 超时后自动新建会话进入待接待大厅，由所有在线客服按路由规则接待或抢单。
alter table inbox
  add column if not exists reopen_grace_minutes integer not null default 1440
    check (reopen_grace_minutes >= 0);

comment on column inbox.reopen_grace_minutes is '结束后访客再发言的宽限分钟数；0 表示结束后再发言一律新建会话进大厅';
