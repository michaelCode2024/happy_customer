package server

import (
	"github.com/tongyu/tongyu/internal/auth"
	"net/http/httptest"
	"testing"
)

// 无数据库依赖：普通坐席在写入前即被拒绝；主管走建号逻辑（空请求体在解码处失败，不再是平台专属 403）。
func TestAgentCannotCreateAccounts(t *testing.T) {
	a := &API{}
	w := httptest.NewRecorder()
	a.adminCreateAgent(w, httptest.NewRequest("POST", "/api/v1/admin/agents", nil), auth.Principal{Kind: auth.KindAgent, Role: auth.RoleAgent})
	if w.Code != 403 {
		t.Fatalf("agent want forbidden, got %d", w.Code)
	}
}

func TestSupervisorCreateNotPlatformLocked(t *testing.T) {
	a := &API{}
	w := httptest.NewRecorder()
	a.adminCreateAgent(w, httptest.NewRequest("POST", "/api/v1/admin/agents", nil), auth.Principal{Kind: auth.KindAgent, Role: auth.RoleSupervisor})
	if w.Code == 403 {
		t.Fatalf("supervisor must not get platform-only lock; got %d body=%s", w.Code, w.Body.String())
	}
}
