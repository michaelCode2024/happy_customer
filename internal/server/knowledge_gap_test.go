package server

import (
	"context"
	"log/slog"
	"os"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/tongyu/tongyu/internal/ai"
	"github.com/tongyu/tongyu/internal/platform/database"
	"github.com/tongyu/tongyu/internal/realtime"
	"github.com/tongyu/tongyu/internal/webhook"
)

func TestNoKnowledgeHandoffRecordsGap(t *testing.T) {
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
	tenant, inbox, visitor, conversation, question, interaction := uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New()
	exec(`insert into tenant(id,name,slug,status) values($1,'gap regression',$2,'ACTIVE')`, tenant, tenant.String())
	exec(`insert into inbox(id,tenant_id,name,public_key,status,auto_assign) values($1,$2,'gap',$3,'ACTIVE',false)`, inbox, tenant, inbox.String())
	exec(`insert into visitor(id,tenant_id,inbox_id) values($1,$2,$3)`, visitor, tenant, inbox)
	exec(`insert into conversation(id,tenant_id,inbox_id,visitor_id,status,last_sequence) values($1,$2,$3,$4,'OPEN',1)`, conversation, tenant, inbox, visitor)
	exec(`insert into message(id,tenant_id,conversation_id,sender_type,message_type,content,sequence) values($1,$2,$3,'VISITOR','TEXT','接入需要准备什么',1)`, question, tenant, conversation)
	a := &API{db: db, logger: slog.Default(), bus: realtime.NewBus(db, realtime.NewHub(slog.Default()), slog.Default()), webhooks: webhook.NewDispatcher(db, 3, slog.Default())}
	a.storeAIHandoff(ctx, tenant, conversation, messageView{ID: question}, interaction, ai.Reply{Provider: "test", Handoff: true, Reason: ai.ReasonNoKnowledge}, "转人工", 1)
	var reason string
	var sources []string
	if err = db.QueryRow(ctx, `select reason,sources from ai_interaction where id=$1`, interaction).Scan(&reason, &sources); err != nil {
		t.Fatal("没有知识时也必须记录缺口: ", err)
	}
	if reason != "NO_KNOWLEDGE_BASE" || sources == nil || len(sources) != 0 {
		t.Fatalf("无知识命中应使用空来源数组: reason=%s sources=%v", reason, sources)
	}
}
