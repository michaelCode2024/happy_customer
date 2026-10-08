-- The message layer, brought up to what a modern chat product expects.
--
-- Everything added here hangs off one idea: a message is not a finished row the
-- moment it is inserted. It can be replied to, edited, recalled, reacted to and
-- searched, and each agent device keeps its own delivery and read cursor. The
-- previous schema could only append, which is why the console had no way to
-- show a quoted reply or fix a typo.

alter table message add column if not exists reply_to_id uuid references message(id) on delete set null;
alter table message add column if not exists edited_at timestamptz;
alter table message add column if not exists deleted_at timestamptz;
alter table message add column if not exists deleted_by uuid;
alter table message add column if not exists pinned_at timestamptz;
alter table message add column if not exists pinned_by uuid;
alter table message add column if not exists forwarded_from_id uuid references message(id) on delete set null;

-- Internal notes already travelled as an EVENT message carrying
-- metadata.private; the metadata flag alone was invisible to SQL, so a note
-- could not be filtered out at the query level. Promoting it to a real column
-- makes "the visitor must never receive this" expressible in a where clause and
-- therefore impossible to forget in a new endpoint.
alter table message add column if not exists is_private boolean not null default false;

update message set is_private = true
 where metadata is not null and metadata ->> 'private' = 'true';

create index if not exists idx_message_private on message(conversation_id) where is_private;
create index if not exists idx_message_reply on message(reply_to_id) where reply_to_id is not null;
create index if not exists idx_message_pinned on message(conversation_id, pinned_at desc) where pinned_at is not null;

-- Message types the product always advertised but the check constraint
-- rejected. AUDIO is voice notes, VIDEO is screen recordings, LOCATION is the
-- visitor sharing where they are, and CARD is a structured payload rendered by
-- the client (order status, tracking number, an action button).
alter table message drop constraint if exists message_message_type_check;
alter table message add constraint message_message_type_check
    check (message_type in ('TEXT', 'IMAGE', 'FILE', 'EVENT', 'SYSTEM', 'RICH', 'RATING', 'AUDIO', 'VIDEO', 'LOCATION', 'CARD'));

-- Full-text search over the transcript. This is a stored generated column: the
-- two-argument to_tsvector is immutable because the configuration is pinned to
-- 'simple', so PostgreSQL accepts it where to_tsvector(regconfig) would not.
-- The 'simple' dictionary is deliberate — it does not stem English words and it
-- keeps Chinese characters intact, which is the only sane default when a single
-- index has to serve both languages. Substring search over CJK is handled by the
-- trigram index below, exactly as the knowledge base already does it.
alter table message add column if not exists search_vector tsvector
    generated always as (to_tsvector('simple', coalesce(content, ''))) stored;
create index if not exists idx_message_search on message using gin (search_vector);
create index if not exists idx_message_content_trgm on message using gin (content gin_trgm_ops);

-- Reactions. One row per (message, actor, emoji), so tapping the same emoji
-- twice removes it by deleting the row rather than accumulating duplicates.
create table if not exists message_reaction (
    message_id uuid not null references message(id) on delete cascade,
    tenant_id uuid not null references tenant(id) on delete cascade,
    actor_type varchar(20) not null check (actor_type in ('VISITOR', 'AGENT', 'SYSTEM')),
    actor_id uuid not null,
    emoji varchar(32) not null,
    created_at timestamptz not null default now(),
    primary key (message_id, actor_type, actor_id, emoji)
);
create index if not exists idx_message_reaction_message on message_reaction(message_id);

-- Per-conversation drafts, keyed by author, so an agent can start a reply on a
-- laptop and finish it on a phone. Keeping this server-side rather than in local
-- storage is what makes that work.
create table if not exists message_draft (
    conversation_id uuid not null references conversation(id) on delete cascade,
    tenant_id uuid not null references tenant(id) on delete cascade,
    agent_id uuid not null references agent(id) on delete cascade,
    content text not null default '',
    updated_at timestamptz not null default now(),
    primary key (conversation_id, agent_id)
);
create index if not exists idx_message_draft_agent on message_draft(agent_id, updated_at desc);

-- Delivery receipts are a separate cursor from read receipts: "your phone got
-- it" and "the visitor looked at it" are different facts, and a chat product
-- that conflates them cannot show the single grey tick. conversation_read
-- already models read; this adds delivered alongside it.
alter table conversation_read add column if not exists last_delivered_sequence bigint not null default 0;

-- Unread beyond what the denormalised counter can express: an agent who joined
-- a conversation late wants a "new messages" divider, and the exact sequence to
-- place it at is the read cursor at the moment they opened the thread.
alter table conversation add column if not exists visitor_typing_at timestamptz;
alter table conversation add column if not exists agent_typing_at timestamptz;

-- Visitors can be muted or blocked (abuse, spam, a bot). Blocking stops new
-- messages at the write path rather than hiding them after the fact.
create table if not exists visitor_block (
    visitor_id uuid primary key references visitor(id) on delete cascade,
    tenant_id uuid not null references tenant(id) on delete cascade,
    reason varchar(200),
    blocked_by uuid references agent(id) on delete set null,
    created_at timestamptz not null default now()
);

-- Reply-to and reaction changes need to reach the other side, so their names
-- join the event vocabulary the webhook dispatcher already documents.
comment on column message.is_private is
    'Internal note: never returned to a visitor principal and never webhooked.';
comment on column message.search_vector is
    'Generated full-text index column; maintained by PostgreSQL.';
