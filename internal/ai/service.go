package ai

import (
	"context"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// NullReason explains why no model was consulted, or why an answer was withheld.
type NullReason string

const (
	ReasonDisabled     NullReason = "AI_DISABLED"
	ReasonNotRouted    NullReason = "NO_ROUTING_RULE"
	ReasonNoKnowledge  NullReason = "NO_KNOWLEDGE_BASE"
	ReasonLowScore     NullReason = "LOW_CONFIDENCE"
	ReasonAgentPresent NullReason = "AGENT_ALREADY_ASSIGNED"
	ReasonProviderFail NullReason = "PROVIDER_ERROR"
)

// Reply is the outcome of one automatic answer attempt.
type Reply struct {
	Content  string
	Score    float64
	Provider string
	Handoff  bool
	Reason   NullReason
	Sources  []string
}

// Service answers visitor questions from the tenant knowledge base. It is the
// only place that talks to the model, so prompt rules and handoff behaviour stay
// consistent across the widget, the console preview and the open API.
type Service struct {
	pool      *pgxpool.Pool
	provider  Provider
	threshold float64
}

func NewService(pool *pgxpool.Pool, provider Provider, threshold float64) *Service {
	if threshold <= 0 || threshold > 1 {
		threshold = 0.35
	}
	return &Service{pool: pool, provider: provider, threshold: threshold}
}

// Available reports whether a usable model is configured. The platform runs
// fine with AI switched off; automatic answers are simply skipped.
func (s *Service) Available() bool {
	return s != nil && s.provider != nil && s.provider.Available()
}

// ProviderName is reported by /ready and stored on every ai_interaction row.
func (s *Service) ProviderName() string {
	if s == nil || s.provider == nil {
		return "disabled"
	}
	return s.provider.Name()
}

// Answer looks up the tenant knowledge base for the visitor question and asks
// the model to answer strictly from those snippets. When nothing relevant is
// found the bot hands off to a human instead of inventing an answer, which is
// the behaviour customers expect from a support product.
func (s *Service) Answer(ctx context.Context, tenantID uuid.UUID, question string) (Reply, error) {
	if !s.Available() {
		return Reply{Reason: ReasonDisabled, Handoff: true}, nil
	}
	question = strings.TrimSpace(question)
	if question == "" {
		return Reply{Reason: ReasonNoKnowledge, Handoff: true, Provider: s.ProviderName()}, nil
	}
	entries, err := s.search(ctx, tenantID, question)
	if err != nil {
		return Reply{}, err
	}
	if len(entries) == 0 {
		return Reply{Reason: ReasonNoKnowledge, Handoff: true, Provider: s.ProviderName()}, nil
	}
	best := 0.0
	for _, entry := range entries {
		if entry.score > best {
			best = entry.score
		}
	}
	answer, err := s.provider.Complete(ctx, []Message{
		{Role: "system", Content: systemPrompt},
		{Role: "user", Content: buildPrompt(entries) + "\n\n访客问题：" + question},
	})
	if err != nil {
		return Reply{Reason: ReasonProviderFail, Handoff: true, Provider: s.ProviderName()}, err
	}
	if strings.TrimSpace(answer) == "" {
		return Reply{Reason: ReasonProviderFail, Handoff: true, Provider: s.ProviderName()}, nil
	}
	return Reply{
		Content:  answer,
		Score:    best,
		Provider: s.ProviderName(),
		Sources:  titles(entries),
	}, nil
}

const systemPrompt = `你是 RelayDesk 客服助手。只能依据“知识库资料”回答访客问题。
规则：
1. 如果资料中没有答案，只回复“这个问题需要人工同事协助，我马上为你转接。”
2. 不要编造价格、承诺、政策或时间。
3. 使用与访客相同的语言，语气简洁、专业、友好。
4. 不要输出资料以外的链接或联系方式。`

func buildPrompt(entries []knowledgeEntry) string {
	var builder strings.Builder
	builder.WriteString("知识库资料：\n")
	for index, entry := range entries {
		builder.WriteString("- [")
		builder.WriteString(itoa(index + 1))
		builder.WriteString("] ")
		builder.WriteString(entry.title)
		builder.WriteString("：")
		builder.WriteString(entry.content)
		builder.WriteString("\n")
		if strings.TrimSpace(entry.examples) != "" {
			builder.WriteString("  常见问法：")
			builder.WriteString(entry.examples)
			builder.WriteString("\n")
		}
	}
	return builder.String()
}

func titles(entries []knowledgeEntry) []string {
	result := make([]string, 0, len(entries))
	for _, entry := range entries {
		result = append(result, entry.title)
	}
	return result
}

func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	negative := value < 0
	if negative {
		value = -value
	}
	digits := make([]byte, 0, 4)
	for value > 0 {
		digits = append([]byte{byte('0' + value%10)}, digits...)
		value /= 10
	}
	if negative {
		return "-" + string(digits)
	}
	return string(digits)
}
