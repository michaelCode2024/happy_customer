package server

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
)

// BackfillEmbeddings generates embeddings for all knowledge entries that don't
// have one yet. Called once after migration 014_vector_search.sql is applied.
func (a *API) BackfillEmbeddings(ctx context.Context, logger *slog.Logger) error {
	if !a.ai.HasEmbeddings() {
		logger.Info("embedding provider not configured, skipping backfill")
		return nil
	}

	rows, err := a.db.Query(ctx, `
		select id, tenant_id, title, content
		  from knowledge_entry
		 where embedding is null
		   and status = 'ACTIVE'
		 order by created_at
	`)
	if err != nil {
		return fmt.Errorf("backfill: query knowledge entries: %w", err)
	}
	defer rows.Close()

	type entry struct {
		id, tenantID uuid.UUID
		title, content string
	}
	var entries []entry
	for rows.Next() {
		var e entry
		if err := rows.Scan(&e.id, &e.tenantID, &e.title, &e.content); err != nil {
			return fmt.Errorf("backfill: scan row: %w", err)
		}
		entries = append(entries, e)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("backfill: iterate rows: %w", err)
	}

	if len(entries) == 0 {
		logger.Info("no knowledge entries need embedding backfill")
		return nil
	}

	logger.Info("backfilling embeddings", "count", len(entries))
	success, failed := 0, 0
	for _, e := range entries {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		reqCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		vec, err := a.ai.EmbedEntry(reqCtx, e.id, e.title, e.content)
		cancel()
		if err != nil {
			logger.Warn("backfill embedding failed", "id", e.id, "error", err)
			failed++
			continue
		}
		if vec == nil {
			failed++
			continue
		}
		success++
		if success%50 == 0 || success == len(entries) {
			logger.Info("backfill progress", "done", success, "total", len(entries))
		}
	}

	logger.Info("backfill complete", "success", success, "failed", failed)
	return nil
}
