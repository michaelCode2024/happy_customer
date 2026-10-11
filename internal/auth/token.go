package auth

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Principal kinds. A single Bearer token format is used by the widget, the
// agent console and the platform admin API so every client implements one
// authentication path.
const (
	KindWidget   = "widget"
	KindAgent    = "agent"
	KindPlatform = "platform"
	KindIdentity = "visitor_identity"
)

// Roles are evaluated by the permission helpers in this package.
const (
	RoleOwner      = "OWNER"
	RoleAdmin      = "ADMIN"
	RoleAgent      = "AGENT"
	RoleSupervisor = "SUPERVISOR"
)

// 鉴权失败文案可能透传到客户端，保持中文。
var ErrUnauthorized = errors.New("登录已失效或令牌无效，请重新登录")

type Principal struct {
	PlatformAdminID uuid.UUID `json:"pa,omitempty"`
	Kind            string    `json:"k"`
	TenantID        uuid.UUID `json:"t"`
	InboxID         uuid.UUID `json:"i,omitempty"`
	VisitorID       uuid.UUID `json:"v,omitempty"`
	AgentID         uuid.UUID `json:"a,omitempty"`
	Email           string    `json:"e,omitempty"`
	Name            string    `json:"n,omitempty"`
	Role            string    `json:"r,omitempty"`
	ExternalID      string    `json:"externalId,omitempty"`
	SessionID       uuid.UUID `json:"s,omitempty"`
	IssuedAt        int64     `json:"iat"`
	ExpiresAt       int64     `json:"exp"`
}

// TokenService issues and verifies the signed, stateless tokens used by every
// RelayDesk client. Session revocation is handled separately through the
// agent_session table, which is checked on logout and password change.
type TokenService struct {
	key        []byte
	widgetTTL  time.Duration
	agentTTL   time.Duration
	platformID string
}

func NewTokenService(key string, widgetTTL, agentTTL time.Duration) *TokenService {
	return &TokenService{key: []byte(key), widgetTTL: widgetTTL, agentTTL: agentTTL}
}

func (s *TokenService) IssueWidget(tenantID, inboxID, visitorID uuid.UUID) (string, error) {
	return s.issue(Principal{Kind: KindWidget, TenantID: tenantID, InboxID: inboxID, VisitorID: visitorID}, s.widgetTTL)
}

// 客户后端证明登录用户身份；票据不能当聊天令牌使用，且只绑定一个企业入口。
func (s *TokenService) IssueVisitorIdentity(tenantID, inboxID uuid.UUID, externalID, name string) (string, error) {
	return s.issue(Principal{Kind: KindIdentity, TenantID: tenantID, InboxID: inboxID, ExternalID: externalID, Name: name}, 5*time.Minute)
}

func (s *TokenService) IssueAgent(p Principal) (string, error) {
	p.Kind = KindAgent
	return s.issue(p, s.agentTTL)
}

func (s *TokenService) IssuePlatform(label string) (string, error) {
	p := Principal{Kind: KindPlatform, Name: label}
	return s.issue(p, 24*time.Hour)
}

func (s *TokenService) IssuePlatformSession(adminID, sessionID uuid.UUID, label string) (string, error) {
	return s.issue(Principal{Kind: KindPlatform, PlatformAdminID: adminID, SessionID: sessionID, Name: label}, 8*time.Hour)
}

func (s *TokenService) issue(p Principal, ttl time.Duration) (string, error) {
	now := time.Now()
	p.IssuedAt = now.Unix()
	p.ExpiresAt = now.Add(ttl).Unix()
	payload, err := json.Marshal(p)
	if err != nil {
		return "", err
	}
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	return encoded + "." + base64.RawURLEncoding.EncodeToString(s.sign(encoded)), nil
}

func (s *TokenService) Verify(token string) (Principal, error) {
	token = strings.TrimSpace(strings.TrimPrefix(token, "Bearer "))
	if token == "" {
		return Principal{}, ErrUnauthorized
	}
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return Principal{}, ErrUnauthorized
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || !hmac.Equal(signature, s.sign(parts[0])) {
		return Principal{}, ErrUnauthorized
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return Principal{}, ErrUnauthorized
	}
	var principal Principal
	if json.Unmarshal(payload, &principal) != nil || principal.ExpiresAt <= time.Now().Unix() {
		return Principal{}, ErrUnauthorized
	}
	return principal, nil
}

func (s *TokenService) sign(value string) []byte {
	mac := hmac.New(sha256.New, s.key)
	mac.Write([]byte(value))
	return mac.Sum(nil)
}

type principalKey struct{}

func WithPrincipal(ctx context.Context, p Principal) context.Context {
	return context.WithValue(ctx, principalKey{}, p)
}

func PrincipalFrom(ctx context.Context) (Principal, bool) {
	p, ok := ctx.Value(principalKey{}).(Principal)
	return p, ok
}

// CanManageTenant reports whether the role may change tenant settings, agents,
// inboxes, knowledge and API keys.
func CanManageTenant(role string) bool {
	return role == RoleOwner || role == RoleAdmin
}

// CanViewReports separates supervisors and above from ordinary agents.
func CanViewReports(role string) bool {
	return role == RoleOwner || role == RoleAdmin || role == RoleSupervisor
}

// ValidRole guards the agent admin API: roles arrive from HTTP requests, so the
// value is checked here rather than trusted. It stays in this package next to the
// role constants so a new role cannot be added in one place and forgotten here.
func ValidRole(role string) bool {
	switch role {
	case RoleOwner, RoleAdmin, RoleSupervisor, RoleAgent:
		return true
	default:
		return false
	}
}
