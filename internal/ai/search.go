package ai

import (
	"context"
	"strings"
	"unicode"

	"github.com/google/uuid"
)

type knowledgeEntry struct {
	id       uuid.UUID
	title    string
	content  string
	examples string
	score    float64
}

// search performs tenant-scoped knowledge retrieval. It combines PostgreSQL
// full-text search with trigram similarity and CJK n-gram matching so that both
// Chinese and English questions hit. Everything runs inside the database, which
// keeps each tenant's knowledge base private and avoids an external vector
// service in the default deployment.
func (s *Service) search(ctx context.Context, tenantID uuid.UUID, question string) ([]knowledgeEntry, error) {
	rows, err := s.pool.Query(ctx, `
		select id, title, content, question_examples,
		       greatest(
		           ts_rank(to_tsvector('simple', title || ' ' || content || ' ' || question_examples),
		                   plainto_tsquery('simple', $2)),
		           similarity(title || ' ' || content, $2) * 0.6
		       ) as score
		  from knowledge_entry
		 where tenant_id = $1 and status = 'ACTIVE'
		   and (content ilike '%' || $2 || '%'
		        or title ilike '%' || $2 || '%'
		        or to_tsvector('simple', title || ' ' || content || ' ' || question_examples)
		               @@ plainto_tsquery('simple', $2)
		        or similarity(title || ' ' || content, $2) > 0.08
		        or exists (
		            select 1 from unnest($3::text[]) as term
		             where title ilike '%' || term || '%'
		                or content ilike '%' || term || '%'
		                or question_examples ilike '%' || term || '%'
		        ))
		 order by score desc, hit_count desc
		 limit 5`, tenantID, question, keywords(question))
	if err != nil {
		return nil, err
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
	if len(entries) > 0 {
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
	entries, err := s.search(ctx, tenantID, question)
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

// keywords splits a question into candidate terms. CJK text has no spaces, so
// in addition to whitespace tokenization the query feeds every 2-4 rune window
// of the question, which is enough for the ILIKE branches above.
func keywords(question string) []string {
	seen := make(map[string]struct{})
	result := make([]string, 0, 16)
	add := func(value string) {
		value = strings.TrimSpace(value)
		if len([]rune(value)) < 2 {
			return
		}
		if _, ok := seen[value]; ok {
			return
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	for _, field := range strings.FieldsFunc(question, func(r rune) bool {
		return unicode.IsSpace(r) || unicode.IsPunct(r)
	}) {
		add(field)
	}
	hasCJK := false
	for _, r := range question {
		if unicode.Is(unicode.Han, r) {
			hasCJK = true
			break
		}
	}
	if hasCJK {
		runes := []rune(question)
		for _, size := range []int{2, 3, 4} {
			for index := 0; index+size <= len(runes); index++ {
				add(string(runes[index : index+size]))
			}
		}
	}
	if len(result) > 64 {
		result = result[:64]
	}
	return result
}
