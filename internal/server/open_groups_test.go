package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/platform/database"
	"github.com/relaydesk/relaydesk/internal/realtime"
)

func TestOpenGroupMembersByExternalIDAndIdentityJoin(t *testing.T) {
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

	tenant, inbox, owner := uuid.New(), uuid.New(), uuid.New()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, e := db.Exec(ctx, q, args...); e != nil {
			t.Fatal(e)
		}
	}
	exec(`insert into tenant(id,name,slug,status) values($1,'open groups',$2,'ACTIVE')`, tenant, tenant.String())
	exec(`insert into tenant_subscription(tenant_id,plan,status) values($1,'ENTERPRISE','ACTIVE')
		on conflict (tenant_id) do update set plan='ENTERPRISE', status='ACTIVE'`, tenant)
	exec(`insert into inbox(id,tenant_id,name,public_key,status) values($1,$2,'inbox',$3,'ACTIVE')`, inbox, tenant, inbox.String())
	exec(`insert into agent(id,tenant_id,email,display_name,password_hash,role,status) values($1,$2,$3,'owner','x','OWNER','ACTIVE')`, owner, tenant, owner.String())
	exec(`insert into agent_inbox(agent_id,inbox_id) values($1,$2)`, owner, inbox)
	defer func() {
		db.Exec(ctx, `delete from chat_group_invite where group_id in(select id from chat_group where tenant_id=$1)`, tenant)
		db.Exec(ctx, `delete from chat_group_member where group_id in(select id from chat_group where tenant_id=$1)`, tenant)
		db.Exec(ctx, `delete from chat_group where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from visitor where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from agent_inbox where inbox_id=$1`, inbox)
		db.Exec(ctx, `delete from agent where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from inbox where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from tenant_subscription where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from tenant where id=$1`, tenant)
	}()

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	hub := realtime.NewHub(logger)
	a := &API{db: db, bus: realtime.NewBus(db, hub, logger), tokens: auth.NewTokenService("test-open-group", time.Hour, time.Hour)}
	principal := apiKeyPrincipal{TenantID: tenant, Name: "test-key", Scopes: []string{"write"}}
	agent := auth.Principal{Kind: auth.KindAgent, TenantID: tenant, AgentID: owner}

	createBody, _ := json.Marshal(map[string]any{"name": "VIP 客户群", "kind": "SERVICE", "inboxId": inbox.String()})
	createReq := httptest.NewRequest("POST", "/", strings.NewReader(string(createBody)))
	createRes := httptest.NewRecorder()
	a.groupCreate(createRes, createReq, agent)
	if createRes.Code != 201 {
		t.Fatalf("create service group %d %s", createRes.Code, createRes.Body.String())
	}
	var created struct {
		ID uuid.UUID `json:"id"`
	}
	json.Unmarshal(createRes.Body.Bytes(), &created)

	addBody, _ := json.Marshal(map[string]any{
		"members": []map[string]any{
			{"externalId": "user-1001", "displayName": "张三"},
			{"externalId": "user-1001", "displayName": "重复"},
			{"externalId": "", "displayName": "空"},
		},
	})
	addReq := httptest.NewRequest("POST", "/", strings.NewReader(string(addBody)))
	addReq.SetPathValue("id", created.ID.String())
	addRes := httptest.NewRecorder()
	a.openGroupAddMembers(addRes, addReq, principal)
	if addRes.Code != 200 {
		t.Fatalf("open add members %d %s", addRes.Code, addRes.Body.String())
	}
	var addResult struct {
		Added          []map[string]any `json:"added"`
		AlreadyMembers []map[string]any `json:"alreadyMembers"`
		Skipped        []map[string]any `json:"skipped"`
	}
	json.Unmarshal(addRes.Body.Bytes(), &addResult)
	if len(addResult.Added) != 1 || addResult.Added[0]["externalId"] != "user-1001" {
		t.Fatalf("added %#v", addResult.Added)
	}
	if len(addResult.Skipped) < 2 {
		t.Fatalf("skipped %#v", addResult.Skipped)
	}

	// 再次加人应落入 alreadyMembers，并与一对一共用 visitor。
	againReq := httptest.NewRequest("POST", "/", strings.NewReader(string(addBody)))
	againReq.SetPathValue("id", created.ID.String())
	againRes := httptest.NewRecorder()
	a.openGroupAddMembers(againRes, againReq, principal)
	json.Unmarshal(againRes.Body.Bytes(), &addResult)
	if len(addResult.Added) != 0 || len(addResult.AlreadyMembers) != 1 {
		t.Fatalf("idempotent add %#v %#v", addResult.Added, addResult.AlreadyMembers)
	}
	visitorID, err := uuid.Parse(fmt.Sprint(addResult.AlreadyMembers[0]["visitorId"]))
	if err != nil {
		t.Fatalf("visitor id %#v", addResult.AlreadyMembers[0]["visitorId"])
	}

	tokenRes := httptest.NewRecorder()
	tokenReq := httptest.NewRequest("POST", "/", strings.NewReader(`{"externalId":"user-1001"}`))
	tokenReq.SetPathValue("id", created.ID.String())
	a.openGroupMemberToken(tokenRes, tokenReq, principal)
	if tokenRes.Code != 200 {
		t.Fatalf("member token %d %s", tokenRes.Code, tokenRes.Body.String())
	}
	var memberToken struct {
		Token     string    `json:"token"`
		VisitorID uuid.UUID `json:"visitorId"`
	}
	json.Unmarshal(tokenRes.Body.Bytes(), &memberToken)
	if memberToken.VisitorID != visitorID || memberToken.Token == "" {
		t.Fatalf("member token payload %#v", memberToken)
	}

	identity, err := a.tokens.IssueVisitorIdentity(tenant, inbox, "user-1001", "张三")
	if err != nil {
		t.Fatal(err)
	}
	sessionBody, _ := json.Marshal(map[string]any{"identityToken": identity, "groupId": created.ID.String()})
	sessionReq := httptest.NewRequest("POST", "/", strings.NewReader(string(sessionBody)))
	sessionRes := httptest.NewRecorder()
	a.groupSession(sessionRes, sessionReq)
	if sessionRes.Code != 200 {
		t.Fatalf("group session %d %s", sessionRes.Code, sessionRes.Body.String())
	}
	var session struct {
		VisitorID uuid.UUID `json:"visitorId"`
	}
	json.Unmarshal(sessionRes.Body.Bytes(), &session)
	if session.VisitorID != visitorID {
		t.Fatalf("session visitor %s want %s", session.VisitorID, visitorID)
	}

	// 邀请链 + identityToken：第二次加入返回 200 且仍是同一 visitor。
	inviteReq := httptest.NewRequest("POST", "/", nil)
	inviteReq.SetPathValue("id", created.ID.String())
	inviteRes := httptest.NewRecorder()
	a.groupInvite(inviteRes, inviteReq, agent)
	var link struct {
		URL string `json:"url"`
	}
	json.Unmarshal(inviteRes.Body.Bytes(), &link)
	ticket := strings.TrimPrefix(link.URL, "/groups.html?invite=")
	joinBody, _ := json.Marshal(map[string]any{"identityToken": identity})
	joinReq := httptest.NewRequest("POST", "/", strings.NewReader(string(joinBody)))
	joinReq.SetPathValue("ticket", ticket)
	joinRes := httptest.NewRecorder()
	a.groupJoin(joinRes, joinReq)
	if joinRes.Code != 200 {
		t.Fatalf("identity re-join %d %s", joinRes.Code, joinRes.Body.String())
	}
	var joined struct {
		VisitorID uuid.UUID `json:"visitorId"`
	}
	json.Unmarshal(joinRes.Body.Bytes(), &joined)
	if joined.VisitorID != visitorID {
		t.Fatalf("join visitor %s want %s", joined.VisitorID, visitorID)
	}

	// 未入群的 externalId 不能拿 token。
	deny := httptest.NewRecorder()
	denyReq := httptest.NewRequest("POST", "/", strings.NewReader(`{"externalId":"nobody"}`))
	denyReq.SetPathValue("id", created.ID.String())
	a.openGroupMemberToken(deny, denyReq, principal)
	if deny.Code != 404 {
		t.Fatalf("unknown member token %d", deny.Code)
	}
}

