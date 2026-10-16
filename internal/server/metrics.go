package server

import (
	"fmt"
	"net/http"
	"sync/atomic"
	"time"
)

// Lightweight Prometheus-compatible counters. No client library: delivery needs
// scrapeable numbers without pulling another dependency into the binary.

var (
	httpRequestsTotal   atomic.Uint64
	httpDurationMsTotal atomic.Uint64
	wsRejectedTotal     atomic.Uint64
	aiAsyncStartedTotal atomic.Uint64
)

func (a *API) registerMetrics(mux *http.ServeMux) {
	mux.HandleFunc("GET /metrics", a.prometheusMetrics)
}

func (a *API) prometheusMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = fmt.Fprintf(w, "# HELP tongyu_http_requests_total Total HTTP requests handled.\n")
	_, _ = fmt.Fprintf(w, "# TYPE tongyu_http_requests_total counter\n")
	_, _ = fmt.Fprintf(w, "tongyu_http_requests_total %d\n", httpRequestsTotal.Load())
	_, _ = fmt.Fprintf(w, "# HELP tongyu_http_duration_ms_total Cumulative request duration in milliseconds.\n")
	_, _ = fmt.Fprintf(w, "# TYPE tongyu_http_duration_ms_total counter\n")
	_, _ = fmt.Fprintf(w, "tongyu_http_duration_ms_total %d\n", httpDurationMsTotal.Load())
	_, _ = fmt.Fprintf(w, "# HELP tongyu_realtime_connections Current WebSocket connections on this instance.\n")
	_, _ = fmt.Fprintf(w, "# TYPE tongyu_realtime_connections gauge\n")
	_, _ = fmt.Fprintf(w, "tongyu_realtime_connections %d\n", a.hub.Count())
	_, _ = fmt.Fprintf(w, "# HELP tongyu_ws_rejected_total WebSocket handshakes rejected for capacity.\n")
	_, _ = fmt.Fprintf(w, "# TYPE tongyu_ws_rejected_total counter\n")
	_, _ = fmt.Fprintf(w, "tongyu_ws_rejected_total %d\n", wsRejectedTotal.Load())
	_, _ = fmt.Fprintf(w, "# HELP tongyu_ai_async_started_total AI auto-replies started off the send path.\n")
	_, _ = fmt.Fprintf(w, "# TYPE tongyu_ai_async_started_total counter\n")
	_, _ = fmt.Fprintf(w, "tongyu_ai_async_started_total %d\n", aiAsyncStartedTotal.Load())
	_, _ = fmt.Fprintf(w, "# HELP tongyu_uptime_seconds Process uptime.\n")
	_, _ = fmt.Fprintf(w, "# TYPE tongyu_uptime_seconds gauge\n")
	_, _ = fmt.Fprintf(w, "tongyu_uptime_seconds %d\n", int(time.Since(a.startedAt).Seconds()))
	_, _ = fmt.Fprintf(w, "# HELP tongyu_db_max_conns Configured database pool size.\n")
	_, _ = fmt.Fprintf(w, "# TYPE tongyu_db_max_conns gauge\n")
	_, _ = fmt.Fprintf(w, "tongyu_db_max_conns %d\n", a.cfg.DatabaseMaxConns)
	_, _ = fmt.Fprintf(w, "# HELP tongyu_ws_max_connections Configured WebSocket admission cap (0 = unlimited).\n")
	_, _ = fmt.Fprintf(w, "# TYPE tongyu_ws_max_connections gauge\n")
	_, _ = fmt.Fprintf(w, "tongyu_ws_max_connections %d\n", a.cfg.MaxWSConnections)
}
