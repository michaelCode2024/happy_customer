-- 别人代设的密码（开通席位、重置密码）要由本人登录后先改掉。已有账号默认不强制。
alter table agent add column if not exists must_change_password boolean not null default false;