func TestGroupJoinIdentityCreatesSharedVisitor(t *testing.T) {
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
	tenant, inbox, owner := uuid.New(), uuid.New(), uuid.New()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(ctx, q, args...); err != nil {
			t.Fatal(err)
		}
	}
	exec(`insert into tenant(id,name,slug,status) values($1,'join identity',$2,'ACTIVE')`, tenant, tenant.String())
	exec(`insert into tenant_subscription(tenant_id,plan,status) values($1,'ENTERPRISE','ACTIVE')
		on conflict (tenant_id) do update set plan='ENTERPRISE', status='ACTIVE'`, tenant)
	exec(`insert into inbox(id,tenant_id,name,public_key,status) values($1,$2,'inbox',$3,'ACTIVE')`, inbox, tenant, inbox.String())
	exec(`insert into agent(id,tenant_id,email,display_name,password_hash,role,status) values($1,$2,$3,'owner','x','OWNER','ACTIVE')`, owner, tenant, owner.String())
	exec(`insert into agent_inbox(agent_id,inbox_id) values($1,$2)`, owner, inbox)
	defer func() {
		db.Exec(ctx, `delete from chat_group_invite where group_id in(select id from chat_group where tenant_id=$1)`, tenant)
		db.Exec(ctx, `delete from chat_group_member where group_id in(select id from chat_group where tenant_id=$1)`, tenant)
		db.Exec(ctx, `delete from chat_group where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from visitor where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from agent_inbox where inbox_id=$1`, inbox)
		db.Exec(ctx, `delete from agent where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from inbox where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from tenant_subscription where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from tenant where id=$1`, tenant)
	}()

	a := &API{db: db, bus: realtime.NewBus(db, realtime.NewHub(slog.New(slog.NewTextHandler(io.Discard, nil))), slog.New(slog.NewTextHandler(io.Discard, nil))), tokens: auth.NewTokenService("join-id", time.Hour, time.Hour)}
	agent := auth.Principal{Kind: auth.KindAgent, TenantID: tenant, AgentID: owner}
	createReq := httptest.NewRequest("POST", "/", strings.NewReader(`{"name":"服务群","kind":"SERVICE","inboxId":"`+inbox.String()+`"}`))
	createRes := httptest.NewRecorder()
	a.groupCreate(createRes, createReq, agent)
	if createRes.Code != 201 {
		t.Fatalf("create %d %s", createRes.Code, createRes.Body.String())
	}
	var g struct {
		ID uuid.UUID `json:"id"`
	}
	json.Unmarshal(createRes.Body.Bytes(), &g)
	inviteRes := httptest.NewRecorder()
	inviteReq := httptest.NewRequest("POST", "/", nil)
	inviteReq.SetPathValue("id", g.ID.String())
	a.groupInvite(inviteRes, inviteReq, agent)
	var link struct {
		URL string `json:"url"`
	}
	json.Unmarshal(inviteRes.Body.Bytes(), &link)
	ticket := strings.TrimPrefix(link.URL, "/groups.html?invite=")

	identity, _ := a.tokens.IssueVisitorIdentity(tenant, inbox, "ext-join-1", "李四")
	joinReq := httptest.NewRequest("POST", "/", strings.NewReader(`{"identityToken":"`+identity+`"}`))
	joinReq.SetPathValue("ticket", ticket)
	joinRes := httptest.NewRecorder()
	a.groupJoin(joinRes, joinReq)
	if joinRes.Code != http.StatusCreated {
		t.Fatalf("first identity join %d %s", joinRes.Code, joinRes.Body.String())
	}
	var first struct {
		VisitorID uuid.UUID `json:"visitorId"`
	}
	json.Unmarshal(joinRes.Body.Bytes(), &first)

	var external string
	if err := db.QueryRow(ctx, `select external_id from visitor where id=$1`, first.VisitorID).Scan(&external); err != nil || external != "ext-join-1" {
		t.Fatalf("visitor external %q err %v", external, err)
	}
}
