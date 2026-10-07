package ai

import (
	"context"
	"errors"
	"strings"
)

// Message is one turn in a chat completion conversation.
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// Provider is the abstraction every AI backend implements. RelayDesk ships an
// OpenAI-compatible HTTP provider (which also covers DeepSeek, Qwen, Moonshot
// and most domestic Chinese gateways) and a deterministic offline provider so
// the platform keeps working when no model credentials are configured.
type Provider interface {
	Name() string
	Complete(ctx context.Context, messages []Message) (string, error)
	Available() bool
}

type Config struct {
	Provider    string
	BaseURL     string
	APIKey      string
	Model       string
	Temperature float64
	MaxTokens   int
	Timeout     int
}

func New(cfg Config) Provider {
	switch strings.ToLower(strings.TrimSpace(cfg.Provider)) {
	case "", "none", "off", "disabled":
		return &disabledProvider{}
	case "openai", "compatible", "deepseek", "qwen", "moonshot", "custom":
		return newOpenAIProvider(cfg)
	default:
		return &disabledProvider{reason: "unsupported AI_PROVIDER " + cfg.Provider}
	}
}

type disabledProvider struct{ reason string }

func (p *disabledProvider) Name() string  { return "disabled" }
func (p *disabledProvider) Available() bool { return false }
func (p *disabledProvider) Complete(context.Context, []Message) (string, error) {
	if p.reason != "" {
		return "", errors.New(p.reason)
	}
	return "", errors.New("AI provider is not configured")
}
