-- Open API support.
--
-- The tenant-facing open API is authenticated by the api_key rows created in
-- 002, but a key needs to declare what it may do. An empty scope list keeps the
-- historical behaviour of full access, so keys issued before this migration
-- continue to work unchanged.

alter table api_key add column if not exists scopes text[] not null default '{}';
alter table api_key add column if not exists description text;
alter table api_key add column if not exists expires_at timestamptz;
alter table api_key add column if not exists revoked_at timestamptz;
alter table api_key add column if not exists request_count bigint not null default 0;

comment on column api_key.scopes is
    'Allowed open API scopes: read, write, admin. Empty means all scopes.';

-- The visitor profile was anonymous-only until now. A tenant's own backend
-- identifies customers by their own account id and contact details, so the open
-- API needs somewhere to keep them.
alter table visitor add column if not exists email varchar(200);
alter table visitor add column if not exists phone varchar(60);
alter table visitor add column if not exists locale varchar(20);
alter table visitor add column if not exists country varchar(80);
alter table visitor add column if not exists timezone varchar(80);
alter table visitor add column if not exists notes text;

-- last_seen_at is nullable from 002; new rows get a value so ordering and
-- listing are stable.
update visitor set last_seen_at = coalesce(last_seen_at, created_at) where last_seen_at is null;

-- The open API filters and orders conversations by these columns on every
-- listing call.
create index if not exists idx_conversation_tenant_status_updated
    on conversation(tenant_id, status, updated_at desc);
create index if not exists idx_conversation_tenant_visitor
    on conversation(tenant_id, visitor_id, created_at desc);
create index if not exists idx_message_conversation_sequence
    on message(conversation_id, sequence);

-- Customer lookup by name, contact details or the tenant's own external id.
create index if not exists idx_visitor_tenant_last_seen
    on visitor(tenant_id, last_seen_at desc);
create index if not exists idx_visitor_external_id_lower
    on visitor(tenant_id, lower(external_id));
create index if not exists idx_visitor_email_lower
    on visitor(tenant_id, lower(email));
