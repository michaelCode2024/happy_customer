-- 第三方群主复用访客映射，不创建客服账号。旧群默认仍由客服持有。
alter table chat_group drop constraint chat_group_owner_id_fkey;
alter table chat_group add column owner_kind varchar(10) not null default 'agent'
 check (owner_kind in ('agent','widget'));
alter table chat_group add column external_group_id varchar(200);
alter table chat_group add constraint chat_group_external_owner_service
 check (owner_kind='agent' or (kind='SERVICE' and inbox_id is not null));
create unique index chat_group_external_key on chat_group(tenant_id,inbox_id,external_group_id)
 where external_group_id is not null;
