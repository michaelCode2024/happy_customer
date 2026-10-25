-- 008 在线上以旧名 relaydesk_* 执行过；品牌改名只改了源码与 008 正文，
-- schema_migration 已记 008 为 applied，不会重跑。Go 现调用 tongyu_*，
-- 缺函数时推荐回复 / 消息搜索会 502。本迁移补齐 tongyu_*（与 008 同逻辑）。
-- 已有的 relaydesk_* 与生成列引用先保留，避免整表重写 search_vector。

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

comment on function tongyu_terms(text) is
    'searchable terms for one text: CJK single characters plus adjacent bigrams, and whole lowercased ASCII words';

create or replace function tongyu_tsvector(value text) returns tsvector
language sql immutable parallel safe as $$
  select case when cardinality(terms) = 0 then ''::tsvector
              else to_tsvector('simple', array_to_string(terms, ' ')) end
    from tongyu_terms(value) as terms
$$;

comment on function tongyu_tsvector(text) is
    'positional search vector built from tongyu_terms; used by generated columns';

create or replace function tongyu_tsquery(value text) returns tsquery
language sql immutable parallel safe as $$
  select case when cardinality(terms) = 0 then null::tsquery
              else to_tsquery('simple',
                   array_to_string(array(select quote_literal(t) from unnest(terms) as t), ' | ')) end
    from tongyu_terms(value) as terms
$$;

comment on function tongyu_tsquery(text) is
    'OR-of-terms query built from the same tokenizer as tongyu_tsvector; null when there is nothing to search for';
