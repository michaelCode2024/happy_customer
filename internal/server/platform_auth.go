package server

import (
	"github.com/google/uuid"
	"github.com/relaydesk/relaydesk/internal/auth"
	"net/http"
	"strings"
	"time"
)

func (a *API) platformLogin(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if !decode(w, r, &in) {
		return
	}
	var id uuid.UUID
	var email, name, hash, status string
	err := a.db.QueryRow(r.Context(), `select id,email,display_name,password_hash,status from platform_admin where email=$1`, strings.ToLower(strings.TrimSpace(in.Email))).Scan(&id, &email, &name, &hash, &status)
	if err != nil || status != "ACTIVE" || !auth.VerifyPassword(hash, in.Password) {
		failCode(w, 401, "LOGIN_FAILED", "账号或密码错误")
		return
	}
	sid := uuid.New()
	token, err := a.tokens.IssuePlatformSession(id, sid, name)
	if err != nil {
		fail(w, 500, "登录失败")
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "登录失败")
		return
	}
	defer tx.Rollback(r.Context())
	_, err = tx.Exec(r.Context(), `insert into platform_session(id,admin_id,expires_at) values($1,$2,$3)`, sid, id, time.Now().Add(8*time.Hour))
	if err == nil {
		_, err = tx.Exec(r.Context(), `update platform_admin set last_login_at=now() where id=$1`, id)
	}
	if err != nil || tx.Commit(r.Context()) != nil {
		fail(w, 500, "登录失败")
		return
	}
	respond(w, 200, map[string]any{"token": token, "expiresIn": 28800, "admin": map[string]any{"id": id, "email": email, "displayName": name}})
}

func (a *API) platformMe(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var email, name, role string
	if err := a.db.QueryRow(r.Context(), `select email,display_name,role from platform_admin where id=$1`, p.PlatformAdminID).Scan(&email, &name, &role); err != nil {
		fail(w, 500, "读取账号失败")
		return
	}
	respond(w, 200, map[string]any{"id": p.PlatformAdminID, "email": email, "displayName": name, "role": role})
}

func (a *API) platformLogout(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	if _, err := a.db.Exec(r.Context(), `update platform_session set revoked_at=now() where id=$1 and admin_id=$2`, p.SessionID, p.PlatformAdminID); err != nil {
		fail(w, 500, "退出失败")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) platformPassword(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		CurrentPassword string `json:"currentPassword"`
		NewPassword     string `json:"newPassword"`
	}
	if !decode(w, r, &in) {
		return
	}
	if len(in.NewPassword) < 8 {
		fail(w, 400, "新密码至少需要 8 个字符")
		return
	}
	var old string
	if err := a.db.QueryRow(r.Context(), `select password_hash from platform_admin where id=$1`, p.PlatformAdminID).Scan(&old); err != nil {
		fail(w, 500, "读取账号失败")
		return
	}
	if !auth.VerifyPassword(old, in.CurrentPassword) {
		failCode(w, 400, "PASSWORD_INVALID", "当前密码错误")
		return
	}
	hash, err := auth.HashPassword(in.NewPassword)
	if err != nil {
		fail(w, 500, "修改密码失败")
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "修改密码失败")
		return
	}
	defer tx.Rollback(r.Context())
	_, err = tx.Exec(r.Context(), `update platform_admin set password_hash=$1,updated_at=now() where id=$2`, hash, p.PlatformAdminID)
	if err == nil {
		_, err = tx.Exec(r.Context(), `update platform_session set revoked_at=now() where admin_id=$1 and revoked_at is null`, p.PlatformAdminID)
	}
	if err != nil || tx.Commit(r.Context()) != nil {
		fail(w, 500, "修改密码失败")
		return
	}
	respond(w, 200, map[string]any{"status": "OK", "message": "密码已更新，请重新登录"})
}
