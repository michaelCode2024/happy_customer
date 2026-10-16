package server

import (
	"context"
	"encoding/json"
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
	"github.com/tongyu/tongyu/internal/auth"
	"github.com/tongyu/tongyu/internal/platform/database"
	"github.com/tongyu/tongyu/internal/realtime"
)

func TestExternalGroupLifecycleWithoutAgentAccounts(t *testing.T) {
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
	tenant, inbox := uuid.New(), uuid.New()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(ctx, q, args...); err != nil {
			t.Fatal(err)
		}
	}
	exec(`insert into tenant(id,name,slug,status) values($1,'external group test',$2,'ACTIVE')`, tenant, tenant.String())
	exec(`insert into tenant_subscription(tenant_id,plan,status) values($1,'STARTER','ACTIVE')`, tenant)
	exec(`insert into inbox(id,tenant_id,name,public_key,status) values($1,$2,'external',$3,'ACTIVE')`, inbox, tenant, inbox.String())
	defer func() {
		for _, q := range []string{`delete from chat_group_member where group_id in(select id from chat_group where tenant_id=$1)`, `delete from chat_group where tenant_id=$1`, `delete from visitor where tenant_id=$1`, `delete from inbox where tenant_id=$1`, `delete from tenant_subscription where tenant_id=$1`, `delete from tenant where id=$1`} {
			db.Exec(ctx, q, tenant)
		}
	}()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	hub := realtime.NewHub(logger)
	a := &API{db: db, bus: realtime.NewBus(db, hub, logger), tokens: auth.NewTokenService("external-test", time.Hour, time.Hour)}
	p := apiKeyPrincipal{TenantID: tenant, Scopes: []string{"read", "write"}}
	call := func(fn func(http.ResponseWriter, *http.Request, apiKeyPrincipal), method, body, id, target, query string, status int) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequest(method, "/"+query, strings.NewReader(body))
		r.SetPathValue("id", id)
		r.SetPathValue("externalId", target)
		w := httptest.NewRecorder()
		fn(w, r, p)
		if w.Code != status {
			t.Fatalf("%s %s want %d got %d: %s", method, body, status, w.Code, w.Body.String())
		}
		return w
	}
	body := `{"inboxKey":"` + inbox.String() + `","externalGroupId":"order-123","name":"订单群","owner":{"externalId":"user-1","displayName":"群主"},"members":[{"externalId":"user-2","displayName":"成员"}]}`
	// 并发建群重试只能创建一个群，不能产生多份成员或半建成记录。
	parallel := strings.Replace(body, "order-123", "parallel-123", 1)
	responses := make(chan *httptest.ResponseRecorder, 4)
	for i := 0; i < 4; i++ {
		go func() {
			r := httptest.NewRequest("POST", "/", strings.NewReader(parallel))
			w := httptest.NewRecorder()
			a.openGroupCreate(w, r, p)
			responses <- w
		}()
	}
	createdCount := 0
	parallelID := ""
	for i := 0; i < 4; i++ {
		w := <-responses
		if w.Code == 201 {
			createdCount++
		} else if w.Code != 200 {
			t.Fatalf("parallel create: %d %s", w.Code, w.Body.String())
		}
		var item struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(w.Body.Bytes(), &item) != nil || item.ID == "" {
			t.Fatal(w.Body.String())
		}
		if parallelID != "" && parallelID != item.ID {
			t.Fatal("concurrent retry created different groups")
		}
		parallelID = item.ID
	}
	if createdCount != 1 {
		t.Fatalf("concurrent creates=%d", createdCount)
	}
	created := call(a.openGroupCreate, "POST", body, "", "", "", 201)
	var result struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(created.Body.Bytes(), &result) != nil || result.ID == "" {
		t.Fatal(created.Body.String())
	}
	gid := result.ID
	retry := call(a.openGroupCreate, "POST", body, "", "", "", 200)
	if !strings.Contains(retry.Body.String(), gid) {
		t.Fatal("retry created another group")
	}
	var agents, members int
	db.QueryRow(ctx, `select count(*) from agent where tenant_id=$1`, tenant).Scan(&agents)
	db.QueryRow(ctx, `select count(*) from chat_group_member where group_id=$1`, gid).Scan(&members)
	if agents != 0 || members != 2 {
		t.Fatalf("agents=%d members=%d", agents, members)
	}
	call(a.openGroupList, "GET", "", "", "", "?externalId=user-1", 200)
	detail := call(a.openGroupDetail, "GET", "", gid, "", "?externalId=user-1", 200)
	if !strings.Contains(detail.Body.String(), `"ownerExternalId":"user-1"`) {
		t.Fatal(detail.Body.String())
	}
	call(a.openGroupDetail, "GET", "", gid, "", "?externalId=outsider", 403)
	call(a.openGroupEdit, "PATCH", `{"actorExternalId":"user-2","name":"抢改"}`, gid, "", "", 403)
	call(a.openGroupAddMembers, "POST", `{"actorExternalId":"user-2","members":[{"externalId":"user-3"}]}`, gid, "", "", 403)
	call(a.openGroupAddMembers, "POST", `{"actorExternalId":"user-1","members":[{"externalId":"user-3"}]}`, gid, "", "", 200)
	call(a.openGroupTransfer, "PUT", `{"actorExternalId":"user-1","ownerExternalId":"outsider"}`, gid, "", "", 400)
	call(a.openGroupTransfer, "PUT", `{"actorExternalId":"user-1","ownerExternalId":"user-2"}`, gid, "", "", 200)
	call(a.openGroupDissolve, "POST", `{"actorExternalId":"user-1"}`, gid, "", "", 403)
	var oldOwner uuid.UUID
	if err := db.QueryRow(ctx, `select id from visitor where inbox_id=$1 and external_id='user-1'`, inbox).Scan(&oldOwner); err != nil {
		t.Fatal(err)
	}
	oldOwnerRequest := httptest.NewRequest("POST", "/", strings.NewReader(`{}`))
	oldOwnerRequest.SetPathValue("id", gid)
	oldOwnerResponse := httptest.NewRecorder()
	a.groupDissolve(oldOwnerResponse, oldOwnerRequest, auth.Principal{Kind: auth.KindWidget, TenantID: tenant, VisitorID: oldOwner})
	if oldOwnerResponse.Code != 403 {
		t.Fatalf("transferred owner retained direct token management: %d", oldOwnerResponse.Code)
	}
	call(a.openGroupRemove, "DELETE", "", gid, "user-2", "?actorExternalId=user-2", 409)
	call(a.openGroupEdit, "PATCH", `{"actorExternalId":"user-2","name":"新群名","announcement":"公告"}`, gid, "", "", 200)
	tokenResult := call(a.openGroupMemberToken, "POST", `{"externalId":"user-3"}`, gid, "", "", 200)
	var tok struct {
		Token string `json:"token"`
	}
	json.Unmarshal(tokenResult.Body.Bytes(), &tok)
	visitor, err := a.tokens.Verify(tok.Token)
	if err != nil {
		t.Fatal(err)
	}
	call(a.openGroupRemove, "DELETE", "", gid, "user-3", "?actorExternalId=user-2", 200)
	// 已签发的用户token不能绕过被移除后的成员检查。
	req := httptest.NewRequest("GET", "/", nil)
	req.SetPathValue("id", gid)
	res := httptest.NewRecorder()
	a.groupDetail(res, req, visitor)
	if res.Code != 404 {
		t.Fatalf("removed token retained access: %d", res.Code)
	}
	call(a.openGroupMemberToken, "POST", `{"externalId":"user-3"}`, gid, "", "", 404)
	old := p.TenantID
	p.TenantID = uuid.New()
	call(a.openGroupDetail, "GET", "", gid, "", "?externalId=user-2", 404)
	p.TenantID = old
	call(a.openGroupDissolve, "POST", `{"actorExternalId":"user-2"}`, gid, "", "", 200)
	call(a.openGroupDissolve, "POST", `{"actorExternalId":"user-2"}`, gid, "", "", 200)
	call(a.openGroupAddMembers, "POST", `{"actorExternalId":"user-2","members":[{"externalId":"user-4"}]}`, gid, "", "", 409)
	call(a.openGroupTransfer, "PUT", `{"actorExternalId":"user-2","ownerExternalId":"user-1"}`, gid, "", "", 409)
	call(a.openGroupMemberToken, "POST", `{"externalId":"user-2"}`, gid, "", "", 409)
	call(a.openGroupDetail, "GET", "", gid, "", "?externalId=user-2", 200)
}
