package server

import (
	"net"
	"net/http"
	"strings"

	"github.com/relaydesk/relaydesk/internal/ratelimit"
)

// limit wraps a public handler with a per-caller token bucket. Callers are
// identified by their token when present and by IP otherwise, so a single
// abusive browser cannot exhaust a shared office NAT.
func (a *API) limit(limiter *ratelimit.Limiter, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if limiter == nil || limiter.Allow(rateKey(r)) {
			next(w, r)
			return
		}
		w.Header().Set("Retry-After", "60")
		failCode(w, 429, "RATE_LIMITED", "请求过于频繁，请稍后再试")
	}
}

func rateKey(r *http.Request) string {
	if token := bearer(r); token != "" {
		return "t:" + token
	}
	if token := r.URL.Query().Get("token"); token != "" {
		return "t:" + token
	}
	return "ip:" + clientIP(r)
}

// clientIP trusts the left-most X-Forwarded-For entry because RelayDesk is
// expected to run behind a reverse proxy or platform load balancer.
func clientIP(r *http.Request) string {
	if forwarded := r.Header.Get("X-Forwarded-For"); forwarded != "" {
		if index := strings.Index(forwarded, ","); index > 0 {
			return strings.TrimSpace(forwarded[:index])
		}
		return strings.TrimSpace(forwarded)
	}
	if real := r.Header.Get("X-Real-IP"); real != "" {
		return strings.TrimSpace(real)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
