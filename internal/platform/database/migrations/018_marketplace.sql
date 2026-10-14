create table marketplace (
 id uuid primary key, name varchar(120) not null, key_hash bytea not null unique,
 status varchar(20) not null default 'ACTIVE' check(status in ('ACTIVE','DISABLED')),
 plan varchar(20) not null default 'ENTERPRISE' check(plan in ('STARTER','GROWTH','ENTERPRISE')),
 created_at timestamptz not null default now());
create table marketplace_shop (
 marketplace_id uuid not null references marketplace(id), external_id varchar(200) not null,
 tenant_id uuid not null unique references tenant(id), inbox_id uuid not null unique references inbox(id),
 primary key(marketplace_id,external_id));
create table marketplace_staff (
 marketplace_id uuid not null, shop_id varchar(200) not null, external_id varchar(200) not null,
 agent_id uuid not null unique references agent(id),
 primary key(marketplace_id,shop_id,external_id),
 foreign key(marketplace_id,shop_id) references marketplace_shop(marketplace_id,external_id));
create table marketplace_buyer_session (
 id uuid primary key, marketplace_id uuid not null references marketplace(id), external_id varchar(200) not null,
 expires_at timestamptz not null, revoked_at timestamptz);
create index marketplace_buyer_session_identity on marketplace_buyer_session(marketplace_id,external_id);
create index visitor_marketplace_identity on visitor(external_id,inbox_id) where external_id is not null;
