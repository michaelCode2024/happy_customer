package server

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/tongyu/tongyu/internal/auth"
	"github.com/tongyu/tongyu/internal/platform/database"
	"github.com/tongyu/tongyu/internal/realtime"
	"github.com/tongyu/tongyu/internal/webhook"
)

// 结束提示：客服标记解决时消息流要留下一条系统行，访客必须看得见（否则以为还在接待），
// 重复标记解决则不能再补一条。
func TestResolveWritesVisitorVisibleEndedNotice(t *testing.T) {
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
	tenant, inbox, visitor, agent, conversation := uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New()
	exec(`insert into tenant(id,name,slug,status) values($1,'ended-notice',$2,'ACTIVE')`, tenant, tenant.String())
	exec(`insert into inbox(id,tenant_id,name,public_key,status,auto_assign) values($1,$2,'ended',$3,'ACTIVE',false)`, inbox, tenant, inbox.String())
	exec(`insert into visitor(id,tenant_id,inbox_id) values($1,$2,$3)`, visitor, tenant, inbox)
	exec(`insert into agent(id,tenant_id,email,display_name,role,status,password_hash) values($1,$2,$3,$3,'AGENT','ACTIVE','x')`, agent, tenant, agent.String())
	exec(`insert into agent_inbox values($1,$2)`, agent, inbox)
	exec(`insert into conversation(id,tenant_id,inbox_id,visitor_id,subject,status,assignee_id,last_sequence)
		values($1,$2,$3,$4,'咨询','OPEN',$5,1)`, conversation, tenant, inbox, visitor, agent)
	exec(`insert into message(id,tenant_id,conversation_id,sender_type,sequence,message_type,content)
		values($1,$2,$3,'VISITOR',1,'TEXT','第一个问题')`, uuid.New(), tenant, conversation)
	defer func() {
		for _, q := range []string{`delete from message where tenant_id=$1`, `delete from conversation where tenant_id=$1`, `delete from visitor where tenant_id=$1`, `delete from agent where tenant_id=$1`, `delete from inbox where tenant_id=$1`, `delete from tenant where id=$1`} {
			db.Exec(ctx, q, tenant)
		}
	}()
	a := &API{db: db, logger: slog.Default(), bus: realtime.NewBus(db, realtime.NewHub(slog.Default()), slog.Default()), webhooks: webhook.NewDispatcher(db, 3, slog.Default())}
	agentPrincipal := auth.Principal{TenantID: tenant, AgentID: agent, Role: "AGENT"}
	visitorPrincipal := auth.Principal{TenantID: tenant, InboxID: inbox, VisitorID: visitor}

	resolve := func() *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("POST", "/", strings.NewReader(`{"status":"RESOLVED"}`)).WithContext(ctx)
		r.SetPathValue("id", conversation.String())
		a.consoleStatus(w, r, agentPrincipal)
		return w
	}
	visitorItems := func() []map[string]any {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("GET", "/", nil).WithContext(ctx)
		r.SetPathValue("id", conversation.String())
		a.listMessages(w, r, visitorPrincipal)
		if w.Code != 200 {
			t.Fatalf("visitor history: status=%d body=%s", w.Code, w.Body)
		}
		var body struct {
			Items []map[string]any `json:"items"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		return body.Items
	}

	if w := resolve(); w.Code != 200 {
		t.Fatalf("resolve: status=%d body=%s", w.Code, w.Body)
	}
	items := visitorItems()
	if len(items) != 2 {
		t.Fatalf("visitor must see the ended notice in the thread: %#v", items)
	}
	notice := items[1]
	if notice["senderType"] != "SYSTEM" || notice["messageType"] != "EVENT" {
		t.Fatalf("ended notice must be a system event: %#v", notice)
	}
	if notice["content"] != "客服已结束本次会话。" {
		t.Fatalf("unexpected notice text: %#v", notice["content"])
	}
	if private, ok := notice["private"].(bool); ok && private {
		t.Fatalf("ended notice must not be an internal note: %#v", notice)
	}
	if seq, ok := notice["sequence"].(float64); !ok || seq != 2 {
		t.Fatalf("notice must advance the cursor so incremental polling cannot skip it: %#v", notice["sequence"])
	}
	var lastSequence int64
	if err := db.QueryRow(ctx, `select last_sequence from conversation where id=$1`, conversation).Scan(&lastSequence); err != nil {
		t.Fatal(err)
	}
	if lastSequence != 2 {
		t.Fatalf("conversation cursor must match the notice: last_sequence=%d", lastSequence)
	}

	// 重复标记解决（访客端刷新、客服连点）不能再补一条。
	if w := resolve(); w.Code != 200 {
		t.Fatalf("resolve again: status=%d body=%s", w.Code, w.Body)
	}
	var notices int
	if err := db.QueryRow(ctx, `select count(*) from message where conversation_id=$1 and metadata->>'ended'='true'`, conversation).Scan(&notices); err != nil {
		t.Fatal(err)
	}
	if notices != 1 {
		t.Fatalf("repeated resolve must not add another notice: %d", notices)
	}
	if items := visitorItems(); len(items) != 2 {
		t.Fatalf("visitor history grew after the second resolve: %#v", items)
	}
}
