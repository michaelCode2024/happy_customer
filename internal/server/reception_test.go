package server

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/tongyu/tongyu/internal/auth"
	"github.com/tongyu/tongyu/internal/platform/database"
	"github.com/tongyu/tongyu/internal/realtime"
	"github.com/tongyu/tongyu/internal/webhook"
)

func TestReceptionAcceptanceAndTimeout(t *testing.T) {
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
	if err = database.Migrate(ctx, db); err != nil {
		t.Fatal(err)
	}
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(ctx, q, args...); err != nil {
			t.Fatal(err)
		}
	}
	tenant, inbox, visitor, conversation, first, second := uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New()
	exec(`insert into tenant(id,name,slug,status) values($1,'reception',$2,'ACTIVE')`, tenant, tenant.String())
	exec(`insert into inbox(id,tenant_id,name,public_key,status,auto_assign) values($1,$2,'reception',$3,'ACTIVE',true)`, inbox, tenant, inbox.String())
	exec(`insert into visitor(id,tenant_id,inbox_id) values($1,$2,$3)`, visitor, tenant, inbox)
	exec(`insert into conversation(id,tenant_id,inbox_id,visitor_id,status) values($1,$2,$3,$4,'OPEN')`, conversation, tenant, inbox, visitor)
	for _, agent := range []uuid.UUID{first, second} {
		exec(`insert into agent(id,tenant_id,email,display_name,role,status,password_hash) values($1,$2,$3,$3,'AGENT','ACTIVE','x')`, agent, tenant, agent.String())
		exec(`insert into agent_inbox values($1,$2)`, agent, inbox)
		exec(`insert into agent_presence(agent_id,status,last_seen_at) values($1,'ONLINE',now())`, agent)
	}
	defer func() {
		for _, q := range []string{`delete from conversation where tenant_id=$1`, `delete from visitor where tenant_id=$1`, `delete from agent where tenant_id=$1`, `delete from inbox where tenant_id=$1`, `delete from tenant where id=$1`} {
			db.Exec(ctx, q, tenant)
		}
	}()
	a := &API{db: db, logger: slog.Default(), bus: realtime.NewBus(db, realtime.NewHub(slog.Default()), slog.Default()), webhooks: webhook.NewDispatcher(db, 3, slog.Default())}
	checkQueue := func(agent uuid.UUID, want int) {
		t.Helper()
		w := httptest.NewRecorder()
		a.consoleConversations(w, httptest.NewRequest("GET", "/?filter=reception", nil), auth.Principal{TenantID: tenant, AgentID: agent})
		var body struct {
			Items   []conversationView `json:"items"`
			Waiting int                `json:"receptionWaiting"`
		}
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &body) != nil || len(body.Items) != want || body.Waiting != want {
			t.Fatalf("reception queue: status=%d body=%s want=%d", w.Code, w.Body, want)
		}
	}
	checkQueue(first, 1)
	checkQueue(second, 1)
	// 实际管理接口持久化超时配置，并拒绝越界值。
	for _, v := range []struct {
		body string
		code int
	}{{`{"strategy":"LOAD_BALANCED","acceptanceTimeoutSeconds":27}`, 200}, {`{"strategy":"LOAD_BALANCED","acceptanceTimeoutSeconds":9}`, 400}, {`{"strategy":"LOAD_BALANCED"}`, 200}} {
		r := httptest.NewRequest("PUT", "/", strings.NewReader(v.body))
		r.SetPathValue("id", inbox.String())
		w := httptest.NewRecorder()
		a.adminInboxRouting(w, r, auth.Principal{TenantID: tenant, AgentID: first, Role: "SUPERVISOR"})
		if w.Code != v.code {
			t.Fatalf("routing status %d: %s", w.Code, w.Body)
		}
	}
	var configured int
	db.QueryRow(ctx, `select acceptance_timeout_seconds from routing_rule where inbox_id=$1`, inbox).Scan(&configured)
	if configured != 27 {
		t.Fatal("omitted timeout must preserve existing configuration")
	}
	owner, _, err := a.completeHandoff(ctx, tenant, conversation)
	if err != nil || owner == nil {
		t.Fatalf("handoff: %v %v", owner, err)
	}
	timedOut := *owner
	replacement := second
	if timedOut == second {
		replacement = first
	}
	checkQueue(timedOut, 1)
	checkQueue(replacement, 0)
	var accepted, expires *time.Time
	var paused bool
	if err = db.QueryRow(ctx, `select accepted_at,assignment_expires_at,bot_paused from conversation where id=$1`, conversation).Scan(&accepted, &expires, &paused); err != nil {
		t.Fatal(err)
	}
	if accepted != nil || expires == nil || !paused {
		t.Fatal("assignment must await acceptance with bot paused")
	}
	var joined int
	db.QueryRow(ctx, `select count(*) from message where conversation_id=$1 and content like '%已接入%'`, conversation).Scan(&joined)
	if joined != 0 {
		t.Fatal("assignment falsely announces reception")
	}
	if _, err = a.appendMessage(ctx, tenant, conversation, messageInput{SenderType: "AGENT", SenderID: owner, MessageType: "TEXT", Content: "premature"}); err == nil {
		t.Fatal("pending agent replied without accepting")
	}
	if err = a.acceptReception(ctx, tenant, conversation, replacement, "wrong"); err == nil {
		t.Fatal("other agent accepted assigned conversation")
	}
	exec(`update conversation set assignment_expires_at=now()-interval '1 second' where id=$1`, conversation)
	if err = a.acceptReception(ctx, tenant, conversation, timedOut, "late"); err == nil {
		t.Fatal("expired assignment accepted")
	}
	// 验证后台定时处理，而不仅是直接调用分配函数。
	workerCtx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() { a.receptionLoop(workerCtx); close(done) }()
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		var id *uuid.UUID
		db.QueryRow(ctx, `select assignee_id from conversation where id=$1`, conversation).Scan(&id)
		if id != nil && *id == replacement {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	cancel()
	<-done
	a.flushReceptionNotices(ctx)
	var newOwner uuid.UUID
	db.QueryRow(ctx, `select assignee_id from conversation where id=$1`, conversation).Scan(&newOwner)
	if newOwner != replacement {
		t.Fatalf("timeout did not reroute: %v", newOwner)
	}
	if err = a.acceptReception(ctx, tenant, conversation, timedOut, "late"); err == nil {
		t.Fatal("old agent accepted reassigned conversation")
	}
	if err = a.acceptReception(ctx, uuid.New(), conversation, replacement, "foreign"); err == nil {
		t.Fatal("tenant isolation failed")
	}
	if err = a.acceptReception(ctx, tenant, conversation, replacement, "客服乙"); err != nil {
		t.Fatal(err)
	}
	checkQueue(replacement, 0)
	if err = a.acceptReception(ctx, tenant, conversation, replacement, "客服乙"); err != nil {
		t.Fatal(err)
	}
	db.QueryRow(ctx, `select accepted_at,assignment_expires_at from conversation where id=$1`, conversation).Scan(&accepted, &expires)
	if accepted == nil || expires != nil {
		t.Fatal("acceptance did not clear deadline")
	}
	if _, err = a.appendMessage(ctx, tenant, conversation, messageInput{SenderType: "AGENT", SenderID: &replacement, MessageType: "TEXT", Content: "您好"}); err != nil {
		t.Fatal(err)
	}
	if err = a.advanceReception(ctx); err != nil {
		t.Fatal(err)
	}
	db.QueryRow(ctx, `select count(*) from message where conversation_id=$1 and content like '%已接入%'`, conversation).Scan(&joined)
	if joined != 1 {
		t.Fatalf("acceptance notice must be unique: %d", joined)
	}
	var view conversationView
	if err = a.queryConversation(ctx, conversation, &view); err != nil || view.AcceptedAt == nil {
		t.Fatalf("detail missing acceptance: %v", err)
	}
	// 所有候选人超时后保持排队，不重复分配给刚超时的客服。
	exec(`update conversation set accepted_at=null,assignment_expires_at=now()-interval '1 second' where id=$1`, conversation)
	if err = a.advanceReception(ctx); err != nil {
		t.Fatal(err)
	}
	a.flushReceptionNotices(ctx)
	var queued bool
	db.QueryRow(ctx, `select assignee_id is null and bot_paused from conversation where id=$1`, conversation).Scan(&queued)
	if !queued {
		t.Fatal("exhausted candidates must remain queued")
	}
	var transcript string
	db.QueryRow(ctx, `select string_agg(content,E'\n' order by sequence) from message where conversation_id=$1`, conversation).Scan(&transcript)
	if strings.Index(transcript, "转接人工") > strings.Index(transcript, "等待客服接待") {
		t.Fatal("state messages out of order")
	}
	if err = a.acceptReception(ctx, tenant, conversation, first, "主动接单"); err != nil {
		t.Fatal("queued manual claim failed", err)
	}
}

