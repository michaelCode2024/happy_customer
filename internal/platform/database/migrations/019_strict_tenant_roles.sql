-- 重申企业角色约束；已经执行过017的环境也不得保留旧角色。
delete from agent_session where agent_id in (select id from agent where role in ('OWNER','ADMIN'));
update agent set role='SUPERVISOR',updated_at=now() where role in ('OWNER','ADMIN');
alter table agent drop constraint if exists agent_role_check;
alter table agent add constraint agent_role_check check(role in ('SUPERVISOR','AGENT'));
