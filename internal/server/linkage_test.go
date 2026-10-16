package server

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/tongyu/tongyu/internal/auth"
	"github.com/tongyu/tongyu/internal/realtime"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestCrossModulePoliciesAndAtomicSettings(t *testing.T) {
	dsn := os.Getenv("TONGYU_TEST_DATABASE")
	if dsn == "" {
		t.Skip("database not configured")
	}
	ctx := context.Background()
	db, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	tenant, inbox, visitor, conv, owner, agent := uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New()
	run := func(q string, args ...any) {
		t.Helper()
		if _, e := db.Exec(ctx, q, args...); e != nil {
			t.Fatal(e)
		}
	}
	defer func() {
		if _, err := db.Exec(ctx, `delete from tenant where id=$1`, tenant); err != nil {
			_, _ = db.Exec(ctx, `update tenant set status='SUSPENDED' where id=$1`, tenant)
		}
	}()
	run(`insert into tenant(id,name,slug,status) values($1,'original',$2,'ACTIVE')`, tenant, tenant.String())
	run(`insert into tenant_subscription(tenant_id,plan,status,seat_limit,monthly_message_limit) values($1,'ENTERPRISE','ACTIVE',10,1)`, tenant)
	run(`insert into agent(id,tenant_id,email,display_name,password_hash,role,status) values($1,$3,'owner','original owner','test','SUPERVISOR','ACTIVE'),($2,$3,'agent','original agent','test','AGENT','ACTIVE')`, owner, agent, tenant)
	run(`insert into inbox(id,tenant_id,name,public_key,status) values($1,$2,'original inbox',$3,'ACTIVE')`, inbox, tenant, inbox.String())
	run(`insert into agent_inbox(agent_id,inbox_id) values($1,$2)`, owner, inbox)
	run(`insert into visitor(id,tenant_id,inbox_id) values($1,$2,$3)`, visitor, tenant, inbox)
	run(`insert into conversation(id,tenant_id,inbox_id,visitor_id,status) values($1,$2,$3,$4,'OPEN')`, conv, tenant, inbox, visitor)
	a := &API{db: db, logger: slog.Default(), bus: realtime.NewBus(db, realtime.NewHub(slog.Default()), slog.Default())}
	first, err := a.appendMessage(ctx, tenant, conv, messageInput{SenderType: "AGENT", Content: "one", ClientMessageID: "one"})
	if err != nil {
		t.Fatal(err)
	}
	duplicate, err := a.appendMessage(ctx, tenant, conv, messageInput{SenderType: "AGENT", Content: "one", ClientMessageID: "one"})
	if err != nil || duplicate.ID != first.ID {
		t.Fatalf("quota broke idempotent retry: %v", err)
	}
	_, err = a.appendMessage(ctx, tenant, conv, messageInput{SenderType: "AGENT", Content: "two"})
	var policy serviceError
	if !errors.As(err, &policy) || policy.code != "MESSAGE_LIMIT_REACHED" {
		t.Fatalf("quota missing: %v", err)
	}
	run(`update tenant_subscription set monthly_message_limit=100,status='CANCELED' where tenant_id=$1`, tenant)
	if a.tenantHasFeature(ctx, tenant, "integrations") {
		t.Fatal("canceled plan retained integrations")
	}
	_, err = a.appendMessage(ctx, tenant, conv, messageInput{SenderType: "AGENT", Content: "canceled"})
	if !errors.As(err, &policy) || policy.code != "SUBSCRIPTION_INACTIVE" {
		t.Fatalf("canceled plan still sends: %v", err)
	}
	run(`update tenant_subscription set plan='TRIAL',status='ACTIVE',trial_ends_at=now()-interval '1 day' where tenant_id=$1`, tenant)
	_, err = a.appendMessage(ctx, tenant, conv, messageInput{SenderType: "AGENT", Content: "expired"})
	if !errors.As(err, &policy) {
		t.Fatal("expired trial still sends")
	}
	run(`update tenant_subscription set plan='ENTERPRISE',trial_ends_at=null where tenant_id=$1`, tenant)
	r := httptest.NewRequest("PATCH", "/", strings.NewReader(`{"name":"partial change","plan":"INVALID"}`))
	r.SetPathValue("id", tenant.String())
	w := httptest.NewRecorder()
	a.platformUpdateTenant(w, r, auth.Principal{Kind: auth.KindPlatform})
	var name string
	_ = db.QueryRow(ctx, `select name from tenant where id=$1`, tenant).Scan(&name)
	if w.Code != 400 || name != "original" {
		t.Fatalf("platform update partially persisted: %d %s", w.Code, name)
	}
	body, _ := json.Marshal(map[string]any{"name": "partial inbox", "routing": map[string]any{"strategy": "FIXED", "fixedAgentId": uuid.New().String()}})
	r = httptest.NewRequest("PATCH", "/", strings.NewReader(string(body)))
	r.SetPathValue("id", inbox.String())
	w = httptest.NewRecorder()
	p := auth.Principal{Kind: auth.KindAgent, TenantID: tenant, AgentID: owner, Role: auth.RoleSupervisor}
	a.adminUpdateInbox(w, r, p)
	_ = db.QueryRow(ctx, `select name from inbox where id=$1`, inbox).Scan(&name)
	if w.Code != 400 || name != "original inbox" {
		t.Fatalf("inbox update partially persisted: %d %s", w.Code, name)
	}
	body, _ = json.Marshal(map[string]any{"displayName": "partial member", "inboxIds": []string{uuid.New().String()}})
	r = httptest.NewRequest("PATCH", "/", strings.NewReader(string(body)))
	r.SetPathValue("id", agent.String())
	w = httptest.NewRecorder()
	a.adminUpdateAgent(w, r, p)
	_ = db.QueryRow(ctx, `select display_name from agent where id=$1`, agent).Scan(&name)
	if w.Code != 400 || name != "original agent" {
		t.Fatalf("member update partially persisted: %d %s", w.Code, name)
	}
	r = httptest.NewRequest("PATCH", "/", strings.NewReader(`{"role":"AGENT"}`))
	r.SetPathValue("id", owner.String())
	w = httptest.NewRecorder()
	a.adminUpdateAgent(w, r, p)
	if w.Code != 409 {
		t.Fatalf("last owner could be demoted: %d", w.Code)
	}
}
