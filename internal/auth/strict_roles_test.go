package auth

import "testing"

func TestStrictTenantRoles(t *testing.T) {
	for _, role := range []string{"OWNER", "ADMIN", "SUPER_ADMIN", "", "supervisor"} {
		if ValidRole(role) || CanManageTenant(role) || CanViewReports(role) {
			t.Fatalf("invalid tenant role accepted: %q", role)
		}
	}
	if !ValidRole(RoleSupervisor) || !CanManageTenant(RoleSupervisor) || !CanViewReports(RoleSupervisor) {
		t.Fatal("supervisor permissions missing")
	}
	if !ValidRole(RoleAgent) || CanManageTenant(RoleAgent) || CanViewReports(RoleAgent) {
		t.Fatal("agent permissions incorrect")
	}
}
