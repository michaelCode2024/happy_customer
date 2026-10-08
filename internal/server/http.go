package server

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"runtime/debug"
	"strings"
	"sync/atomic"
	"time"

	"github.com/relaydesk/relaydesk/internal/auth"
)

type middleware func(http.Handler) http.Handler

func chain(handler http.Handler, middlewares ...any) http.Handler {
	result := handler
	for index := len(middlewares) - 1; index >= 0; index-- {
		switch value := middlewares[index].(type) {
		case middleware:
			result = value(result)
		case func(http.Handler) http.Handler:
			result = value(result)
		case *slog.Logger:
			result = recoverer(result, value)
		case []string:
			result = cors(result, value)
		}
	}
	return result
}

func nullable(v string) any {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	return v
}

func respond(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	if v == nil {
		return
	}
	_ = json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, status int, message string) {
	respond(w, status, map[string]any{"status": status, "message": message, "timestamp": time.Now().UTC()})
}

func failCode(w http.ResponseWriter, status int, code, message string) {
	respond(w, status, map[string]any{"status": status, "code": code, "message": message, "timestamp": time.Now().UTC()})
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	if r.Body == nil {
		fail(w, 400, "请求体不能为空")
		return false
	}
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		fail(w, 400, "请求 JSON 不合法："+err.Error())
		return false
	}
	return true
}

func recoverer(next http.Handler, logger *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				logger.Error("request panic", "value", v, "path", r.URL.Path, "stack", string(debug.Stack()))
				fail(w, 500, "服务内部错误")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func cors(next http.Handler, origins []string) http.Handler {
	allowAll := len(origins) == 0
	for _, origin := range origins {
		if origin == "*" {
			allowAll = true
		}
	}
	allowed := make(map[string]struct{}, len(origins))
	for _, origin := range origins {
		allowed[origin] = struct{}{}
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" {
			if _, ok := allowed[origin]; ok || allowAll {
				w.Header().Set("Access-Control-Allow-Origin", origin)
				w.Header().Set("Access-Control-Allow-Credentials", "true")
				w.Header().Add("Vary", "Origin")
			}
		}
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-RelayDesk-Key, X-Request-Id")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PATCH, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Max-Age", "600")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

var requestCounter atomic.Uint64

func (a *API) metrics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		requestCounter.Add(1)
		recorder := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(recorder, r)
		if r.URL.Path == "/health" || r.URL.Path == "/ready" {
			return
		}
		a.logger.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", recorder.status,
			"durationMs", time.Since(started).Milliseconds(),
			"bytes", recorder.bytes)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (s *statusRecorder) WriteHeader(status int) {
	s.status = status
	s.ResponseWriter.WriteHeader(status)
}

func (s *statusRecorder) Write(payload []byte) (int, error) {
	written, err := s.ResponseWriter.Write(payload)
	s.bytes += written
	return written, err
}

// Flush and Hijack must be forwarded so websockets still upgrade behind the
// logging middleware.
func (s *statusRecorder) Flush() {
	if flusher, ok := s.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (s *statusRecorder) Unwrap() http.ResponseWriter { return s.ResponseWriter }

// requireWidget authenticates a visitor token.
func (a *API) requireWidget(next func(http.ResponseWriter, *http.Request, auth.Principal)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		principal, err := a.tokens.Verify(bearer(r))
		if err != nil || principal.Kind != auth.KindWidget {
			failCode(w, 401, "WIDGET_TOKEN_INVALID", "访客令牌无效或已过期，请刷新页面重新连接")
			return
		}
		next(w, r, principal)
	}
}

// requireAgent authenticates an agent token and verifies the session is still
// valid in the database, which makes force-logout immediate.
func (a *API) requireAgent(next func(http.ResponseWriter, *http.Request, auth.Principal)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		principal, err := a.tokens.Verify(bearer(r))
		if err != nil || principal.Kind != auth.KindAgent {
			failCode(w, 401, "AGENT_TOKEN_INVALID", "坐席登录已失效，请重新登录")
			return
		}
		if !a.authn.SessionValid(r.Context(), principal.SessionID, principal.AgentID) {
			failCode(w, 401, "AGENT_SESSION_REVOKED", "登录状态已被注销，请重新登录")
			return
		}
		next(w, r, principal)
	}
}

func (a *API) requireRole(role []string, next func(http.ResponseWriter, *http.Request, auth.Principal)) http.HandlerFunc {
	return a.requireAgent(func(w http.ResponseWriter, r *http.Request, p auth.Principal) {
		for _, candidate := range role {
			if candidate == p.Role {
				next(w, r, p)
				return
			}
		}
		failCode(w, 403, "ROLE_REQUIRED", "当前角色没有操作权限")
	})
}

// requirePlatform authenticates the RelayDesk operations API (tenant creation,
// plan changes, cross-tenant support).
func (a *API) requirePlatform(next func(http.ResponseWriter, *http.Request, auth.Principal)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		principal, err := a.tokens.Verify(bearer(r))
		if err == nil && principal.Kind == auth.KindPlatform {
			next(w, r, principal)
			return
		}
		// The static token is also accepted straight from the Authorization
		// header so deploy scripts and break-glass debugging work without first
		// exchanging it. The X-RelayDesk-Key spelling is kept for callers that
		// already send it.
		if a.cfg.PlatformAdminToken != "" &&
			(subtleEqual(bearer(r), a.cfg.PlatformAdminToken) ||
				subtleEqual(r.Header.Get("X-RelayDesk-Key"), a.cfg.PlatformAdminToken)) {
			next(w, r, auth.Principal{Kind: auth.KindPlatform, Name: "static-token"})
			return
		}
		failCode(w, 401, "PLATFORM_TOKEN_INVALID", "平台管理令牌无效")
	}
}

func bearer(r *http.Request) string {
	header := r.Header.Get("Authorization")
	if header == "" {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))
}

func subtleEqual(a, b string) bool {
	if a == "" || b == "" || len(a) != len(b) {
		return false
	}
	var diff byte
	for index := range a {
		diff |= a[index] ^ b[index]
	}
	return diff == 0
}

func queryInt(r *http.Request, key string, fallback int) int {
	value := r.URL.Query().Get(key)
	if value == "" {
		return fallback
	}
	parsed := 0
	for _, char := range value {
		if char < '0' || char > '9' {
			return fallback
		}
		parsed = parsed*10 + int(char-'0')
		if parsed > 1_000_000 {
			return fallback
		}
	}
	if parsed == 0 {
		return fallback
	}
	return parsed
}

func queryInt64(r *http.Request, key string, fallback int64) int64 {
	return int64(queryInt(r, key, int(fallback)))
}

// truthy reads a boolean query parameter. It accepts the spellings a browser
// form and a hand-written integration realistically send, and treats anything
// else as absent rather than erroring: a mistyped flag should fall back to the
// safe default, not fail the request.
func truthy(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}
