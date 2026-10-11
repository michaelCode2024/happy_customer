package database

import (
	"context"
	"embed"
	"fmt"
	"sort"

	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrations embed.FS

func Open(ctx context.Context, databaseURL string, maxConns int32) (*pgxpool.Pool, error) {
	config, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse database URL: %w", err)
	}
	if maxConns < 4 {
		maxConns = 4
	}
	config.MaxConns = maxConns
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping database: %w", err)
	}
	return pool, nil
}

func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "select pg_advisory_lock(734892341)"); err != nil {
		return err
	}
	defer conn.Exec(context.Background(), "select pg_advisory_unlock(734892341)") //nolint:errcheck

	if _, err := conn.Exec(ctx, `create table if not exists schema_migration (
		version varchar(200) primary key, applied_at timestamptz not null default now())`); err != nil {
		return err
	}
	entries, err := migrations.ReadDir("migrations")
	if err != nil {
		return err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	for _, entry := range entries {
		var applied bool
		err := conn.QueryRow(ctx, "select exists(select 1 from schema_migration where version=$1)", entry.Name()).Scan(&applied)
		if err != nil || applied {
			if err != nil {
				return err
			}
			continue
		}
		sql, err := migrations.ReadFile("migrations/" + entry.Name())
		if err != nil {
			return err
		}
		tx, err := conn.Begin(ctx)
		if err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, string(sql)); err == nil {
			_, err = tx.Exec(ctx, "insert into schema_migration(version) values($1)", entry.Name())
		}
		if err != nil {
			tx.Rollback(ctx) //nolint:errcheck
			return fmt.Errorf("apply %s: %w", entry.Name(), err)
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
	}
	return nil
}
