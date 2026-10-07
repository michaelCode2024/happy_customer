package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// openAIProvider speaks the OpenAI chat-completions protocol, which is the de
// facto standard for both international and Chinese model gateways.
type openAIProvider struct {
	baseURL     string
	apiKey      string
	model       string
	temperature float64
	maxTokens   int
	client      *http.Client
}

func newOpenAIProvider(cfg Config) *openAIProvider {
	baseURL := strings.TrimSuffix(cfg.BaseURL, "/")
	if baseURL == "" {
		baseURL = "https://api.openai.com/v1"
	}
	timeout := time.Duration(cfg.Timeout) * time.Second
	if timeout <= 0 {
		timeout = 45 * time.Second
	}
	return &openAIProvider{
		baseURL:     baseURL,
		apiKey:      cfg.APIKey,
		model:       cfg.Model,
		temperature: cfg.Temperature,
		maxTokens:   cfg.MaxTokens,
		client:      &http.Client{Timeout: timeout},
	}
}

func (p *openAIProvider) Name() string { return "openai-compatible:" + p.model }

func (p *openAIProvider) Available() bool {
	return p.apiKey != "" && p.model != ""
}

type completionRequest struct {
	Model       string    `json:"model"`
	Messages    []Message `json:"messages"`
	Temperature float64   `json:"temperature,omitempty"`
	MaxTokens   int       `json:"max_tokens,omitempty"`
	Stream      bool      `json:"stream"`
}

type completionResponse struct {
	Choices []struct {
		Message Message `json:"message"`
	} `json:"choices"`
	Error *struct {
		Message string `json:"message"`
		Type    string `json:"type"`
	} `json:"error"`
}

func (p *openAIProvider) Complete(ctx context.Context, messages []Message) (string, error) {
	if !p.Available() {
		return "", errors.New("AI provider credentials are missing")
	}
	body, err := json.Marshal(completionRequest{
		Model:       p.model,
		Messages:    messages,
		Temperature: p.temperature,
		MaxTokens:   p.maxTokens,
	})
	if err != nil {
		return "", err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, p.baseURL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+p.apiKey)
	response, err := p.client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return "", err
	}
	if response.StatusCode >= 300 {
		return "", fmt.Errorf("model gateway returned %d: %s", response.StatusCode, truncate(string(payload), 300))
	}
	var parsed completionResponse
	if err := json.Unmarshal(payload, &parsed); err != nil {
		return "", fmt.Errorf("decode model response: %w", err)
	}
	if parsed.Error != nil {
		return "", errors.New(parsed.Error.Message)
	}
	if len(parsed.Choices) == 0 {
		return "", errors.New("model returned no choices")
	}
	return strings.TrimSpace(parsed.Choices[0].Message.Content), nil
}

func truncate(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	return value[:limit] + "..."
}
