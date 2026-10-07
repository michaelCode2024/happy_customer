-- Widens the constraints and adds the columns the console, the tenant admin API
-- and the platform operations API depend on. All of it is additive so an
-- already running deployment upgrades in place.

-- Supervisor is a real role: it can watch every inbox and read reports without
-- being allowed to change tenant settings.
alter table agent drop constraint agent_role_check;
alter table agent add constraint agent_role_check
    check (role in ('OWNER', 'ADMIN', 'SUPERVISOR', 'AGENT'));

-- SYSTEM covers join/leave notices, RICH carries structured bot payloads and
-- RATING holds the CSAT survey prompt. Widening the check keeps historical rows
-- valid because every existing value is still accepted.
alter table message drop constraint message_message_type_check;
alter table message add constraint message_message_type_check
    check (message_type in ('TEXT', 'IMAGE', 'FILE', 'EVENT', 'SYSTEM', 'RICH', 'RATING'));

-- Tenant level settings: branding, business hours, default locale and the
-- feature switches the admin console edits.
alter table tenant add column settings jsonb not null default '{}'::jsonb;
alter table tenant add column updated_at timestamptz not null default now();

-- Visitor facing widget behaviour per inbox. An empty allowed_domains array
-- means "no restriction", which is what a brand new inbox starts with.
alter table inbox add column allowed_domains text[] not null default '{}';
alter table inbox add column avatar_url text;
alter table inbox add column greeting_delay_seconds integer not null default 0;
alter table inbox add column locale varchar(20) not null default 'zh-CN';

-- Agent profile extras shown next to their messages.
alter table agent add column avatar_url text;
alter table agent add column signature text;

-- Attachment integrity: the checksum lets the download endpoint detect a
-- truncated or tampered object and the open API clients verify a re-upload.
alter table attachment add column checksum varchar(80);

-- One article per title per tenant. The importer matches on this key, and the
-- index keeps a tenant from ending up with two near-identical answers that the
-- bot would then have to choose between.
create unique index if not exists uk_knowledge_entry_title on knowledge_entry(tenant_id, lower(title));

-- Unanswered questions drive the knowledge gap report.
create index if not exists idx_ai_interaction_unanswered on ai_interaction(tenant_id, created_at desc)
    where answered = false;

-- Fast lookup for the widget's "which of my conversations are still open" call
-- and for the console's open-queue counts.
create index if not exists idx_conversation_visitor_open on conversation(visitor_id, last_message_at desc)
    where status <> 'RESOLVED';

-- The open API lists conversations by external visitor id, which is the key a
-- customer's own backend knows.
create index if not exists idx_visitor_external_id on visitor(tenant_id, external_id)
    where external_id is not null;
