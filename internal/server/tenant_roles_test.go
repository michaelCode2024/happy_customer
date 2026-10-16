package server

import (
	"context"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/tongyu/tongyu/internal/auth"
	"github.com/tongyu/tongyu/internal/platform/database"
)

func TestTenantRoleMigrationAndLastSupervisor(t *testing.T) {
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
	// 在回滚事务中复原旧约束和账号，真实执行迁移SQL，避免改动其他测试数据。
	tx, err := db.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := tx.Exec(ctx, q, args...); err != nil {
			t.Fatal(err)
		}
	}
	tenant, owner, admin := uuid.New(), uuid.New(), uuid.New()
	exec(`alter table agent drop constraint agent_role_check`)
	exec(`alter table agent add constraint agent_role_check check(role in ('OWNER','ADMIN','SUPERVISOR','AGENT'))`)
	exec(`insert into tenant(id,name,slug,status) values($1,'role migration',$2,'ACTIVE')`, tenant, tenant.String())
	exec(`insert into agent(id,tenant_id,email,display_name,password_hash,role,status) values($1,$3,'legacy-owner','owner','test','OWNER','ACTIVE'),($2,$3,'legacy-admin','admin','test','ADMIN','ACTIVE')`, owner, admin, tenant)
	exec(`insert into agent_session(id,agent_id,token_hash,expires_at) values($1,$2,$3,now()+interval '1 hour')`, uuid.New(), owner, []byte(uuid.NewString()))
	sql, err := os.ReadFile("../platform/database/migrations/017_simplify_tenant_roles.sql")
	if err != nil {
		t.Fatal(err)
	}
	exec(string(sql))
	var count int
	if err = tx.QueryRow(ctx, `select count(*) from agent where tenant_id=$1 and role='SUPERVISOR'`, tenant).Scan(&count); err != nil || count != 2 {
		t.Fatalf("migration supervisors=%d err=%v", count, err)
	}
	if err = tx.QueryRow(ctx, `select count(*) from agent_session where agent_id=$1`, owner).Scan(&count); err != nil || count != 0 {
		t.Fatalf("legacy session retained=%d err=%v", count, err)
	}
	tx.Rollback(ctx)
	// 最后一名主管不能通过修改角色或停用失去管理权限。
	tenant, owner = uuid.New(), uuid.New()
	if _, err = db.Exec(ctx, `insert into tenant(id,name,slug,status) values($1,'last supervisor',$2,'ACTIVE')`, tenant, tenant.String()); err != nil {
		t.Fatal(err)
	}
	defer func() {
		db.Exec(ctx, `delete from agent where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from tenant_subscription where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from tenant where id=$1`, tenant)
	}()
	if _, err = db.Exec(ctx, `insert into tenant_subscription(tenant_id,plan,status) values($1,'GROWTH','ACTIVE')`, tenant); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(ctx, `insert into agent(id,tenant_id,email,display_name,password_hash,role,status) values($1,$2,'supervisor','主管','test','SUPERVISOR','ACTIVE')`, owner, tenant); err != nil {
		t.Fatal(err)
	}
	a := &API{db: db, authn: auth.NewAuthenticator(db), tokens: auth.NewTokenService("role-test", time.Hour, time.Hour)}
	ordinary := uuid.New()
	if _, err = db.Exec(ctx, `insert into agent(id,tenant_id,email,display_name,password_hash,role,status) values($1,$2,'ordinary','坐席','test','AGENT','ACTIVE')`, ordinary, tenant); err != nil {
		t.Fatal(err)
	}
	for _, item := range []struct {
		id   uuid.UUID
		want int
	}{{owner, 200}, {ordinary, 403}} {
		// 令牌内的旧OWNER声明不能覆盖数据库的坐席身份。
		token, err := a.tokens.IssueAgent(auth.Principal{Kind: auth.KindAgent, TenantID: tenant, AgentID: item.id, Role: "OWNER"})
		if err != nil {
			t.Fatal(err)
		}
		r := httptest.NewRequest("GET", "/api/v1/admin/tenant", nil)
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		a.requireRole([]string{auth.RoleSupervisor}, a.adminTenant)(w, r)
		if w.Code != item.want {
			t.Fatalf("admin route want=%d got=%d %s", item.want, w.Code, w.Body.String())
		}
	}
	p := auth.Principal{TenantID: tenant, Kind: auth.KindAgent, Role: auth.RoleSupervisor, AgentID: uuid.New()}
	for _, body := range []string{`{"role":"AGENT"}`, `{"status":"DISABLED"}`} {
		r := httptest.NewRequest("PATCH", "/", strings.NewReader(body))
		r.SetPathValue("id", owner.String())
		w := httptest.NewRecorder()
		a.adminUpdateAgent(w, r, p)
		if w.Code != 409 {
			t.Fatalf("last supervisor %s: %d %s", body, w.Code, w.Body.String())
		}
	}
}
