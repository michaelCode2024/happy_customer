package server

import (
	"context"
	"github.com/google/uuid"
	"github.com/tongyu/tongyu/internal/auth"
	"net/http"
	"strings"
)

// Navigation and route access share this server-owned catalog. Roles remain
// an independent restriction; buying a plan never grants an administrator role.
func planFeatures(plan string) map[string]bool {
	rank := map[string]int{"TRIAL": 0, "STARTER": 1, "GROWTH": 2, "ENTERPRISE": 3}[plan]
	return map[string]bool{"groups": rank >= 1, "integrations": rank >= 1, "automation": rank >= 2, "channels": rank >= 2, "ai": rank >= 2, "identity": rank >= 3}
}

func (a *API) entitlementFeatures(r *http.Request, p auth.Principal) (string, map[string]bool, error) {
	var plan string
	err := a.db.QueryRow(r.Context(), "select coalesce((select case when status='ACTIVE' and (plan<>'TRIAL' or trial_ends_at is null or trial_ends_at>now()) and (service_starts_at is null or service_starts_at<=now()) and (service_ends_at is null or service_ends_at>now()) then plan else 'INACTIVE' end from tenant_subscription where tenant_id=$1),'TRIAL')", p.TenantID).Scan(&plan)
	return plan, planFeatures(plan), err
}

func (a *API) consoleEntitlements(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	plan, features, err := a.entitlementFeatures(r, p)
	if err != nil {
		fail(w, 503, "暂时无法读取套餐权限")
		return
	}
	respond(w, 200, map[string]any{"plan": plan, "features": features})
}

func routeFeature(path string) string {
	if path == "/api/v1/open/visitor-identity" {
		return "identity"
	}
	// 开放群聊接口同时属于开放 API，套餐上以群聊能力为准。
	if strings.HasPrefix(path, "/api/v1/open/groups") {
		return "groups"
	}
	if strings.HasPrefix(path, "/api/v1/open/") {
		return "integrations"
	}
	if strings.HasPrefix(path, "/api/v1/groups") || strings.HasPrefix(path, "/api/v1/group-join") {
		return "groups"
	}
	if strings.Contains(path, "/automation") {
		return "automation"
	}
	if path == "/api/v1/console/knowledge/search" || strings.HasPrefix(path, "/api/v1/console/assist") || strings.HasPrefix(path, "/api/v1/console/ai/") || strings.HasSuffix(path, "/ai") {
		return "ai"
	}
	if strings.HasPrefix(path, "/api/v1/admin/webhooks") || strings.HasPrefix(path, "/api/v1/admin/api-keys") || strings.HasSuffix(path, "/snippet") {
		return "integrations"
	}
	if strings.HasPrefix(path, "/api/v1/admin/inboxes/") && strings.Contains(path, "/conversations") {
		return "channels"
	}
	return ""
}

func (a *API) allowPlanRoute(w http.ResponseWriter, r *http.Request, p auth.Principal) bool {
	feature := routeFeature(r.URL.Path)
	if feature == "" {
		return true
	}
	_, features, err := a.entitlementFeatures(r, p)
	if err != nil {
		fail(w, 503, "暂时无法读取套餐权限")
		return false
	}
	if !features[feature] {
		failCode(w, 403, "PLAN_FEATURE_REQUIRED", "当前套餐未包含此功能，请联系平台管理员调整套餐")
		return false
	}
	return true
}

func (a *API) tenantHasFeature(ctx context.Context, tenantID uuid.UUID, feature string) bool {
	var plan string
	if err := a.db.QueryRow(ctx, "select coalesce((select case when status='ACTIVE' and (plan<>'TRIAL' or trial_ends_at is null or trial_ends_at>now()) and (service_starts_at is null or service_starts_at<=now()) and (service_ends_at is null or service_ends_at>now()) then plan else 'INACTIVE' end from tenant_subscription where tenant_id=$1),'TRIAL')", tenantID).Scan(&plan); err != nil {
		return false
	}
	return planFeatures(plan)[feature]
}
