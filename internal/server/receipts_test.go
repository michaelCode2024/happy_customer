package server

import (
	"context"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/relaydesk/relaydesk/internal/realtime"
	"github.com/relaydesk/relaydesk/internal/webhook"
	"log/slog"
	"os"
	"testing"
)

func TestReceiptBoundaryAndWebhookOutbox(t *testing.T) {
	dsn := os.Getenv("RELAYDESK_TEST_DATABASE")
	if dsn == "" {
		t.Skip("database not configured")
	}
	ctx := context.Background()
	db, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	tenant, inbox, visitor, conv := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	run := func(sql string, args ...any) {
		t.Helper()
		if _, e := db.Exec(ctx, sql, args...); e != nil {
			t.Fatal(e)
		}
	}
	defer func() {
		if _, err := db.Exec(ctx, `delete from tenant where id=$1`, tenant); err != nil {
			_, _ = db.Exec(ctx, `update tenant set status='SUSPENDED' where id=$1`, tenant)
		}
	}()
	run(`insert into tenant(id,name,slug,status) values($1,'receipt test',$2,'ACTIVE')`, tenant, tenant.String())
	run(`insert into tenant_subscription(tenant_id,plan,status) values($1,'ENTERPRISE','ACTIVE')`, tenant)
	run(`insert into inbox(id,tenant_id,name,public_key,status) values($1,$2,'receipt test',$3,'ACTIVE')`, inbox, tenant, inbox.String())
	run(`insert into visitor(id,tenant_id,inbox_id) values($1,$2,$3)`, visitor, tenant, inbox)
	run(`insert into conversation(id,tenant_id,inbox_id,visitor_id,status,last_sequence,visitor_unread) values($1,$2,$3,$4,'OPEN',3,2)`, conv, tenant, inbox, visitor)
	for i := 1; i <= 3; i++ {
		run(`insert into message(id,tenant_id,conversation_id,sender_type,sequence,message_type,content,is_private) values($1,$2,$3,'AGENT',$4,'TEXT','test',$5)`, uuid.New(), tenant, conv, i, i == 2)
	}
	run(`insert into webhook_endpoint(id,tenant_id,url,secret,status,events) values($1,$2,'http://127.0.0.1/test','test-secret','ACTIVE',array['conversation.read','conversation.delivered'])`, uuid.New(), tenant)
	a := &API{db: db, logger: slog.Default(), bus: realtime.NewBus(db, realtime.NewHub(slog.Default()), slog.Default()), webhooks: webhook.NewDispatcher(db, 3, slog.Default())}
	if err = a.markRead(ctx, conv, tenant, "VISITOR", visitor, 1); err != nil {
		t.Fatal(err)
	}
	if err = a.markRead(ctx, conv, tenant, "VISITOR", visitor, 0); err == nil {
		t.Fatal("zero receipt boundary accepted")
	}
	var unread int
	db.QueryRow(ctx, `select visitor_unread from conversation where id=$1`, conv).Scan(&unread)
	if unread != 1 {
		t.Fatalf("partial read cleared later message: %d", unread)
	}
	if err = a.markRead(ctx, conv, tenant, "VISITOR", visitor, 1); err != nil {
		t.Fatal(err)
	}
	if err = a.markRead(ctx, conv, tenant, "VISITOR", visitor, 999); err != nil {
		t.Fatal(err)
	}
	var read int64
	db.QueryRow(ctx, `select last_read_sequence from conversation_read where conversation_id=$1`, conv).Scan(&read)
	if read != 3 {
		t.Fatalf("cursor escaped boundary: %d", read)
	}
	if err = a.markRead(ctx, conv, tenant, "VISITOR", visitor, 1); err != nil {
		t.Fatal(err)
	}
	if err = a.markDelivered(ctx, conv, tenant, "VISITOR", visitor, 3); err != nil {
		t.Fatal(err)
	}
	var count int
	db.QueryRow(ctx, `select count(*) from webhook_delivery where tenant_id=$1`, tenant).Scan(&count)
	if count != 3 {
		t.Fatalf("duplicate or missing webhook: %d", count)
	}
	if err = a.markRead(ctx, conv, uuid.New(), "VISITOR", visitor, 3); err == nil {
		t.Fatal("cross tenant receipt accepted")
	}
}
