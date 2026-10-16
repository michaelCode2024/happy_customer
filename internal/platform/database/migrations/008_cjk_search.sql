-- CJK-aware full-text search.
--
-- PostgreSQL's built-in tokenizers cannot segment Chinese. Under the 'simple'
-- configuration the whole run between two punctuation marks becomes one token,
-- so "补充一下，是加急件" indexes as '补充一下' and '是加急件' and a query for
-- '加急' matches nothing. The trigram fallback does not cover the gap either:
-- pg_trgm pads a two-character query into three padded trigrams, and the
-- similarity of "加急" against a real sentence is zero, so it never reaches the
-- threshold. The visible symptom was a search box that returned no results for
-- the most ordinary Chinese keyword.
--
-- The fix is to tokenize in the database, in a function both the index and the
-- query side call, so the two can never disagree:
--
--   * each CJK ideograph becomes a term of its own, so a one-character query
--     still finds its text;
--   * every adjacent pair of ideographs becomes a term, which is the shortest
--     window that still means something and is what makes a two-character
--     Chinese query hit;
--   * runs of ASCII letters and digits stay whole and are lowercased, so
--     'A20261008' and 'get a refund' keep behaving like normal full-text search.
--
-- Being a pure function of its input, it is marked immutable and can therefore
-- back a generated column.

create or replace function tongyu_terms(value text) returns text[]
language sql immutable parallel safe as $$
  with chars as (
      select ord, ch, ascii(ch) as code
        from regexp_split_to_table(coalesce(value, ''), '') with ordinality as t(ch, ord)
  ), flagged as (
      select ord, ch,
             -- Han, kana, hangul and the compatibility ideographs all carry
             -- meaning; punctuation, spaces and symbols only break runs.
             (code between 13312 and 19903) or (code between 19968 and 40959)
             or (code between 12352 and 12543) or (code between 44032 and 55215)
             or (code between 63744 and 64255) as cjk
        from chars
  ), terms as (
      select ord, ch as term from flagged where cjk
      union all
      -- A bigram is tagged with the position of its first character, so "补充"
      -- and the character "补" claim the same slot and then order by length.
      -- Tagging it with the second character's position instead would make a
      -- term's index position depend on which side of the pair it came from.
      select current.ord, current.ch || next.ch
        from flagged current join flagged next on next.ord = current.ord + 1
       where current.cjk and next.cjk
      union all
      select 0, lower(matches[1])
        from regexp_matches(coalesce(value, ''), '[0-9A-Za-z]{2,}', 'g') as g(matches)
  ), unique_terms as (
      -- One entry per distinct term, keeping its first position. A repeated
      -- word does not need a second index position, and without this a long
      -- message full of one character would fill the cap with duplicates.
      select distinct on (term) term, ord from terms order by term, ord
  )
  select coalesce(array_agg(term order by ord, length(term), term), '{}'::text[]) from (
      -- A pathological input (a megabyte of prose) would otherwise build a
      -- generated column the size of the message. 4000 distinct terms is far
      -- more than any real message needs and keeps the index entry bounded.
      --
      -- The sort is a total order, not just by position: a character and the
      -- bigram that starts at it share a position, and ts_rank depends on where
      -- each term lands in the vector. Leaving that tie to the planner would
      -- make ranking drift between plans and between Postgres versions.
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

-- The query side must use the same tokenizer. Terms are OR-ed rather than
-- AND-ed: a two-character Chinese query is already a bigram, and requiring
-- every term to be present turns "订单发货" into a search for a sentence rather
-- than for a message about it. Ranking, not filtering, decides relevance.
create or replace function tongyu_tsquery(value text) returns tsquery
language sql immutable parallel safe as $$
  select case when cardinality(terms) = 0 then null::tsquery
              else to_tsquery('simple',
                   array_to_string(array(select quote_literal(t) from unnest(terms) as t), ' | ')) end
    from tongyu_terms(value) as terms
$$;

comment on function tongyu_tsquery(text) is
    'OR-of-terms query built from the same tokenizer as tongyu_tsvector; null when there is nothing to search for';

-- message.search_vector was created in 006 over the 'simple' configuration,
-- which is precisely the tokenizer that cannot segment Chinese. It holds no
-- hand-written data, so it is rebuilt rather than patched.
alter table message drop column if exists search_vector;
alter table message add column search_vector tsvector
    generated always as (tongyu_tsvector(content)) stored;
create index if not exists idx_message_search on message using gin (search_vector);

comment on column message.search_vector is
    'generated from content with tongyu_tsvector so Chinese keywords match; see migration 008';

-- The knowledge base gets the same treatment. Its trigger stays hand-written in
-- Go (it also maintains hit counts and re-embeds), but the vector itself is now
-- generated, so an entry edited by any path is searchable again immediately.
alter table knowledge_entry add column if not exists search_vector tsvector
    generated always as (tongyu_tsvector(title || ' ' || content || ' ' || question_examples)) stored;
create index if not exists idx_knowledge_entry_vector on knowledge_entry using gin (search_vector);

comment on column knowledge_entry.search_vector is
    'generated from title, content and question_examples; ranked retrieval uses this';

-- 003 indexed an expression over the same three columns with the old tokenizer.
-- It cannot serve a query the new tokenizer produces, and leaving it behind
-- would cost a write on every knowledge edit for no reader.
drop index if exists idx_knowledge_entry_search;
