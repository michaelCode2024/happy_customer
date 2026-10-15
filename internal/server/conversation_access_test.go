package server

import (
	"context"
	"encoding/json"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/platform/database"
	"github.com/relaydesk/relaydesk/internal/realtime"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestConversationOwnershipIsolation(t *testing.T) {
	dsn := os.Getenv("RELAYDESK_TEST_DATABASE")
	if dsn == "" {
		t.Skip("database not configured")
	}
	ctx := context.Background()
	db, e := pgxpool.New(ctx, dsn)
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	if e = database.Migrate(ctx, db); e != nil {
		t.Fatal(e)
	}
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(ctx, q, args...); err != nil {
			t.Fatal(err)
		}
	}
	tenant, inbox, first, second, supervisor := uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New()
	exec(`insert into tenant(id,name,slug,status) values($1,'scope',$2,'ACTIVE')`, tenant, tenant.String())
	defer db.Exec(ctx, `delete from tenant where id=$1`, tenant)
	exec(`insert into inbox(id,tenant_id,name,public_key,status) values($1,$2,'scope',$3,'ACTIVE')`, inbox, tenant, inbox.String())
	for _, agent := range []uuid.UUID{first, second, supervisor} {
		role := "AGENT"
		if agent == supervisor {
			role = "SUPERVISOR"
		}
		exec(`insert into agent(id,tenant_id,email,display_name,role,status,password_hash) values($1,$2,$3,$3,$4,'ACTIVE','x')`, agent, tenant, agent.String(), role)
		exec(`insert into agent_inbox(agent_id,inbox_id) values($1,$2)`, agent, inbox)
	}
	ids, visitors := []uuid.UUID{}, []uuid.UUID{}
	for i := 0; i < 3; i++ {
		id, v := uuid.New(), uuid.New()
		ids = append(ids, id)
		visitors = append(visitors, v)
		exec(`insert into visitor(id,tenant_id,inbox_id,display_name) values($1,$2,$3,'scope')`, v, tenant, inbox)
		var owner any
		if i == 0 {
			owner = first
		}
		if i == 1 {
			owner = second
		}
		exec(`insert into conversation(id,tenant_id,inbox_id,visitor_id,status,assignee_id,last_message_preview,agent_unread) values($1,$2,$3,$4,'OPEN',$5,'isolation-secret',1)`, id, tenant, inbox, v, owner)
		exec(`insert into message(id,tenant_id,conversation_id,sequence,sender_type,sender_id,message_type,content) values($1,$2,$3,1,'VISITOR',$4,'TEXT','isolation-secret')`, uuid.New(), tenant, id, v)
	}
	api := &API{db: db, logger: slog.Default()}
	p1 := auth.Principal{Kind: auth.KindAgent, TenantID: tenant, AgentID: first, Role: "AGENT"}
	p2 := p1
	p2.AgentID = second
	ps := p1
	ps.AgentID = supervisor
	ps.Role = "SUPERVISOR"
	request := func(handler func(http.ResponseWriter, *http.Request, auth.Principal), p auth.Principal, id uuid.UUID, url string) *httptest.ResponseRecorder {
		t.Helper()
		w := httptest.NewRecorder()
		r := httptest.NewRequest("GET", url, nil)
		r.SetPathValue("id", id.String())
		handler(w, r, p)
		return w
	}
	for _, p := range []auth.Principal{p1, p2, ps} {
		w := request(api.consoleConversations, p, uuid.Nil, "/?filter=all&status=ALL")
		if w.Code != 200 {
			t.Fatalf("list: %s", w.Body)
		}
		var result struct {
			Items  []conversationView `json:"items"`
			Unread int                `json:"unread"`
		}
		json.Unmarshal(w.Body.Bytes(), &result)
		want := 2
		if p.Role == "SUPERVISOR" {
			want = 1
		}
		if len(result.Items) != want || result.Unread != want {
			t.Fatalf("list/unread %s: %s", p.Role, w.Body)
		}
		for _, c := range result.Items {
			if p.Role == "AGENT" && c.ID == ids[1] && p.AgentID == first {
				t.Fatal("other owner's preview leaked")
			}
		}
	}
	// Both directions: guessing IDs must not bypass the list restriction.
	for _, pair := range []struct {
		p     auth.Principal
		index int
	}{{p1, 1}, {p2, 0}} {
		for _, handler := range []func(http.ResponseWriter, *http.Request, auth.Principal){api.consoleConversation, api.consoleMessages, api.consoleDraft, api.consolePinnedMessages, api.consoleFindInConversation, api.consoleTyping, api.consoleRead, api.consoleDelivered, api.consoleSend, api.consoleTransfer} {
			w := request(handler, pair.p, ids[pair.index], "/?q=isolation")
			if w.Code != 404 {
				t.Fatalf("resource bypass %d: %s", w.Code, w.Body)
			}
		}
		for _, handler := range []func(http.ResponseWriter, *http.Request, auth.Principal){api.consoleVisitor, api.consoleVisitorConversations, api.consoleNotes} {
			w := request(handler, pair.p, visitors[pair.index], "/")
			if w.Code != 404 {
				t.Fatalf("visitor bypass %d: %s", w.Code, w.Body)
			}
		}
		w := request(api.consoleSearchMessages, pair.p, uuid.Nil, "/?q=isolation-secret")
		if w.Code != 200 || strings.Contains(w.Body.String(), ids[pair.index].String()) {
			t.Fatalf("search bypass: %d %s", w.Code, w.Body)
		}
	}
	if !api.agentConversationAccess(ctx, p1, ids[0]) || !api.agentConversationAccess(ctx, p1, ids[2]) || !api.agentConversationAccess(ctx, ps, ids[1]) {
		t.Fatal("valid access lost")
	}
	payload := realtime.Encode(realtime.Event{Type: "message.created", ConversationID: ids[0].String(), Data: map[string]any{"content": "isolation-secret"}})
	if !strings.Contains(string(api.filterConsoleEvent(ctx, p1, payload)), "isolation-secret") {
		t.Fatal("own realtime denied")
	}
	if strings.Contains(string(api.filterConsoleEvent(ctx, p2, payload)), "isolation-secret") {
		t.Fatal("realtime leaked")
	}
	// Simulate an existing socket subscription surviving a transfer.
	exec(`update conversation set assignee_id=$2 where id=$1`, ids[0], second)
	if api.agentConversationAccess(ctx, p1, ids[0]) || !api.agentConversationAccess(ctx, p2, ids[0]) {
		t.Fatal("transfer did not revoke access")
	}
	if strings.Contains(string(api.filterConsoleEvent(ctx, p1, payload)), "isolation-secret") {
		t.Fatal("stale subscription leaked")
	}
	if request(api.consoleMessages, p1, ids[0], "/").Code != 404 {
		t.Fatal("old owner can read after transfer")
	}
	t.Log("PASS: bidirectional list/detail/messages/draft/search/visitor/realtime/transfer isolation; supervisor and reception preserved")
}
