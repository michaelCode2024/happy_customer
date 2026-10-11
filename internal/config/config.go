package config

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	ListenAddress      string
	PublicBaseURL      string
	StaticDir          string
	DatabaseURL        string
	DatabaseMaxConns   int32
	WidgetTokenKey     string
	WidgetTokenTTL     time.Duration
	AgentSessionTTL    time.Duration
	PlatformAdminToken string
	AllowedOrigins     []string
	// FrameAncestors drives Content-Security-Policy frame-ancestors on /h5.
	// Empty / "*" means any parent may iframe the embed page (delivery default).
	FrameAncestors     []string
	MaxWSConnections   int
	DemoEnabled        bool
	Storage            Storage
	Webhook            Webhook
	AI                 AI
	RateLimit          RateLimit
	Upload             Upload
}

type Storage struct {
	Driver            string
	LocalDir          string
	S3Bucket          string
	S3Region          string
	S3Endpoint        string
	S3AccessKeyID     string
	S3SecretAccessKey string
	S3PathStyle       bool
}

type Webhook struct {
	MaxAttempts int
	Timeout     time.Duration
}

// AI configures the optional large-model provider. Leaving AI_PROVIDER empty
// disables automatic answers; the rest of the platform keeps working.
type AI struct {
	Provider       string
	BaseURL        string
	APIKey         string
	Model          string
	Temperature    float64
	MaxTokens      int
	TimeoutSeconds int
	// ConfidenceThreshold is a coverage floor, not a similarity floor: it is the
	// share of the question's distinctive terms an article must match before the
	// bot will answer from it. Measured on the demo knowledge base, an article
	// asked about in its own words scores 1.0, a genuine paraphrase 0.47–0.76,
	// and an unrelated question at most 0.24 — so 0.35 declines to answer rather
	// than answer from the wrong article. Raising it makes the bot more willing
	// to hand off to a person; lowering it makes it more willing to guess.
	ConfidenceThreshold float64
	AutoReplyEnabled    bool
}

type RateLimit struct {
	WidgetPerMinute int
	WidgetBurst     int
	LoginPerMinute  int
	LoginBurst      int
	UploadPerMinute int
	UploadBurst     int
	OpenPerMinute   int
	OpenBurst       int
	AssistPerMinute int
	AssistBurst     int
}

type Upload struct {
	MaxBytes       int64
	AllowedTypes   []string
	PublicBasePath string
}

