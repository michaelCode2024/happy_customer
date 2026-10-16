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

// Usage records what a completion cost. Tokens are only present when the
// gateway reports them; a tenant can therefore see spend per conversation
// without TongYu having to guess at a price list it does not control.
type Usage struct {
	PromptTokens     int `json:"promptTokens,omitempty"`
	CompletionTokens int `json:"completionTokens,omitempty"`
	TotalTokens      int `json:"totalTokens,omitempty"`
}

// Provider is the abstraction every AI backend implements. TongYu ships an
// OpenAI-compatible HTTP provider (which also covers DeepSeek, Qwen, Moonshot
// and most domestic Chinese gateways) and a deterministic offline provider so
// the platform keeps working when no model credentials are configured.
type Provider interface {
	Name() string
	// Complete returns the answer text alone. It is kept because most callers
	// (the knowledge test bench, translation, summarisation) do not care about
	// accounting.
	Complete(ctx context.Context, messages []Message) (string, error)
	// Generate is Complete plus token accounting, so per-tenant spend can be
	// recorded on every ai_interaction row.
	Generate(ctx context.Context, messages []Message) (string, Usage, error)
	// GenerateWithTools runs a chat completion that may emit tool calls.
	// The caller supplies tool definitions; the provider dispatches them and
	// loops until the model returns plain text or maxToolRounds is reached.
	GenerateWithTools(ctx context.Context, messages []Message, tools []Tool, maxToolRounds int) (string, Usage, error)
	// Stream delivers the answer incrementally. A nil channel with a nil error
	// means the provider cannot stream and the caller should fall back to
	// Generate.
	Stream(ctx context.Context, messages []Message) (<-chan string, error)
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

func (p *disabledProvider) Name() string    { return "disabled" }
func (p *disabledProvider) Available() bool { return false }

func (p *disabledProvider) err() error {
	if p.reason != "" {
		return errors.New(p.reason)
	}
	return errors.New("AI provider is not configured")
}

func (p *disabledProvider) Complete(context.Context, []Message) (string, error) {
	return "", p.err()
}

func (p *disabledProvider) Generate(context.Context, []Message) (string, Usage, error) {
	return "", Usage{}, p.err()
}

func (p *disabledProvider) GenerateWithTools(context.Context, []Message, []Tool, int) (string, Usage, error) {
	return "", Usage{}, p.err()
}

func (p *disabledProvider) Stream(context.Context, []Message) (<-chan string, error) {
	return nil, p.err()
}
