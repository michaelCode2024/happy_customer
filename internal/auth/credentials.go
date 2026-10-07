package auth

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/argon2"
)

const (
	argonMemory      = 64 * 1024
	argonIterations  = 3
	argonParallelism = 2
	argonSaltLength  = 16
	argonKeyLength   = 32
)

var ErrInvalidCredentials = errors.New("email or password is incorrect")

func init() {
	if argonMemory < 8*1024 {
		panic("argon2id memory cost is too low")
	}
}

// HashPassword produces an Argon2id hash in the PHC string format.
func HashPassword(password string) (string, error) {
	if len([]rune(password)) < 8 {
		return "", errors.New("密码至少需要 8 个字符")
	}
	salt := make([]byte, argonSaltLength)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(password), salt, argonIterations, argonMemory, argonParallelism, argonKeyLength)
	return fmt.Sprintf("argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s", argon2.Version, argonMemory, argonIterations,
		argonParallelism, base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key)), nil
}

// VerifyPassword performs a constant-time comparison against a PHC encoded hash.
func VerifyPassword(encoded, password string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 5 || parts[0] != "argon2id" {
		return false
	}
	var version int
	if _, err := fmt.Sscanf(parts[1], "v=%d", &version); err != nil || version != argon2.Version {
		return false
	}
	var memory, iterations uint32
	var parallelism uint8
	if _, err := fmt.Sscanf(parts[2], "m=%d,t=%d,p=%d", &memory, &iterations, &parallelism); err != nil {
		return false
	}
	if memory > 1024*1024 || iterations > 16 || parallelism > 16 {
		// Refuse hashes that would let a malicious row exhaust the server.
		return false
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[3])
	if err != nil {
		return false
	}
	expected, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil || len(expected) < 16 {
		return false
	}
	actual := argon2.IDKey([]byte(password), salt, iterations, memory, parallelism, uint32(len(expected)))
	return constantTimeEqual(expected, actual)
}

func constantTimeEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := range a {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}

// NewOpaqueToken returns a random secret plus the hash that is stored in the
// database. Plaintext is only ever returned to the client that just created it.
func NewOpaqueToken() (string, []byte, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", nil, err
	}
	token := base64.RawURLEncoding.EncodeToString(raw)
	return token, HashToken(token), nil
}

func NewAPIKey() (string, []byte, string, error) {
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return "", nil, "", err
	}
	token := "rdk_" + base64.RawURLEncoding.EncodeToString(raw)
	prefix := token
	if len(prefix) > 12 {
		prefix = prefix[:12]
	}
	return token, HashToken(token), prefix, nil
}

func HashToken(token string) []byte {
	sum := hashSHA256(token)
	return sum
}

// AgentAccount is the credential row used during login.
type AgentAccount struct {
	ID           uuid.UUID
	TenantID     uuid.UUID
	Email        string
	DisplayName  string
	PasswordHash string
	Role         string
	Status       string
	TenantStatus string
}

type Authenticator struct {
	pool *pgxpool.Pool
}

func NewAuthenticator(pool *pgxpool.Pool) *Authenticator { return &Authenticator{pool: pool} }

// Login validates credentials. It always executes a password verification, even
// when the account does not exist, so response timing does not reveal which
// emails are registered.
func (a *Authenticator) Login(ctx context.Context, email, password, tenantSlug string) (AgentAccount, error) {
	const dummyHash = "argon2id$v=19$m=65536,t=3,p=2$c29tZXNhbHR2YWx1ZTEy$Zm9yLXRpbWluZy1lcXVhbGl6YXRpb24tMDAwMDA"

	var account AgentAccount
	query := `
		select ag.id, ag.tenant_id, ag.email, ag.display_name, ag.password_hash, ag.role, ag.status, t.status
		  from agent ag
		  join tenant t on t.id = ag.tenant_id
		 where lower(ag.email) = lower($1)`
	args := []any{strings.TrimSpace(email)}
	if tenantSlug != "" {
		query += " and t.slug = $2"
		args = append(args, tenantSlug)
	}
	query += " limit 1"

	err := a.pool.QueryRow(ctx, query, args...).Scan(&account.ID, &account.TenantID, &account.Email,
		&account.DisplayName, &account.PasswordHash, &account.Role, &account.Status, &account.TenantStatus)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			VerifyPassword(dummyHash, password)
			return AgentAccount{}, ErrInvalidCredentials
		}
		return AgentAccount{}, err
	}
	if !VerifyPassword(account.PasswordHash, password) {
		return AgentAccount{}, ErrInvalidCredentials
	}
	if account.Status != "ACTIVE" {
		return AgentAccount{}, errors.New("该坐席账号已被停用")
	}
	if account.TenantStatus != "ACTIVE" {
		return AgentAccount{}, errors.New("该企业账号已停用，请联系 RelayDesk")
	}
	return account, nil
}

// CreateSession stores the session hash and returns the plaintext token.
func (a *Authenticator) CreateSession(ctx context.Context, agentID uuid.UUID, ttlHours int) (uuid.UUID, string, error) {
	token, hash, err := NewOpaqueToken()
	if err != nil {
		return uuid.Nil, "", err
	}
	sessionID := uuid.New()
	// make_interval takes the number directly, so no string concatenation and no
	// implicit text cast is involved.
	_, err = a.pool.Exec(ctx, `insert into agent_session(id, agent_id, token_hash, expires_at)
		values($1, $2, $3, now() + make_interval(hours => $4::int))`, sessionID, agentID, hash, ttlHours)
	return sessionID, token, err
}

func (a *Authenticator) RevokeSession(ctx context.Context, sessionID uuid.UUID) error {
	if sessionID == uuid.Nil {
		return nil
	}
	_, err := a.pool.Exec(ctx, `delete from agent_session where id = $1`, sessionID)
	return err
}

func (a *Authenticator) RevokeAllSessions(ctx context.Context, agentID uuid.UUID) error {
	_, err := a.pool.Exec(ctx, `delete from agent_session where agent_id = $1`, agentID)
	return err
}

// SessionValid supports force-logout after a password change.
func (a *Authenticator) SessionValid(ctx context.Context, sessionID, agentID uuid.UUID) bool {
	if sessionID == uuid.Nil {
		return true
	}
	var exists bool
	err := a.pool.QueryRow(ctx, `select exists(select 1 from agent_session where id=$1 and agent_id=$2 and expires_at > now())`,
		sessionID, agentID).Scan(&exists)
	return err == nil && exists
}

func (a *Authenticator) DeleteExpiredSessions(ctx context.Context) error {
	_, err := a.pool.Exec(ctx, `delete from agent_session where expires_at < now()`)
	return err
}
