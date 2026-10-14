package server

import (
	"context"
	"encoding/json"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/realtime"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// 同时检查实时频道和补拉历史，避免备注在一个通道隐藏、另一个通道泄露。
func TestInternalNotesStayAgentOnly(t *testing.T) {
	dsn := os.Getenv("RELAYDESK_TEST_DATABASE")
	if dsn == "" {
		t.Skip("database not configured")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	tenant, inbox, visitor, conversation, agent := uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New()
	defer func() {
		pool.Exec(ctx, `delete from message where tenant_id=$1`, tenant)
		pool.Exec(ctx, `delete from conversation where tenant_id=$1`, tenant)
		pool.Exec(ctx, `delete from visitor where tenant_id=$1`, tenant)
		pool.Exec(ctx, `delete from inbox where tenant_id=$1`, tenant)
		pool.Exec(ctx, `delete from agent where tenant_id=$1`, tenant)
		pool.Exec(ctx, `delete from tenant where id=$1`, tenant)
	}()
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, args...); err != nil {
			t.Fatal(err)
		}
	}
	exec(`insert into tenant(id,name,slug,status) values($1,'privacy test',$2,'ACTIVE')`, tenant, tenant.String())
	exec(`insert into inbox(id,tenant_id,name,public_key,status) values($1,$2,'test',$3,'ACTIVE')`, inbox, tenant, inbox.String())
	exec(`insert into visitor(id,tenant_id,inbox_id) values($1,$2,$3)`, visitor, tenant, inbox)
	exec(`insert into conversation(id,tenant_id,inbox_id,visitor_id,status) values($1,$2,$3,$4,'OPEN')`, conversation, tenant, inbox, visitor)
	exec(`insert into message(id,tenant_id,conversation_id,sender_type,sequence,message_type,content,is_private) values($1,$2,$3,'AGENT',1,'TEXT','public message',false)`, uuid.New(), tenant, conversation)
	exec(`insert into message(id,tenant_id,conversation_id,sender_type,sequence,message_type,content,is_private) values($1,$2,$3,'AGENT',2,'EVENT','private secret note',true)`, uuid.New(), tenant, conversation)
	a := &API{db: pool}
	channels := a.agentOnlyChannels(ctx, conversation)
	if len(channels) == 0 {
		t.Fatal("no agent channel")
	}
	for _, channel := range channels {
		if channel == realtime.ConversationChannel(conversation.String()) || channel == realtime.VisitorChannel(visitor.String()) {
			t.Fatal("private event on visitor accessible channel")
		}
	}
	visible, err := a.pageMessages(ctx, conversation, 0, 0, 50, visitorVisibility)
	if err != nil {
		t.Fatal(err)
	}
	if len(visible.Items) != 1 || visible.Items[0].Private {
		t.Fatal("private note in visitor history")
	}
	staff, err := a.pageMessages(ctx, conversation, 0, 0, 50, agentVisibility)
	if err != nil {
		t.Fatal(err)
	}
	if len(staff.Items) != 2 {
		t.Fatal("agent cannot read internal note")
	}
	hits, err := a.searchMessagesInConversation(ctx, conversation, "private secret", 20, visitorVisibility)
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 0 {
		t.Fatal("private note in visitor search")
	}
	// 重试必须返回同一条备注；推送与 HTTP 响应用此标识替换乐观消息。
	exec(`insert into agent(id,tenant_id,email,display_name,password_hash,role,status) values($1,$2,$3,'当前坐席名称','test','SUPERVISOR','ACTIVE')`, agent, tenant, agent.String()+"@test.local")
	exec(`update conversation set assignee_id=$1,last_sequence=2 where id=$2`, agent, conversation)
	a.bus = realtime.NewBus(pool, realtime.NewHub(slog.Default()), slog.Default())
	var firstID uuid.UUID
	for attempt := 0; attempt < 2; attempt++ {
		r := httptest.NewRequest("POST", "/", strings.NewReader(`{"content":"deduplicated private note","private":true,"clientMessageId":"private-retry-test"}`))
		r.SetPathValue("id", conversation.String())
		w := httptest.NewRecorder()
		a.consoleSend(w, r, auth.Principal{TenantID: tenant, AgentID: agent, Name: "旧名称"})
		if w.Code != 201 {
			t.Fatalf("private send %d: %s", w.Code, w.Body.String())
		}
		var saved messageView
		if err := json.Unmarshal(w.Body.Bytes(), &saved); err != nil {
			t.Fatal(err)
		}
		if saved.ClientMessageID == nil || *saved.ClientMessageID != "private-retry-test" || saved.SenderName != "当前坐席名称" {
			t.Fatalf("invalid private response: %+v", saved)
		}
		if attempt == 0 {
			firstID = saved.ID
		} else if saved.ID != firstID {
			t.Fatal("retry created another private note")
		}
	}
}
