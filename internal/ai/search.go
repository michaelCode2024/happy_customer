package ai

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/google/uuid"
)

type knowledgeEntry struct {
	id       uuid.UUID
	title    string
	content  string
	examples string
	score    float64
}

// search performs tenant-scoped knowledge retrieval.
//
// Ranking is by "coverage": the share of the question's specificity mass that an
// article carries. Every term in the question is weighted by how rare it is
// across the tenant's active articles — a term in every article is worth almost
// nothing, a term in one article is worth a lot — and an article's score is the
// fraction of that mass it matches. The result is a number between 0 and 1 that
// means "how much of what makes this question distinctive does this article
// contain", which is the quantity the confidence threshold actually wants to
// compare against.
//
// The previous formula took the greatest of ts_rank, trigram similarity and a
// verbatim bonus. Measured against the real knowledge base it returned 0.019 to
// 0.061 for every question, correct or not, so with the shipped 0.35 threshold
// the bot declined to answer even when the article it needed was sitting right
// there. The cause is that all three components measure surface similarity, and
// a question shares its function words ("怎么", "吗") with every article written
// in the same voice. Coverage ignores the surface and asks what a match is worth.
//
// Coverage is affordable here in a way it would not be on the message table: a
// tenant's knowledge base is tens of rows, so the document-frequency pass is a
// scan of a small table rather than the transcript.
//
// countHits separates real traffic from an operator poking at the test bench.
// The hit counter feeds the tenant's "knowledge base coverage" report, and a
// preview that incremented it would make every article look popular the moment
// someone opened the console.
func (s *Service) search(ctx context.Context, tenantID uuid.UUID, question string, countHits bool) ([]knowledgeEntry, error) {
	question = strings.TrimSpace(question)
	if len(terms(question)) == 0 {
		return nil, nil
	}
	rows, err := s.pool.Query(ctx, `
		with corpus as (
		    select id, title, content, question_examples, search_vector
		      from knowledge_entry
		     where tenant_id = $1 and status = 'ACTIVE'
		), stats as (
		    select count(*)::numeric as total from corpus
		), q as (
		    select unnest(relaydesk_terms($2)) as term
		), freq as (
		    -- One row per question term. The left join keeps terms that appear
		    -- in no article: they are the most specific terms of all, and an
		    -- article that matches none of them should carry none of their
		    -- mass. Counting the join rather than the articles is what makes a
		    -- term absent from the corpus score highest instead of zero.
		    select q.term,
		           count(c.id)::numeric as docs,
		           -- 单条知识也必须可检索；全部条目都出现的词不能变成零权重。
		           greatest(ln((s.total + 1) / (count(c.id) + 1)), 0.05) as idf
		      from q
		      cross join stats s
		      left join corpus c
		        on c.search_vector @@ to_tsquery('simple', quote_literal(q.term))
		     group by q.term, s.total
		), mass as (
		    select sum(idf) as total_idf from freq
		), matched as (
		    select c.id, c.title, c.content, c.question_examples,
		           coalesce(sum(f.idf), 0) as matched_idf
		      from corpus c
		      left join freq f
		        on c.search_vector @@ to_tsquery('simple', quote_literal(f.term))
		     group by c.id, c.title, c.content, c.question_examples
		)
		select m.id, m.title, m.content, m.question_examples,
		       (m.matched_idf / greatest(mass.total_idf, 1e-9))::float8 as score
		  from matched m
		  cross join mass
		 where m.matched_idf > 0
		 order by score desc, m.title
		 limit 5`, tenantID, question)
	if err != nil {
		return nil, fmt.Errorf("knowledge retrieval: %w", err)
	}
	defer rows.Close()
	entries := make([]knowledgeEntry, 0, 5)
	for rows.Next() {
		var entry knowledgeEntry
		if err := rows.Scan(&entry.id, &entry.title, &entry.content, &entry.examples, &entry.score); err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if countHits && len(entries) > 0 {
		ids := make([]uuid.UUID, 0, len(entries))
		for _, entry := range entries {
			ids = append(ids, entry.id)
		}
		// Hit counters drive the "unanswered questions" report: entries that are
		// retrieved but never chosen still show up as demand.
		_, _ = s.pool.Exec(ctx, `update knowledge_entry set hit_count = hit_count + 1 where id = any($1)`, ids)
	}
	return entries, nil
}

// Hit is one knowledge snippet returned by Retrieve. The console shows these
// next to the answer so an operator can see exactly what the model was given,
// which is what makes "why did the bot say that?" answerable.
type Hit struct {
	ID       uuid.UUID `json:"id"`
	Title    string    `json:"title"`
	Content  string    `json:"content"`
	Examples string    `json:"examples,omitempty"`
	Score    float64   `json:"score"`
}

// Retrieve exposes the retrieval half of the AI pipeline without calling a
// model. Operators use it to test whether a question can be answered at all
// before blaming the model, and it costs nothing to run.
func (s *Service) Retrieve(ctx context.Context, tenantID uuid.UUID, question string) ([]Hit, error) {
	entries, err := s.SearchHybrid(ctx, tenantID, question, false)
	if err != nil {
		return nil, err
	}
	hits := make([]Hit, 0, len(entries))
	for _, entry := range entries {
		hits = append(hits, Hit{
			ID: entry.id, Title: entry.title, Content: entry.content,
			Examples: entry.examples, Score: entry.score,
		})
	}
	return hits, nil
}

// terms mirrors relaydesk_terms in the database: one term per CJK character,
// one term per adjacent CJK pair, and whole lowercased ASCII words. The mirror
// exists so a question with nothing searchable in it can be rejected before it
// reaches the database, where an empty tsquery would otherwise match nothing
// after a full scan.
//
// It reproduces the SQL function's total order — position, then length, then
// text — rather than merely the same set, because an array comparison is only
// meaningful when both sides agree on the order. TestTermsMatchTheDatabaseTokenizer
// pins the outputs against the real function, since a mirror that drifts is
// worse than no mirror at all.
func terms(question string) []string {
	type term struct {
		position int
		value    string
	}
	runes := []rune(question)
	collected := make([]term, 0, len(runes)*2)
	for index := 0; index < len(runes); index++ {
		if !isCJK(runes[index]) {
			continue
		}
		collected = append(collected, term{position: index + 1, value: string(runes[index])})
		if index+1 < len(runes) && isCJK(runes[index+1]) {
			collected = append(collected, term{position: index + 1, value: string(runes[index : index+2])})
		}
	}
	// ASCII words are grouped under position zero, exactly as the SQL
	// union does, so they sort ahead of every Chinese character.
	var word strings.Builder
	flush := func() {
		if word.Len() >= 2 {
			collected = append(collected, term{position: 0, value: strings.ToLower(word.String())})
		}
		word.Reset()
	}
	for _, r := range runes {
		if isASCIIAlnum(r) {
			word.WriteRune(r)
			continue
		}
		flush()
	}
	flush()

	sort.SliceStable(collected, func(first, second int) bool {
		if collected[first].position != collected[second].position {
			return collected[first].position < collected[second].position
		}
		if len(collected[first].value) != len(collected[second].value) {
			return len(collected[first].value) < len(collected[second].value)
		}
		return collected[first].value < collected[second].value
	})
	// Deduplicate before truncating, the same order of operations as the SQL
	// function: deduplicating afterwards would let duplicates consume slots in
	// the cap and yield fewer distinct terms than the database indexed.
	result := make([]string, 0, len(collected))
	seen := make(map[string]struct{}, len(collected))
	for _, item := range collected {
		if _, ok := seen[item.value]; ok {
			continue
		}
		seen[item.value] = struct{}{}
		result = append(result, item.value)
	}
	if len(result) > 4000 {
		result = result[:4000]
	}
	if len(result) == 0 {
		return nil
	}
	return result
}

// isCJK reports whether a rune is a script the 'simple' tokenizer cannot
// segment: Han, kana, hangul and the compatibility ideographs. It matches the
// ranges in relaydesk_terms.
func isCJK(r rune) bool {
	switch {
	case r >= 0x3400 && r <= 0x4DBF: // CJK extension A
		return true
	case r >= 0x4E00 && r <= 0x9FFF: // CJK unified ideographs
		return true
	case r >= 0x3040 && r <= 0x30FF: // hiragana and katakana
		return true
	case r >= 0xAC00 && r <= 0xD7AF: // hangul syllables
		return true
	case r >= 0xF900 && r <= 0xFAFF: // compatibility ideographs
		return true
	}
	return false
}

// isASCIIAlnum matches the SQL side's [0-9A-Za-z] and nothing more: an accented
// letter is not part of a word here, because the database would not treat it as
// one either.
func isASCIIAlnum(r rune) bool {
	return (r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
}
