package server

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/tongyu/tongyu/internal/auth"
	"github.com/tongyu/tongyu/internal/platform/database"
	"github.com/tongyu/tongyu/internal/realtime"
	"github.com/tongyu/tongyu/internal/webhook"
)

// 结束后访客再发言另开一轮。原来的一轮保持结束和原接待人。
// 新的一轮没有接待人，出现在该入口的待接待。一小时内和超过一天都一样。
func TestVisitorReplyStartsNewConversation(t *testing.T) {
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
	tenant, inbox, visitor := uuid.New(), uuid.New(), uuid.New()
	recent, expired := uuid.New(), uuid.New()
	first := uuid.New()
	exec(`insert into tenant(id,name,slug,status) values($1,'reopen',$2,'ACTIVE')`, tenant, tenant.String())
	exec(`insert into inbox(id,tenant_id,name,public_key,status,auto_assign,reopen_grace_minutes) values($1,$2,'reopen',$3,'ACTIVE',false,1440)`, inbox, tenant, inbox.String())
	exec(`insert into visitor(id,tenant_id,inbox_id) values($1,$2,$3)`, visitor, tenant, inbox)
	exec(`insert into agent(id,tenant_id,email,display_name,role,status,password_hash) values($1,$2,$3,$3,'AGENT','ACTIVE','x')`, first, tenant, first.String())
	exec(`insert into agent_inbox values($1,$2)`, first, inbox)
	exec(`insert into agent_presence(agent_id,status,last_seen_at) values($1,'ONLINE',now())`, first)
	for _, c := range []struct {
		id        uuid.UUID
		closedAgo time.Duration
	}{
		{recent, time.Hour},
		{expired, 25 * time.Hour},
	} {
		exec(`insert into conversation(id,tenant_id,inbox_id,visitor_id,subject,status,assignee_id,accepted_at,assigned_at,assignment_expires_at,closed_at,last_sequence)
			values($1,$2,$3,$4,'咨询','RESOLVED',$5,now(),now(),now()+interval '10 minutes',now()-($6::double precision * interval '1 minute'),2)`,
			c.id, tenant, inbox, visitor, first, float64(c.closedAgo.Minutes()))
		exec(`insert into message(id,tenant_id,conversation_id,sender_type,sequence,message_type,content)
			values($1,$2,$3,'VISITOR',1,'TEXT','上一轮问题')`, uuid.New(), tenant, c.id)
		exec(`insert into message(id,tenant_id,conversation_id,sender_type,sequence,message_type,content,metadata)
			values($1,$2,$3,'SYSTEM',2,'EVENT','客服已结束本次会话。','{"ended":true}')`, uuid.New(), tenant, c.id)
	}
	defer func() {
		db.Exec(ctx, `delete from agent_presence where agent_id=$1`, first)
		for _, q := range []string{
			`delete from message where tenant_id=$1`,
			`delete from conversation where tenant_id=$1`,
			`delete from visitor where tenant_id=$1`,
			`delete from agent where tenant_id=$1`,
			`delete from inbox where tenant_id=$1`,
			`delete from tenant where id=$1`,
		} {
			db.Exec(ctx, q, tenant)
		}
	}()
	a := &API{db: db, logger: slog.Default(), bus: realtime.NewBus(db, realtime.NewHub(slog.Default()), slog.Default()), webhooks: webhook.NewDispatcher(db, 3, slog.Default())}

	opened := map[uuid.UUID]uuid.UUID{}
	assertForked := func(id uuid.UUID, content string) {
		t.Helper()
		saved, err := a.appendMessage(ctx, tenant, id, messageInput{SenderType: "VISITOR", MessageType: "TEXT", Content: content})
		if err != nil {
			t.Fatalf("visitor reply: %v", err)
		}
		if saved.ConversationID == id {
			t.Fatalf("reply must start a new conversation, stayed on %s", id)
		}
		var status string
		var closedAt *time.Time
		var assignee *uuid.UUID
		if err = db.QueryRow(ctx, `select status, closed_at, assignee_id from conversation where id=$1`, id).Scan(&status, &closedAt, &assignee); err != nil {
			t.Fatal(err)
		}
		if status != "RESOLVED" || closedAt == nil || assignee == nil || *assignee != first {
			t.Fatalf("ended conversation must stay archived with its assignee: status=%s closed=%v assignee=%v", status, closedAt, assignee)
		}
		var nextStatus string
		var nextAssignee *uuid.UUID
		if err = db.QueryRow(ctx, `select status, assignee_id from conversation where id=$1`, saved.ConversationID).Scan(&nextStatus, &nextAssignee); err != nil {
			t.Fatal(err)
		}
		if nextStatus != "OPEN" || nextAssignee != nil {
			t.Fatalf("new conversation must wait in the queue: status=%s assignee=%v", nextStatus, nextAssignee)
		}
		opened[id] = saved.ConversationID
	}
	assertForked(recent, "一小时后再问")
	assertForked(expired, "超过一天再问")
	if err = a.advanceReception(ctx); err != nil {
		t.Fatal(err)
	}
	again, err := a.appendMessage(ctx, tenant, recent, messageInput{SenderType: "VISITOR", MessageType: "TEXT", Content: "还没人接，再发一句"})
	if err != nil {
		t.Fatal(err)
	}
	if again.ConversationID != opened[recent] {
		t.Fatalf("follow-up must stay on the new conversation %s, got %s", opened[recent], again.ConversationID)
	}
	if _, err = a.appendMessage(ctx, tenant, recent, messageInput{SenderType: "AGENT", SenderID: &first, MessageType: "TEXT", Content: "我把旧的打开"}); err == nil {
		t.Fatal("agent must not reply into an ended conversation")
	}

	var threads int
	if err = db.QueryRow(ctx, `select count(*) from conversation where tenant_id=$1`, tenant).Scan(&threads); err != nil {
		t.Fatal(err)
	}
	if threads != 4 {
		t.Fatalf("each ended conversation must open one new conversation, got %d", threads)
	}

	second := uuid.New()
	exec(`insert into agent(id,tenant_id,email,display_name,role,status,password_hash) values($1,$2,$3,$3,'AGENT','ACTIVE','x')`, second, tenant, second.String())
	exec(`insert into agent_inbox values($1,$2)`, second, inbox)
	for _, agent := range []uuid.UUID{first, second} {
		w := httptest.NewRecorder()
		a.consoleConversations(w, httptest.NewRequest("GET", "/?filter=reception", nil), auth.Principal{TenantID: tenant, AgentID: agent})
		var body struct {
			Items []conversationView `json:"items"`
		}
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &body) != nil {
			t.Fatalf("reception queue: status=%d body=%s", w.Code, w.Body)
		}
		seen := map[uuid.UUID]bool{}
		for _, item := range body.Items {
			if item.AssigneeID != nil {
				t.Fatalf("reception item still has an assignee: %s", item.ID)
			}
			seen[item.ID] = true
		}
		if seen[recent] || seen[expired] || !seen[opened[recent]] || !seen[opened[expired]] {
			t.Fatalf("queue must list the new conversations only: %s", w.Body)
		}
	}

	exec(`update inbox set reopen_grace_minutes=0 where id=$1`, inbox)
	exec(`update conversation set status='RESOLVED', closed_at=now() where id=$1`, opened[recent])
	assertForked(recent, "宽限期为 0 也另开一轮")
	if err = db.QueryRow(ctx, `select count(*) from conversation where tenant_id=$1`, tenant).Scan(&threads); err != nil {
		t.Fatal(err)
	}
	if threads != 5 {
		t.Fatalf("closing the new round and speaking again must open another one, got %d", threads)
	}
}
