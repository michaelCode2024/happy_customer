-- Existing platform accounts were unrestricted operators; retain that access,
-- while newly provisioned platform accounts default to read-only ADMIN.
alter table platform_admin add column role varchar(20) not null default 'SUPER_ADMIN';
alter table platform_admin alter column role set default 'ADMIN';
alter table platform_admin add constraint platform_admin_role_check check (role in ('SUPER_ADMIN','ADMIN'));
alter table tenant_subscription add column monthly_ai_limit integer not null default 0 check(monthly_ai_limit>=0);
update tenant_subscription set monthly_ai_limit=case plan when 'GROWTH' then 5000 when 'ENTERPRISE' then 100000 else 0 end;
alter table tenant_subscription add column service_starts_at timestamptz;
alter table tenant_subscription add column service_ends_at timestamptz;
alter table tenant_subscription add constraint service_period_check check(service_starts_at is null or service_ends_at is null or service_ends_at>service_starts_at);
create table tenant_quota_bonus (
 tenant_id uuid not null references tenant(id), month date not null,
 messages bigint not null default 0 check(messages>=0), ai bigint not null default 0 check(ai>=0),
 primary key(tenant_id,month)
);
create table tenant_ai_quota_usage (
 tenant_id uuid not null references tenant(id), month date not null,
 used bigint not null default 0 check(used>=0), primary key(tenant_id,month)
);
insert into tenant_ai_quota_usage(tenant_id,month,used)
 select tenant_id,date_trunc('month',created_at)::date,count(*) from ai_interaction
 where answered group by tenant_id,date_trunc('month',created_at)::date;
create table quota_adjustment (
 id uuid primary key, request_id uuid not null unique,
 tenant_id uuid not null references tenant(id), actor_id uuid not null references platform_admin(id),
 mode varchar(10) not null check(mode in ('SET','ADD')), reason varchar(200) not null,
 request_value jsonb not null, before_value jsonb not null, after_value jsonb not null, created_at timestamptz not null default now()
);
create index quota_adjustment_time_idx on quota_adjustment(created_at desc);
create index quota_adjustment_tenant_idx on quota_adjustment(tenant_id,created_at desc);
