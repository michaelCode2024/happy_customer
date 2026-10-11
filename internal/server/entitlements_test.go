package server

import "testing"

func TestPlanNavigationFeatures(t *testing.T) {
	for _, tc := range []struct {
		plan               string
		groups, automation bool
	}{
		{"TRIAL", false, false}, {"STARTER", true, false}, {"GROWTH", true, true}, {"ENTERPRISE", true, true}, {"UNKNOWN", false, false},
	} {
		f := planFeatures(tc.plan)
		if f["groups"] != tc.groups || f["integrations"] != tc.groups || f["automation"] != tc.automation || f["channels"] != tc.automation || f["ai"] != tc.automation {
			t.Errorf("%s: %v", tc.plan, f)
		}
	}
}
func TestProtectedPlanRoutes(t *testing.T) {
	for path, want := range map[string]string{
		"/api/v1/admin/inboxes/id/routing": "",
		"/api/v1/groups":                   "groups", "/api/v1/groups/id/rooms": "groups",
		"/api/v1/admin/inboxes/id/automation":    "automation",
		"/api/v1/admin/inboxes/id/conversations": "channels",
		"/api/v1/admin/webhooks":                 "integrations",
		"/api/v1/console/assist/stream":          "ai",
		"/api/v1/console/entitlements":           "", "/api/v1/admin/agents": "",
	} {
		if got := routeFeature(path); got != want {
			t.Errorf("%s: %s != %s", path, got, want)
		}
	}
}
