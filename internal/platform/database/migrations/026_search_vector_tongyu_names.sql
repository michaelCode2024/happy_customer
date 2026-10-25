-- 生成列与旧函数仍叫 relaydesk_*；在 025 已提供 tongyu_* 后，把列改挂新名并卸旧函数。
-- 消息/知识表体量小，drop+add 可接受；大库需改成并发重建。

alter table message drop column if exists search_vector;
alter table message add column search_vector tsvector
    generated always as (tongyu_tsvector(content)) stored;
create index if not exists idx_message_search on message using gin (search_vector);
comment on column message.search_vector is
    'generated from content with tongyu_tsvector so Chinese keywords match';

alter table knowledge_entry drop column if exists search_vector;
alter table knowledge_entry add column search_vector tsvector
    generated always as (tongyu_tsvector(title || ' ' || content || ' ' || question_examples)) stored;
create index if not exists idx_knowledge_entry_vector on knowledge_entry using gin (search_vector);
comment on column knowledge_entry.search_vector is
    'generated from title, content and question_examples; ranked retrieval uses this';

drop function if exists relaydesk_tsquery(text);
drop function if exists relaydesk_tsvector(text);
drop function if exists relaydesk_terms(text);
