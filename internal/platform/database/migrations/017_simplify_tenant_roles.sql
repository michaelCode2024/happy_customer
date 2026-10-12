-- 企业侧只有客服主管和客服坐席；平台角色不受此迁移影响。
delete from agent_session
 where agent_id in (select id from agent where role in ('OWNER','ADMIN'));
update agent set role='SUPERVISOR',updated_at=now() where role in ('OWNER','ADMIN');
alter table agent drop constraint agent_role_check;
alter table agent add constraint agent_role_check check(role in ('SUPERVISOR','AGENT'));
