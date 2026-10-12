package auth

import (
	"github.com/google/uuid"
	"testing"
	"time"
)

func TestVisitorIdentityBoundToTenantInboxAndCustomer(t *testing.T) {
	service := NewTokenService("local-test-signing-key", time.Hour, time.Hour)
	tenant, inbox := uuid.New(), uuid.New()
	token, err := service.IssueVisitorIdentity(tenant, inbox, "customer-42", "测试客户")
	if err != nil {
		t.Fatal(err)
	}
	principal, err := service.Verify(token)
	if err != nil {
		t.Fatal(err)
	}
	if principal.Kind != KindIdentity || principal.Kind == KindWidget || principal.TenantID != tenant || principal.InboxID != inbox || principal.ExternalID != "customer-42" || principal.Name != "测试客户" {
		t.Fatalf("unexpected identity principal: %+v", principal)
	}
	if principal.ExpiresAt-principal.IssuedAt != 300 {
		t.Fatal("identity must expire after five minutes")
	}
	other := NewTokenService("another-signing-key", time.Hour, time.Hour)
	if _, err = other.Verify(token); err == nil {
		t.Fatal("different signing key accepted identity")
	}
}