func TestInboxAutoAcceptOnAssign(t *testing.T) {
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
	if err = database.Migrate(ctx, db); err != nil {
		t.Fatal(err)
	}
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(ctx, q, args...); err != nil {
			t.Fatal(err)
		}
	}
	tenant, inbox, visitor, conversation, agent := uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New()
	exec(`insert into tenant(id,name,slug,status) values($1,'auto-accept',$2,'ACTIVE')`, tenant, tenant.String())
	exec(`insert into inbox(id,tenant_id,name,public_key,status,auto_assign,auto_accept) values($1,$2,'auto-accept',$3,'ACTIVE',true,true)`, inbox, tenant, inbox.String())
	exec(`insert into visitor(id,tenant_id,inbox_id) values($1,$2,$3)`, visitor, tenant, inbox)
	exec(`insert into conversation(id,tenant_id,inbox_id,visitor_id,status) values($1,$2,$3,$4,'OPEN')`, conversation, tenant, inbox, visitor)
	exec(`insert into agent(id,tenant_id,email,display_name,role,status,password_hash) values($1,$2,$3,'甲','AGENT','ACTIVE','x')`, agent, tenant, agent.String())
	exec(`insert into agent_inbox values($1,$2)`, agent, inbox)
	exec(`insert into agent_presence(agent_id,status,last_seen_at) values($1,'ONLINE',now())`, agent)
	defer func() {
		for _, q := range []string{
			`delete from conversation where tenant_id=$1`,
			`delete from visitor where tenant_id=$1`,
			`delete from agent where tenant_id=$1`,
			`delete from inbox where tenant_id=$1`,
			`delete from tenant where id=$1`,
		} {
			_, _ = db.Exec(ctx, q, tenant)
		}
	}()
	a := &API{db: db, logger: slog.Default(), bus: realtime.NewBus(db, realtime.NewHub(slog.Default()), slog.Default()), webhooks: webhook.NewDispatcher(db, 3, slog.Default())}
	owner, msg, err := a.completeHandoff(ctx, tenant, conversation)
	if err != nil || owner == nil || *owner != agent {
		t.Fatalf("handoff: owner=%v err=%v", owner, err)
	}
	var accepted *time.Time
	var expires *time.Time
	if err = db.QueryRow(ctx, `select accepted_at, assignment_expires_at from conversation where id=$1`, conversation).Scan(&accepted, &expires); err != nil {
		t.Fatal(err)
	}
	if accepted == nil || expires != nil {
		t.Fatalf("auto_accept must accept immediately: accepted=%v expires=%v", accepted, expires)
	}
	if !strings.Contains(msg, "已在接待中") && !strings.Contains(msg, "已接入") {
		t.Fatalf("visitor message should reflect accepted state: %q", msg)
	}
	if _, err = a.appendMessage(ctx, tenant, conversation, messageInput{SenderType: "AGENT", SenderID: &agent, MessageType: "TEXT", Content: "您好"}); err != nil {
		t.Fatal("auto-accepted agent must be able to reply", err)
	}
}
