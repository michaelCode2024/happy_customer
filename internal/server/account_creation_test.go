package server

import (
	"github.com/tongyu/tongyu/internal/auth"
	"net/http/httptest"
	"testing"
)

// 无数据库依赖：企业各角色都应在读取请求、写入数据库之前被拒绝。
func TestTenantCannotCreateAccounts(t *testing.T) {
	for _, role := range []string{auth.RoleSupervisor, auth.RoleAgent} {
		t.Run(role, func(t *testing.T) {
			a := &API{}
			w := httptest.NewRecorder()
			a.adminCreateAgent(w, httptest.NewRequest("POST", "/api/v1/admin/agents", nil), auth.Principal{Kind: auth.KindAgent, Role: role})
			if w.Code != 403 {
				t.Fatalf("want forbidden, got %d", w.Code)
			}
		})
	}
}
