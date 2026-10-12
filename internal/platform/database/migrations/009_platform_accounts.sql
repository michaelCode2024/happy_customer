create table platform_admin (
 id uuid primary key,
 email varchar(200) not null unique,
 display_name varchar(100) not null,
 password_hash text not null,
 status varchar(16) not null default 'ACTIVE' check(status in ('ACTIVE','DISABLED')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 last_login_at timestamptz
);
create table platform_session (
 id uuid primary key,
 admin_id uuid not null references platform_admin(id) on delete cascade,
 expires_at timestamptz not null,
 revoked_at timestamptz,
 created_at timestamptz not null default now()
);
create index platform_session_admin_idx on platform_session(admin_id);
