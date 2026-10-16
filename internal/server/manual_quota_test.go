package server

import (
	"context"
	"encoding/json"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/tongyu/tongyu/internal/auth"
	"github.com/tongyu/tongyu/internal/platform/database"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestManualQuotaWorkflow(t *testing.T) {
	dsn := os.Getenv("TONGYU_TEST_DATABASE")
	if dsn == "" {
		t.Skip("isolated database not configured")
	}
	ctx := context.Background()
	db, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err = database.Migrate(ctx, db); err != nil {
		t.Fatal(err)
	}
	tenant, super, ordinary := uuid.New(), uuid.New(), uuid.New()
	run := func(sql string, args ...any) {
		t.Helper()
		if _, e := db.Exec(ctx, sql, args...); e != nil {
			t.Fatal(e)
		}
	}
	run(`insert into tenant(id,name,slug,status) values($1,'额度验收',$2,'ACTIVE')`, tenant, "quota-"+tenant.String())
	run(`insert into tenant_subscription(tenant_id,plan,status,seat_limit,monthly_message_limit,monthly_ai_limit) values($1,'GROWTH','ACTIVE',10,5,1)`, tenant)
	for _, v := range []struct {
		id   uuid.UUID
		role string
	}{{super, "SUPER_ADMIN"}, {ordinary, "ADMIN"}} {
		run(`insert into platform_admin(id,email,display_name,password_hash,role) values($1,$2,'额度测试','unused',$3)`, v.id, v.id.String(), v.role)
	}
	a := &API{db: db, logger: slog.Default(), tokens: auth.NewTokenService("quota-test-secret-at-least-thirty-two-chars", time.Hour, time.Hour)}
	token := func(id uuid.UUID) string {
		sid := uuid.New()
		run(`insert into platform_session(id,admin_id,expires_at) values($1,$2,now()+interval '1 hour')`, sid, id)
		s, e := a.tokens.IssuePlatformSession(id, sid, "test")
		if e != nil {
			t.Fatal(e)
		}
		return s
	}
	superToken, adminToken := token(super), token(ordinary)
	request := func(body quotaRequest, token string) *httptest.ResponseRecorder {
		b, _ := json.Marshal(body)
		r := httptest.NewRequest("POST", "/api/v1/platform/tenants/"+tenant.String()+"/quota", strings.NewReader(string(b)))
		r.SetPathValue("id", tenant.String())
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		a.requireSuperAdmin(a.platformAssignQuota)(w, r)
		return w
	}
	q, e := readQuota(ctx, db, tenant)
	if e != nil {
		t.Fatal(e)
	}
	start := time.Now().Add(-time.Hour)
	end := time.Now().Add(time.Hour)
	in := quotaRequest{RequestID: uuid.New(), Mode: "SET", Reason: "企业扩容验收", Version: q.Version, Plan: "GROWTH", Status: "ACTIVE", Seats: 12, Messages: 20, AI: 2, Starts: &start, Ends: &end}
	if w := request(in, adminToken); w.Code != 403 {
		t.Fatalf("ordinary admin: %d %s", w.Code, w.Body.String())
	}
	agentToken, _ := a.tokens.IssuePlatformSession(uuid.New(), uuid.New(), "forged")
	if w := request(in, agentToken); w.Code != 401 {
		t.Fatal("invalid session accepted")
	}
	if w := request(in, superToken); w.Code != 200 {
		t.Fatalf("set: %d %s", w.Code, w.Body.String())
	}
	if w := request(in, superToken); w.Code != 200 {
		t.Fatalf("retry: %d %s", w.Code, w.Body.String())
	}
	altered := in
	altered.Messages = 21
	if w := request(altered, superToken); w.Code != 409 {
		t.Fatal("same request ID changed payload accepted")
	}
	stale := in
	stale.RequestID = uuid.New()
	if w := request(stale, superToken); w.Code != 409 {
		t.Fatal("stale version accepted")
	}
	q, _ = readQuota(ctx, db, tenant)
	add := quotaRequest{RequestID: uuid.New(), Mode: "ADD", Reason: "本月临时追加", Version: q.Version, ExtraMessages: 7, ExtraAI: 1}
	if w := request(add, superToken); w.Code != 200 {
		t.Fatalf("add: %d %s", w.Code, w.Body.String())
	}
	if w := request(add, superToken); w.Code != 200 {
		t.Fatal("add retry failed")
	}
	q, _ = readQuota(ctx, db, tenant)
	if q.MessageBonus != 7 || q.AIBonus != 1 || q.MessageLimit != 20 {
		t.Fatalf("bonus changed base or duplicated: %+v", q)
	}
	var auditCount int
	runCountErr := db.QueryRow(ctx, `select count(*) from quota_adjustment where tenant_id=$1 and actor_id=$2`, tenant, super).Scan(&auditCount)
	if runCountErr != nil || auditCount != 2 {
		t.Fatal("audit/idempotency mismatch")
	}
	// With three effective AI credits, parallel reservations admit exactly three.
	var admitted int
	var mu sync.Mutex
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			finish, e := a.reserveAIQuota(ctx, tenant)
			if e == nil {
				finish(true)
				mu.Lock()
				admitted++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if admitted != 3 {
		t.Fatalf("parallel AI quota admitted %d", admitted)
	}
	q, _ = readQuota(ctx, db, tenant)
	if q.UsedAI != 3 {
		t.Fatal("AI usage missing")
	}
	// Past-month additions do not count and changing limits never resets usage.
	run(`update tenant_quota_bonus set month=(date_trunc('month',now())-interval '1 month')::date where tenant_id=$1`, tenant)
	q, _ = readQuota(ctx, db, tenant)
	if q.MessageBonus != 0 || q.AIBonus != 0 || q.UsedAI != 3 {
		t.Fatal("monthly rollover/reset failed")
	}
	run(`update tenant_subscription set service_ends_at=now()-interval '1 minute' where tenant_id=$1`, tenant)
	tx, e := db.Begin(ctx)
	if e != nil {
		t.Fatal(e)
	}
	if a.checkMessageQuota(ctx, tx, tenant) == nil {
		t.Fatal("expired service can send")
	}
	tx.Rollback(ctx)
	// Role is read from DB on every write, including existing bearer sessions.
	run(`update platform_admin set role='ADMIN' where id=$1`, super)
	if w := request(add, superToken); w.Code != 403 {
		t.Fatal("demoted super admin retained quota access")
	}
	// Clean only fixtures belonging to this test.
	run(`delete from audit_log where tenant_id=$1`, tenant)
	run(`delete from quota_adjustment where tenant_id=$1`, tenant)
	run(`delete from tenant_quota_bonus where tenant_id=$1`, tenant)
	run(`delete from tenant_ai_quota_usage where tenant_id=$1`, tenant)
	run(`delete from tenant_subscription where tenant_id=$1`, tenant)
	run(`delete from tenant where id=$1`, tenant)
	run(`delete from platform_admin where id=any($1)`, []uuid.UUID{super, ordinary})
}
