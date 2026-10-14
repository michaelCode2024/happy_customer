package database

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TestSubscriptionTrialWindow pins the SQL shape behind tenant provisioning.
//
// The first version of platformCreateTenant bound the plan to a single
// placeholder used in two type contexts — as the varchar(30) column value and
// as a text comparison inside the trial predicate. Postgres cannot deduce one
// type for a placeholder in two contexts and rejects the whole statement with
// SQLSTATE 42P08, so every "create tenant" returned 500 while the equivalent
// hand-typed psql statement worked fine. The plan is therefore bound twice.
func TestSubscriptionTrialWindow(t *testing.T) {
	dsn := os.Getenv("RELAYDESK_TEST_DATABASE")
	if dsn == "" {
		t.Skip("RELAYDESK_TEST_DATABASE is not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err = Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	tenantID := uuid.New()
	if _, err := tx.Exec(ctx, `insert into tenant(id, name, slug, status) values($1,$2,$3,'ACTIVE')`,
		tenantID, "subscription-test", "sub-test-"+tenantID.String()[:8]); err != nil {
		t.Fatalf("tenant: %v", err)
	}

	const createSubscription = `insert into tenant_subscription(tenant_id, plan, status, seat_limit, monthly_message_limit, trial_ends_at)
		values($1,$2,'ACTIVE',$3,$4, case when $5::text = 'TRIAL' then now() + ($6 || ' days')::interval else null end)`

	if _, err := tx.Exec(ctx, createSubscription, tenantID, "TRIAL", 2, 1000, "TRIAL", "14"); err != nil {
		t.Fatalf("trial subscription: %v", err)
	}
	var plan string
	var trialEnds *time.Time
	if err := tx.QueryRow(ctx, `select plan, trial_ends_at from tenant_subscription where tenant_id=$1`, tenantID).
		Scan(&plan, &trialEnds); err != nil {
		t.Fatalf("read back: %v", err)
	}
	if plan != "TRIAL" || trialEnds == nil {
		t.Fatalf("unexpected trial row: plan=%q trialEnds=%v", plan, trialEnds)
	}

	// A paid plan must leave the trial column null rather than stamping a date:
	// a paying customer showing up as "试用中" is a billing dispute.
	if _, err := tx.Exec(ctx, createSubscription+
		` on conflict (tenant_id) do update set plan=$2, trial_ends_at=excluded.trial_ends_at`,
		tenantID, "GROWTH", 10, 50_000, "GROWTH", "14"); err != nil {
		t.Fatalf("paid subscription: %v", err)
	}
	if err := tx.QueryRow(ctx, `select plan, trial_ends_at from tenant_subscription where tenant_id=$1`, tenantID).
		Scan(&plan, &trialEnds); err != nil {
		t.Fatal(err)
	}
	if plan != "GROWTH" || trialEnds != nil {
		t.Fatalf("unexpected paid row: plan=%q trialEnds=%v", plan, trialEnds)
	}
}
