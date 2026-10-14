-- 福利群默认保留旧群行为；新建外部群可选更大容量及实名邀请。
alter table chat_group add column max_members integer not null default 100 check (max_members between 2 and 5000);
alter table chat_group add column speaking_mode varchar(20) not null default 'ALL' check (speaking_mode in ('ALL','MANAGERS'));
alter table chat_group add column require_identity boolean not null default false;
alter table chat_group_member add column is_manager boolean not null default false;