func Load() (Config, error) {
	widgetTTL, err := duration("WIDGET_TOKEN_TTL", "12h")
	if err != nil {
		return Config{}, err
	}
	sessionTTL, err := duration("AGENT_SESSION_TTL", "720h")
	if err != nil {
		return Config{}, err
	}
	demo, err := boolean("DEMO_ENABLED", false)
	if err != nil {
		return Config{}, err
	}
	pathStyle, err := boolean("S3_PATH_STYLE", true)
	if err != nil {
		return Config{}, err
	}
	autoReply, err := boolean("AI_AUTO_REPLY_ENABLED", true)
	if err != nil {
		return Config{}, err
	}
	maxAttempts, err := integer("WEBHOOK_MAX_ATTEMPTS", 6)
	if err != nil {
		return Config{}, err
	}
	maxUploadMB, err := integer("UPLOAD_MAX_MB", 20)
	if err != nil {
		return Config{}, err
	}
	temperature, err := float("AI_TEMPERATURE", 0.2)
	if err != nil {
		return Config{}, err
	}
	threshold, err := float("AI_CONFIDENCE_THRESHOLD", 0.35)
	if err != nil {
		return Config{}, err
	}
	maxTokens, err := integer("AI_MAX_TOKENS", 800)
	if err != nil {
		return Config{}, err
	}
	aiTimeout, err := integer("AI_TIMEOUT_SECONDS", 45)
	if err != nil {
		return Config{}, err
	}
	widgetRate, err := integer("RATE_LIMIT_WIDGET_PER_MINUTE", 240)
	if err != nil {
		return Config{}, err
	}
	loginRate, err := integer("RATE_LIMIT_LOGIN_PER_MINUTE", 20)
	if err != nil {
		return Config{}, err
	}
	uploadRate, err := integer("RATE_LIMIT_UPLOAD_PER_MINUTE", 60)
	if err != nil {
		return Config{}, err
	}
	// A tenant's own backend legitimately bursts, so the open API gets a higher
	// ceiling than the public widget.
	openRate, err := integer("RATE_LIMIT_OPEN_API_PER_MINUTE", 600)
	if err != nil {
		return Config{}, err
	}
	// Assistant calls cost the tenant real money at a model gateway, so they get
	// their own ceiling: an agent leaning on the suggest button all day is
	// exactly the pattern this limit exists to make visible.
	assistRate, err := integer("RATE_LIMIT_ASSIST_PER_MINUTE", 60)
	if err != nil {
		return Config{}, err
	}
	// 连接池默认按单实例中等负载留余量；LISTEN 会长期占用一条，别压得太紧。
	dbMaxConns, err := integer("DATABASE_MAX_CONNS", 40)
	if err != nil {
		return Config{}, err
	}
	if dbMaxConns < 4 {
		return Config{}, errors.New("DATABASE_MAX_CONNS must be at least 4")
	}
	// 0 = 不限制；生产建议按实例内存与 FD 上限设一个硬顶，避免慢客户端拖垮进程。
	maxWS, err := integer("MAX_WS_CONNECTIONS", 10000)
	if err != nil {
		return Config{}, err
	}

	storage := Storage{
		Driver:            env("STORAGE_DRIVER", "local"),
		LocalDir:          env("STORAGE_LOCAL_DIR", "data/uploads"),
		S3Bucket:          env("S3_BUCKET", ""),
		S3Region:          env("S3_REGION", "us-east-1"),
		S3Endpoint:        env("S3_ENDPOINT", ""),
		S3AccessKeyID:     env("S3_ACCESS_KEY_ID", ""),
		S3SecretAccessKey: env("S3_SECRET_ACCESS_KEY", ""),
		S3PathStyle:       pathStyle,
	}
	if storage.Driver != "local" && storage.Driver != "s3" {
		return Config{}, errors.New("STORAGE_DRIVER must be local or s3")
	}
	if storage.Driver == "s3" && (storage.S3Bucket == "" || storage.S3AccessKeyID == "" || storage.S3SecretAccessKey == "") {
		return Config{}, errors.New("S3_BUCKET, S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY are required when STORAGE_DRIVER=s3")
	}

	cfg := Config{
		ListenAddress:      env("LISTEN_ADDRESS", ":8080"),
		PublicBaseURL:      strings.TrimSuffix(env("PUBLIC_BASE_URL", "http://localhost:8080"), "/"),
		StaticDir:          env("STATIC_DIR", ""),
		DatabaseURL:        env("DATABASE_URL", "postgres://relaydesk:relaydesk@localhost:5432/relaydesk?sslmode=disable"),
		DatabaseMaxConns:   int32(dbMaxConns),
		WidgetTokenKey:     env("WIDGET_TOKEN_SECRET", "local-only-change-this-secret-before-production"),
		WidgetTokenTTL:     widgetTTL,
		AgentSessionTTL:    sessionTTL,
		PlatformAdminToken: env("PLATFORM_ADMIN_TOKEN", ""),
		AllowedOrigins:     splitAndTrim(env("ALLOWED_ORIGINS", env("ALLOWED_ORIGIN", "*"))),
		FrameAncestors:     splitAndTrim(env("FRAME_ANCESTORS", "*")),
		MaxWSConnections:   maxWS,
		DemoEnabled:        demo,
		Storage:            storage,
		Webhook:            Webhook{MaxAttempts: maxAttempts, Timeout: 10 * time.Second},
		AI: AI{
			Provider:            env("AI_PROVIDER", ""),
			BaseURL:             env("AI_BASE_URL", ""),
			APIKey:              env("AI_API_KEY", ""),
			Model:               env("AI_MODEL", ""),
			Temperature:         temperature,
			MaxTokens:           maxTokens,
			TimeoutSeconds:      aiTimeout,
			ConfidenceThreshold: threshold,
			AutoReplyEnabled:    autoReply,
		},
		RateLimit: RateLimit{
			WidgetPerMinute: widgetRate,
			WidgetBurst:     widgetRate,
			LoginPerMinute:  loginRate,
			LoginBurst:      loginRate,
			UploadPerMinute: uploadRate,
			UploadBurst:     uploadRate,
			OpenPerMinute:   openRate,
			OpenBurst:       openRate,
			AssistPerMinute: assistRate,
			AssistBurst:     assistRate,
		},
		Upload: Upload{
			MaxBytes: int64(maxUploadMB) << 20,
			AllowedTypes: splitAndTrim(env("UPLOAD_ALLOWED_TYPES",
				"image/png,image/jpeg,image/gif,image/webp,application/pdf,text/plain,application/zip,application/msword,application/vnd.openxmlformats-officedocument.wordprocessingml.document,application/vnd.ms-excel,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")),
			PublicBasePath: "/api/v1/files",
		},
	}
	if len(cfg.WidgetTokenKey) < 32 {
		return Config{}, errors.New("WIDGET_TOKEN_SECRET must contain at least 32 characters")
	}
	if cfg.PlatformAdminToken == "" {
		if !cfg.DemoEnabled {
			return Config{}, errors.New("PLATFORM_ADMIN_TOKEN is required when DEMO_ENABLED is false")
		}
		cfg.PlatformAdminToken = "demo-platform-admin-token"
	}
	return cfg, nil
}

func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func integer(key string, fallback int) (int, error) {
	value := os.Getenv(key)
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer", key)
	}
	if parsed < 0 {
		return 0, fmt.Errorf("%s must not be negative", key)
	}
	return parsed, nil
}

func float(key string, fallback float64) (float64, error) {
	value := os.Getenv(key)
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return 0, fmt.Errorf("%s must be a number", key)
	}
	return parsed, nil
}

func boolean(key string, fallback bool) (bool, error) {
	value := os.Getenv(key)
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return false, fmt.Errorf("%s must be true or false", key)
	}
	return parsed, nil
}

func duration(key, fallback string) (time.Duration, error) {
	value := os.Getenv(key)
	if value == "" {
		value = fallback
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("%s must be a Go duration such as 12h", key)
	}
	return parsed, nil
}

func splitAndTrim(value string) []string {
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			result = append(result, trimmed)
		}
	}
	return result
}

func (s Storage) Describe() string {
	if s.Driver == "s3" {
		return fmt.Sprintf("s3 bucket=%s region=%s", s.S3Bucket, s.S3Region)
	}
	return "local dir=" + s.LocalDir
}
