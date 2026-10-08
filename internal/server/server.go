package server

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/relaydesk/relaydesk/internal/ai"
	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/config"
	"github.com/relaydesk/relaydesk/internal/ratelimit"
	"github.com/relaydesk/relaydesk/internal/realtime"
	"github.com/relaydesk/relaydesk/internal/storage"
	"github.com/relaydesk/relaydesk/internal/webhook"
)

// API carries every dependency the HTTP layer needs. Handlers are grouped by
// audience in widget.go (visitor), console.go (agent workbench), admin.go
// (tenant management), platform.go (RelayDesk operations) and sockets.go.
type API struct {
	cfg        config.Config
	db         *pgxpool.Pool
	tokens     *auth.TokenService
	authn      *auth.Authenticator
	hub        *realtime.Hub
	bus        *realtime.Bus
	ai         *ai.Service
	store      storage.Store
	webhooks   *webhook.Dispatcher
	widgetRate *ratelimit.Limiter
	loginRate  *ratelimit.Limiter
	uploadRate *ratelimit.Limiter
	openRate   *ratelimit.Limiter
	// aiAssistRate guards the paid assistant endpoints. It is separate from the
	// other buckets because its purpose is cost control, not abuse control.
	aiAssistRate *ratelimit.Limiter
	logger       *slog.Logger
	startedAt    time.Time
}

func New(cfg config.Config, db *pgxpool.Pool, logger *slog.Logger) (*API, error) {
	store, err := storage.New(context.Background(), cfg.Storage)
	if err != nil {
		return nil, err
	}
	hub := realtime.NewHub(logger)
	api := &API{
		cfg:    cfg,
		db:     db,
		tokens: auth.NewTokenService(cfg.WidgetTokenKey, cfg.WidgetTokenTTL, cfg.AgentSessionTTL),
		authn:  auth.NewAuthenticator(db),
		hub:    hub,
		bus:    realtime.NewBus(db, hub, logger),
		ai: ai.NewService(db, ai.New(ai.Config{
			Provider:    cfg.AI.Provider,
			BaseURL:     cfg.AI.BaseURL,
			APIKey:      cfg.AI.APIKey,
			Model:       cfg.AI.Model,
			Temperature: cfg.AI.Temperature,
			MaxTokens:   cfg.AI.MaxTokens,
			Timeout:     cfg.AI.TimeoutSeconds,
		}), cfg.AI.ConfidenceThreshold),
		store:        store,
		webhooks:     webhook.NewDispatcher(db, cfg.Webhook.MaxAttempts, logger),
		widgetRate:   ratelimit.New(cfg.RateLimit.WidgetPerMinute, cfg.RateLimit.WidgetBurst),
		loginRate:    ratelimit.New(cfg.RateLimit.LoginPerMinute, cfg.RateLimit.LoginBurst),
		uploadRate:   ratelimit.New(cfg.RateLimit.UploadPerMinute, cfg.RateLimit.UploadBurst),
		openRate:     ratelimit.New(cfg.RateLimit.OpenPerMinute, cfg.RateLimit.OpenBurst),
		aiAssistRate: ratelimit.New(cfg.RateLimit.AssistPerMinute, cfg.RateLimit.AssistBurst),
		logger:       logger,
		startedAt:    time.Now(),
	}
	return api, nil
}

// Run starts the background workers (event bus, webhook retries, retention) and
// returns when ctx is cancelled.
func (a *API) Run(ctx context.Context) {
	go a.bus.Start(ctx)
	go a.webhooks.Run(ctx)
	go a.retentionLoop(ctx)
}

func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	a.registerSystem(mux)
	a.registerWidget(mux)
	a.registerConsole(mux)
	a.registerAdmin(mux)
	a.registerPlatform(mux)
	a.registerOpen(mux)
	a.registerUploads(mux)
	return chain(mux, a.logger, a.cfg.AllowedOrigins, a.bodyLimit, a.metrics)
}

// bodyLimit keeps large uploads from being buffered by every other endpoint.
func (a *API) bodyLimit(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/uploads" {
			// Endpoint-specific limits (uploads) apply instead; everything else
			// is capped well below what any legitimate request needs.
			r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		}
		next.ServeHTTP(w, r)
	})
}

func (a *API) retentionLoop(ctx context.Context) {
	ticker := time.NewTicker(6 * time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := a.authn.DeleteExpiredSessions(ctx); err != nil && ctx.Err() == nil {
				a.logger.Warn("session cleanup failed", "error", err)
			}
		}
	}
}

func (a *API) registerSystem(mux *http.ServeMux) {
	mux.HandleFunc("GET /health", a.health)
	mux.HandleFunc("GET /ready", a.ready)
	mux.HandleFunc("GET /api/v1/meta", a.meta)
}

func (a *API) health(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if a.db.Ping(ctx) != nil {
		fail(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	respond(w, 200, map[string]any{"status": "UP", "version": version, "uptimeSeconds": int(time.Since(a.startedAt).Seconds())})
}

func (a *API) ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if a.db.Ping(ctx) != nil {
		fail(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	respond(w, 200, map[string]any{"status": "READY", "realtimeConnections": a.hub.Count(),
		"storage": a.cfg.Storage.Driver, "ai": a.ai.ProviderName(), "instance": a.bus.InstanceID()})
}

// meta is public and lets the embed script discover features without an API key.
func (a *API) meta(w http.ResponseWriter, r *http.Request) {
	respond(w, 200, map[string]any{
		"product":     "RelayDesk",
		"version":     version,
		"time":        time.Now().UTC(),
		"aiEnabled":   a.ai.Available(),
		"storageMode": a.cfg.Storage.Driver,
	})
}

// version is overridden at build time with -ldflags.
var version = "0.1.0-dev"

func init() {
	if value := os.Getenv("RELAYDESK_VERSION"); value != "" {
		version = value
	}
}

// newID is a small helper that keeps handler code readable.
func newID() uuid.UUID { return uuid.New() }
