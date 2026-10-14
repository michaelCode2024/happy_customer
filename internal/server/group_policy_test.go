package server

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/platform/database"
	"github.com/relaydesk/relaydesk/internal/realtime"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestWelfareGroupRolesInvitesAndThousandMembers(t *testing.T) {
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
	if err = database.Migrate(ctx, db); err != nil {
		t.Fatal(err)
	}
	tenant, inbox := uuid.New(), uuid.New()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(ctx, q, args...); err != nil {
			t.Fatal(err)
		}
	}
	exec(`insert into tenant(id,name,slug,status) values($1,'welfare test',$2,'ACTIVE')`, tenant, tenant.String())
	exec(`insert into tenant_subscription(tenant_id,plan,status) values($1,'ENTERPRISE','ACTIVE')`, tenant)
	exec(`insert into inbox(id,tenant_id,name,public_key,status) values($1,$2,'shop',$3,'ACTIVE')`, inbox, tenant, inbox.String())
	defer func() {
		for _, q := range []string{
			`delete from chat_group_invite where group_id in(select id from chat_group where tenant_id=$1)`,
			`delete from chat_group_message where group_id in(select id from chat_group where tenant_id=$1)`,
			`delete from chat_group_member where group_id in(select id from chat_group where tenant_id=$1)`,
			`delete from chat_group where tenant_id=$1`, `delete from visitor where tenant_id=$1`, `delete from inbox where tenant_id=$1`, `delete from tenant_subscription where tenant_id=$1`, `delete from tenant where id=$1`,
		} {
			db.Exec(ctx, q, tenant)
		}
	}()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	a := &API{db: db, bus: realtime.NewBus(db, realtime.NewHub(logger), logger), tokens: auth.NewTokenService("welfare-test", time.Hour, time.Hour)}
	p := apiKeyPrincipal{TenantID: tenant}
	var gid string
	open := func(fn func(http.ResponseWriter, *http.Request, apiKeyPrincipal), body any, status int) *httptest.ResponseRecorder {
		t.Helper()
		raw, _ := json.Marshal(body)
		r := httptest.NewRequest("POST", "/", strings.NewReader(string(raw)))
		r.SetPathValue("id", gid)
		w := httptest.NewRecorder()
		fn(w, r, p)
		if w.Code != status {
			t.Fatalf("want %d got %d: %s", status, w.Code, w.Body.String())
		}
		return w
	}
	created := open(a.openGroupCreate, map[string]any{"inboxKey": inbox.String(), "externalGroupId": "shop-welfare", "name": "店铺福利群", "speakingMode": "MANAGERS", "owner": map[string]any{"externalId": "owner"}, "members": []map[string]any{{"externalId": "staff"}, {"externalId": "buyer"}}}, 201)
	var result struct {
		ID string `json:"id"`
	}
	json.Unmarshal(created.Body.Bytes(), &result)
	gid = result.ID
	open(a.openGroupPolicy, map[string]any{"actorExternalId": "buyer", "speakingMode": "ALL"}, 403)
	open(a.openGroupManager, map[string]any{"actorExternalId": "buyer", "externalId": "buyer", "isManager": true}, 403)
	open(a.openGroupManager, map[string]any{"actorExternalId": "owner", "externalId": "staff", "isManager": true}, 200)
	principal := func(external string) auth.Principal {
		var visitor uuid.UUID
		if db.QueryRow(ctx, `select id from visitor where inbox_id=$1 and external_id=$2`, inbox, external).Scan(&visitor) != nil {
			t.Fatal("missing visitor")
		}
		return auth.Principal{Kind: auth.KindWidget, TenantID: tenant, InboxID: inbox, VisitorID: visitor}
	}
	call := func(fn func(http.ResponseWriter, *http.Request, auth.Principal), actor string, body any, status int) *httptest.ResponseRecorder {
		t.Helper()
		raw, _ := json.Marshal(body)
		r := httptest.NewRequest("POST", "/", strings.NewReader(string(raw)))
		r.SetPathValue("id", gid)
		w := httptest.NewRecorder()
		fn(w, r, principal(actor))
		if w.Code != status {
			t.Fatalf("%s want %d got %d: %s", actor, status, w.Code, w.Body.String())
		}
		return w
	}
	message := map[string]any{"content": "福利通知", "clientId": uuid.NewString()}
	call(a.groupSend, "buyer", message, 403)
	call(a.groupSend, "staff", message, 201)
	open(a.openGroupManager, map[string]any{"actorExternalId": "owner", "externalId": "staff", "isManager": false}, 200)
	// 已成功的重试仍幂等；撤销管理员后不能发新消息。
	call(a.groupSend, "staff", message, 200)
	call(a.groupSend, "staff", map[string]any{"content": "越权", "clientId": uuid.NewString()}, 403)
	open(a.openGroupPolicy, map[string]any{"actorExternalId": "owner", "speakingMode": "ALL"}, 200)
	call(a.groupSend, "buyer", map[string]any{"content": "买家消息", "clientId": uuid.NewString()}, 201)
	open(a.openGroupInvite, map[string]any{"actorExternalId": "buyer"}, 403)
	invite := open(a.openGroupInvite, map[string]any{"actorExternalId": "owner"}, 200)
	var invitation struct {
		Ticket string `json:"ticket"`
	}
	json.Unmarshal(invite.Body.Bytes(), &invitation)
	join := func(ticket, identity string, status int) {
		t.Helper()
		raw, _ := json.Marshal(map[string]any{"name": "买家", "identityToken": identity})
		r := httptest.NewRequest("POST", "/", strings.NewReader(string(raw)))
		r.SetPathValue("ticket", ticket)
		w := httptest.NewRecorder()
		a.groupJoin(w, r)
		if w.Code != status {
			t.Fatalf("join want %d got %d: %s", status, w.Code, w.Body.String())
		}
	}
	join(invitation.Ticket, "", 401)
	identity, _ := a.tokens.IssueVisitorIdentity(tenant, inbox, "new-buyer", "买家")
	join(invitation.Ticket, identity, 201)
	join(invitation.Ticket, identity, 200)
	otherIdentity, _ := a.tokens.IssueVisitorIdentity(uuid.New(), inbox, "bad", "bad")
	join(invitation.Ticket, otherIdentity, 401)
	for start := 0; start < 1050; start += 50 {
		members := []map[string]any{}
		for i := start; i < start+50; i++ {
			members = append(members, map[string]any{"externalId": fmt.Sprintf("buyer-%d", i)})
		}
		open(a.openGroupAddMembers, map[string]any{"actorExternalId": "owner", "members": members}, 200)
	}
	var count int
	if db.QueryRow(ctx, `select count(*) from chat_group_member where group_id=$1`, gid).Scan(&count) != nil || count != 1054 {
		t.Fatalf("expected 1054 members, got %d", count)
	}
	open(a.openGroupPolicy, map[string]any{"actorExternalId": "owner", "maxMembers": 1000}, 409)
	open(a.openGroupPolicy, map[string]any{"actorExternalId": "owner", "maxMembers": 1054}, 200)
	full := open(a.openGroupAddMembers, map[string]any{"actorExternalId": "owner", "members": []map[string]any{{"externalId": "overflow"}}}, 200)
	var batch struct {
		Added   []any `json:"added"`
		Skipped []any `json:"skipped"`
	}
	json.Unmarshal(full.Body.Bytes(), &batch)
	if len(batch.Added) != 0 || len(batch.Skipped) != 1 {
		t.Fatal("capacity not enforced")
	}
	overflow, _ := a.tokens.IssueVisitorIdentity(tenant, inbox, "invite-overflow", "买家")
	join(invitation.Ticket, overflow, 409)
	// 满员时原成员仍能幂等加入，不占额外人数。
	join(invitation.Ticket, identity, 200)
	call(a.groupDetail, "buyer", nil, 200)
	call(a.groupManager, "buyer", map[string]any{"kind": "widget", "id": principal("buyer").VisitorID, "isManager": true}, 403)
	call(a.groupManager, "owner", map[string]any{"kind": "widget", "id": principal("staff").VisitorID, "isManager": true}, 200)
	call(a.groupInvite, "staff", nil, 200)
	// 两个买家同时争抢最后一个名额，群锁确保不会超额。
	invitation2 := open(a.openGroupInvite, map[string]any{"actorExternalId": "owner"}, 200)
	json.Unmarshal(invitation2.Body.Bytes(), &invitation)
	open(a.openGroupPolicy, map[string]any{"actorExternalId": "owner", "maxMembers": 1055}, 200)
	statuses := make(chan int, 2)
	for i := 0; i < 2; i++ {
		go func(i int) {
			ticket, _ := a.tokens.IssueVisitorIdentity(tenant, inbox, fmt.Sprintf("last-slot-%d", i), "买家")
			raw, _ := json.Marshal(map[string]any{"identityToken": ticket})
			r := httptest.NewRequest("POST", "/", strings.NewReader(string(raw)))
			r.SetPathValue("ticket", invitation.Ticket)
			w := httptest.NewRecorder()
			a.groupJoin(w, r)
			statuses <- w.Code
		}(i)
	}
	first, second := <-statuses, <-statuses
	if !(first == 201 && second == 409 || first == 409 && second == 201) {
		t.Fatalf("last slot statuses: %d %d", first, second)
	}
	open(a.openGroupInvite, map[string]any{"actorExternalId": "owner"}, 200)
	join(invitation.Ticket, identity, 404)
}
