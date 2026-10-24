-- 入口级开关：自动分配成功后是否直接接单（默认关闭，仍需坐席点「开始接待」）。
alter table inbox
  add column if not exists auto_accept boolean not null default false;

comment on column inbox.auto_accept is '自动分配后是否自动确认接单；false 时仍需坐席手动接待';
