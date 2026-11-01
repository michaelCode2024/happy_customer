package server

import (
	"context"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/tongyu/tongyu/internal/platform/database"
	"github.com/tongyu/tongyu/internal/realtime"
	"github.com/tongyu/tongyu/internal/webhook"
)

// 结束宽限期：宽限期内访客再发言复活原会话并保留原接待人；超过宽限期或宽限期为 0
// 时自动新建无主会话进入待接待大厅，新会话用 EVENT 关联上一轮咨询。
func TestInboxReopenGraceForksToLobby(t *testing.T) {
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
	graced, closed := uuid.New(), uuid.New()
	first := uuid.New()
	exec(`insert into tenant(id,name,slug,status) values($1,'grace',$2,'ACTIVE')`, tenant, tenant.String())
	exec(`insert into inbox(id,tenant_id,name,public_key,status,auto_assign,reopen_grace_minutes) values($1,$2,'grace',$3,'ACTIVE',false,1440)`, inbox, tenant, inbox.String())
	exec(`insert into visitor(id,tenant_id,inbox_id) values($1,$2,$3)`, visitor, tenant, inbox)
	exec(`insert into agent(id,tenant_id,email,display_name,role,status,password_hash) values($1,$2,$3,$3,'AGENT','ACTIVE','x')`, first, tenant, first.String())
	exec(`insert into agent_inbox values($1,$2)`, first, inbox)
	for _, c := range []struct {
		id        uuid.UUID
		closedAgo time.Duration
	}{
		{graced, time.Hour},
		{closed, 25 * time.Hour},
	} {
		exec(`insert into conversation(id,tenant_id,inbox_id,visitor_id,subject,status,assignee_id,closed_at,last_sequence)
			values($1,$2,$3,$4,'咨询','RESOLVED',$5,now()-($6::double precision * interval '1 minute'),1)`,
			c.id, tenant, inbox, visitor, first, float64(c.closedAgo.Minutes()))
		exec(`insert into message(id,tenant_id,conversation_id,sender_type,sequence,message_type,content)
			values($1,$2,$3,'VISITOR',1,'TEXT','上一轮问题')`, uuid.New(), tenant, c.id)
	}
	defer func() {
		for _, q := range []string{`delete from conversation where tenant_id=$1`, `delete from visitor where tenant_id=$1`, `delete from agent where tenant_id=$1`, `delete from inbox where tenant_id=$1`, `delete from tenant where id=$1`} {
			db.Exec(ctx, q, tenant)
		}
	}()
	a := &API{db: db, logger: slog.Default(), bus: realtime.NewBus(db, realtime.NewHub(slog.Default()), slog.Default()), webhooks: webhook.NewDispatcher(db, 3, slog.Default())}

	// 宽限期内：复活原会话，原接待人和上下文都不变。
	kept, err := a.appendMessage(ctx, tenant, graced, messageInput{SenderType: "VISITOR", MessageType: "TEXT", Content: "补充一句"})
	if err != nil {
		t.Fatalf("revive within grace: %v", err)
	}
	var status string
	var closedAt *time.Time
	var assignee *uuid.UUID
	if err = db.QueryRow(ctx, `select status, closed_at, assignee_id from conversation where id=$1`, graced).Scan(&status, &closedAt, &assignee); err != nil {
		t.Fatal(err)
	}
	if status != "OPEN" || closedAt != nil || assignee == nil || *assignee != first {
		t.Fatalf("grace revive kept %#v status=%s closed=%v assignee=%v", kept, status, closedAt, assignee)
	}

	// 超宽限：新建会话进入大厅，原会话保持结束状态。
	forked, err := a.appendMessage(ctx, tenant, closed, messageInput{SenderType: "VISITOR", MessageType: "TEXT", Content: "新问题"})
	if err != nil {
		t.Fatalf("fork after grace: %v", err)
	}
	if forked.ConversationID == closed {
		t.Fatalf("expired conversation must not be reused: %s", forked.ConversationID)
	}
	var newStatus string
	var newInbox, newVisitor uuid.UUID
	var newAssignee *uuid.UUID
	if err = db.QueryRow(ctx, `select status, inbox_id, visitor_id, assignee_id from conversation where id=$1`, forked.ConversationID).Scan(&newStatus, &newInbox, &newVisitor, &newAssignee); err != nil {
		t.Fatal(err)
	}
	if newStatus != "OPEN" || newInbox != inbox || newVisitor != visitor || newAssignee != nil {
		t.Fatalf("forked conversation must be ownerless and in the same inbox: %s %#v", forked.ConversationID, newStatus)
	}
	var events, messages int
	if err = db.QueryRow(ctx, `select count(*) from message where conversation_id=$1 and message_type='EVENT' and metadata->>'fork'='true'`, forked.ConversationID).Scan(&events); err != nil {
		t.Fatal(err)
	}
	if events != 1 {
		t.Fatalf("forked conversation must link the previous one, events=%d", events)
	}
	if err = db.QueryRow(ctx, `select count(*) from message where conversation_id=$1`, forked.ConversationID).Scan(&messages); err != nil {
		t.Fatal(err)
	}
	if messages != 2 {
		t.Fatalf("visitor message must land in the new conversation, got %d", messages)
	}
	if err = db.QueryRow(ctx, `select status from conversation where id=$1`, closed).Scan(&status); err != nil {
		t.Fatal(err)
	}
	if status != "RESOLVED" {
		t.Fatalf("previous conversation must stay resolved, got %s", status)
	}

	// 原会话补一条回指提示，序列号同步递增，坐席翻归档时看得出访客已另起线程。
	var pointerCount int
	var parentSequence, pointerSeq int64
	var pointerNext *string
	if err = db.QueryRow(ctx, `
		select count(*), coalesce(max(sequence), 0), max(metadata->>'nextConversationId')
		  from message
		 where conversation_id = $1 and message_type = 'EVENT'
		   and metadata->>'nextConversationId' is not null`, closed).
		Scan(&pointerCount, &pointerSeq, &pointerNext); err != nil {
		t.Fatal(err)
	}
	if pointerCount != 1 || pointerNext == nil || *pointerNext != forked.ConversationID.String() {
		t.Fatalf("previous conversation must carry one forward pointer, count=%d next=%v", pointerCount, pointerNext)
	}
	if err = db.QueryRow(ctx, `select last_sequence from conversation where id=$1`, closed).Scan(&parentSequence); err != nil {
		t.Fatal(err)
	}
	if parentSequence != pointerSeq {
		t.Fatalf("pointer must advance the conversation cursor: last_sequence=%d message=%d", parentSequence, pointerSeq)
	}

	// 旧客户端把后续消息和重试仍发到已结束的原会话：复用刚分流出的进行中会话，
	// 并按幂等标识返回原消息，不在大厅里刷出重复线程。
	exec(`update inbox set reopen_grace_minutes=0 where id=$1`, inbox)
	followUp, err := a.appendMessage(ctx, tenant, closed, messageInput{SenderType: "VISITOR", MessageType: "TEXT", Content: "再补一句", ClientMessageID: "retry-1"})
	if err != nil {
		t.Fatalf("follow-up on resolved conversation: %v", err)
	}
	if followUp.ConversationID != forked.ConversationID {
		t.Fatalf("follow-up must reuse the forked conversation, got %s want %s", followUp.ConversationID, forked.ConversationID)
	}
	retried, err := a.appendMessage(ctx, tenant, closed, messageInput{SenderType: "VISITOR", MessageType: "TEXT", Content: "再补一句", ClientMessageID: "retry-1"})
	if err != nil {
		t.Fatalf("idempotent retry: %v", err)
	}
	if retried.ID != followUp.ID {
		t.Fatalf("retry must return the stored message, got %s want %s", retried.ID, followUp.ID)
	}
	if err = db.QueryRow(ctx, `select count(*) from message where conversation_id=$1 and message_type='EVENT' and metadata->>'nextConversationId' is not null`, closed).Scan(&pointerCount); err != nil {
		t.Fatal(err)
	}
	if pointerCount != 1 {
		t.Fatalf("reusing the forked conversation must not repeat the pointer, got %d", pointerCount)
	}

	// 宽限期为 0：刚结束也直接进大厅，不复用别的会话。
	exec(`update conversation set status='RESOLVED', closed_at=now() where id=$1`, graced)
	zeroGrace, err := a.appendMessage(ctx, tenant, graced, messageInput{SenderType: "VISITOR", MessageType: "TEXT", Content: "再来一次"})
	if err != nil {
		t.Fatalf("fork with zero grace: %v", err)
	}
	if zeroGrace.ConversationID == graced || zeroGrace.ConversationID == forked.ConversationID {
		t.Fatalf("zero grace must always start a new conversation, got %s", zeroGrace.ConversationID)
	}

	var threads int
	if err = db.QueryRow(ctx, `select count(*) from conversation where tenant_id=$1`, tenant).Scan(&threads); err != nil {
		t.Fatal(err)
	}
	if threads != 4 {
		t.Fatalf("expected 2 originals plus 2 forks, got %d conversations", threads)
	}
}
