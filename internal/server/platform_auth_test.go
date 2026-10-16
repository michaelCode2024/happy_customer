package server

import (
	"context"
	"encoding/json"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/tongyu/tongyu/internal/auth"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

// 使用独立数据库账号，验证密码、HTTP 会话和实时连接共同采用的撤销边界。
func TestPlatformPasswordSessions(t *testing.T) {
	dsn := os.Getenv("TONGYU_TEST_DATABASE")
	if dsn == "" {
		t.Skip("TONGYU_TEST_DATABASE is not set")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	id := uuid.New()
	email := "auth-test-" + id.String() + "@tongyu.local"
	hash, err := auth.HashPassword("Before@2026")
	if err != nil {
		t.Fatal(err)
	}
	_, err = pool.Exec(ctx, `insert into platform_admin(id,email,display_name,password_hash) values($1,$2,'回归测试',$3)`, id, email, hash)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Exec(ctx, `delete from platform_admin where id=$1`, id)
	a := &API{db: pool, tokens: auth.NewTokenService("test-secret-at-least-thirty-two-characters", time.Hour, time.Hour)}
	call := func(handler http.HandlerFunc, body, token string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "/", strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		handler(w, r)
		return w
	}
	login := func(password string) string {
		body, _ := json.Marshal(map[string]string{"email": email, "password": password})
		w := call(a.platformLogin, string(body), "")
		if w.Code != 200 {
			t.Fatalf("login %d: %s", w.Code, w.Body.String())
		}
		var out struct{ Token string }
		if json.Unmarshal(w.Body.Bytes(), &out) != nil || out.Token == "" {
			t.Fatal("missing token")
		}
		return out.Token
	}
	wrong, _ := json.Marshal(map[string]string{"email": email, "password": "wrong"})
	if w := call(a.platformLogin, string(wrong), ""); w.Code != 401 {
		t.Fatal("wrong password accepted")
	}
	first, second := login("Before@2026"), login("Before@2026")
	if w := call(a.requirePlatform(a.platformMe), "", first); w.Code != 200 {
		t.Fatal("valid session rejected")
	}
	if w := call(a.requirePlatform(a.platformPassword), `{"currentPassword":"wrong","newPassword":"After@2026"}`, first); w.Code != 400 {
		t.Fatal("wrong current password accepted")
	}
	if w := call(a.requirePlatform(a.platformPassword), `{"currentPassword":"Before@2026","newPassword":"After@2026"}`, first); w.Code != 200 {
		t.Fatalf("password update: %s", w.Body.String())
	}
	for _, token := range []string{first, second} {
		if w := call(a.requirePlatform(a.platformMe), "", token); w.Code != 401 {
			t.Fatal("password change did not revoke all sessions")
		}
	}
	old, _ := json.Marshal(map[string]string{"email": email, "password": "Before@2026"})
	if w := call(a.platformLogin, string(old), ""); w.Code != 401 {
		t.Fatal("old password accepted")
	}
	next := login("After@2026")
	if w := call(a.requirePlatform(a.platformLogout), "", next); w.Code != 200 {
		t.Fatal("logout failed")
	}
	if w := call(a.requirePlatform(a.platformMe), "", next); w.Code != 401 {
		t.Fatal("logout did not revoke session")
	}
	legacy, _ := a.tokens.IssuePlatform("legacy")
	if w := call(a.requirePlatform(a.platformMe), "", legacy); w.Code != 401 {
		t.Fatal("legacy platform token accepted")
	}
	token := login("After@2026")
	pool.Exec(ctx, `update platform_admin set status='DISABLED' where id=$1`, id)
	if w := call(a.requirePlatform(a.platformMe), "", token); w.Code != 401 {
		t.Fatal("disabled account session accepted")
	}
}
