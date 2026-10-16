package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/tongyu/tongyu/internal/config"
	"github.com/tongyu/tongyu/internal/platform/database"
	"github.com/tongyu/tongyu/internal/server"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg, err := config.Load()
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	pool, err := database.Open(ctx, cfg.DatabaseURL, cfg.DatabaseMaxConns)
	if err != nil {
		logger.Error("database unavailable", "error", err)
		os.Exit(1)
	}
	defer pool.Close()
	if err := database.Migrate(ctx, pool); err != nil {
		logger.Error("migration failed", "error", err)
		os.Exit(1)
	}
	if cfg.DemoEnabled {
		if err := database.EnsureDemoData(ctx, pool); err != nil {
			logger.Error("demo data initialization failed", "error", err)
			os.Exit(1)
		}
	}
	if err := database.EnsurePlatformAdmin(ctx, pool, cfg.PlatformAdminEmail, cfg.PlatformAdminPassword); err != nil {
		logger.Error("platform administrator initialization failed", "error", err)
		os.Exit(1)
	}

	api, err := server.New(cfg, pool, logger)
	if err != nil {
		logger.Error("http layer initialization failed", "error", err)
		os.Exit(1)
	}
	// Backfill embeddings for existing knowledge entries (one-time operation).
	if cfg.AI.EmbeddingProvider != "" && cfg.AI.APIKey != "" {
		if err := api.BackfillEmbeddings(ctx, logger); err != nil {
			logger.Warn("embedding backfill failed (non-fatal)", "error", err)
		}
	}
	go api.Run(ctx)

	httpServer := &http.Server{
		Addr:              cfg.ListenAddress,
		Handler:           api.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       75 * time.Second,
	}

	go func() {
		logger.Info("tongyu started", "address", cfg.ListenAddress)
		if cfg.DemoEnabled {
			logger.Info("demo login (development only)",
				"console", cfg.PublicBaseURL+"/console/",
				"tenant", database.DemoTenantSlug,
				"ownerEmail", database.DemoOwnerEmail,
				"agentEmail", database.DemoAgentEmail,
				"password", database.DemoAgentPassword)
		}
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("server stopped unexpectedly", "error", err)
			stop()
		}
	}()

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		logger.Error("graceful shutdown failed", "error", err)
	}
}
