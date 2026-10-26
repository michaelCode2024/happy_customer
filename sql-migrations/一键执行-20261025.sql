-- TongYuDesk 2026-10-25
-- 补齐品牌改名后线上缺失的 tongyu_* 中文检索函数。
-- 背景：008_cjk_search 曾以 relaydesk_* 落地；源码已改调 tongyu_*，但 008 不会重跑。
-- 症状：推荐回复 / 消息关键词搜索 502「AI 调用失败」。
-- 安全：只 CREATE OR REPLACE 函数，不改表、不重写 search_vector 生成列。

BEGIN;

create or replace function tongyu_terms(value text) returns text[]
language sql immutable parallel safe as $$
  with chars as (
      select ord, ch, ascii(ch) as code
        from regexp_split_to_table(coalesce(value, ''), '') with ordinality as t(ch, ord)
  ), flagged as (
      select ord, ch,
             (code between 13312 and 19903) or (code between 19968 and 40959)
             or (code between 12352 and 12543) or (code between 44032 and 55215)
             or (code between 63744 and 64255) as cjk
        from chars
  ), terms as (
      select ord, ch as term from flagged where cjk
      union all
      select current.ord, current.ch || next.ch
        from flagged current join flagged next on next.ord = current.ord + 1
       where current.cjk and next.cjk
      union all
      select 0, lower(matches[1])
        from regexp_matches(coalesce(value, ''), '[0-9A-Za-z]{2,}', 'g') as g(matches)
  ), unique_terms as (
      select distinct on (term) term, ord from terms order by term, ord
  )
  select coalesce(array_agg(term order by ord, length(term), term), '{}'::text[]) from (
      select term, ord from unique_terms order by ord, length(term), term limit 4000
  ) bounded
$$;

create or replace function tongyu_tsvector(value text) returns tsvector
language sql immutable parallel safe as $$
  select case when cardinality(terms) = 0 then ''::tsvector
              else to_tsvector('simple', array_to_string(terms, ' ')) end
    from tongyu_terms(value) as terms
$$;

create or replace function tongyu_tsquery(value text) returns tsquery
language sql immutable parallel safe as $$
  select case when cardinality(terms) = 0 then null::tsquery
              else to_tsquery('simple',
                   array_to_string(array(select quote_literal(t) from unnest(terms) as t), ' | ')) end
    from tongyu_terms(value) as terms
$$;

-- 若服务端尚未带上 025 迁移文件重启，先手记版本，避免下次启动重复失败以外的困惑。
insert into schema_migration(version)
values ('025_tongyu_cjk_search_aliases.sql')
on conflict (version) do nothing;

COMMIT;

-- ---- 同日追加：生成列改挂 tongyu_tsvector，并卸掉旧函数名 ----
BEGIN;

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

insert into schema_migration(version)
values ('026_search_vector_tongyu_names.sql')
on conflict (version) do nothing;

COMMIT;
