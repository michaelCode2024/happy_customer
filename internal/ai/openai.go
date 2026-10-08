package ai

import (
	"bufio"
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
	Stream      bool      `json:"stream,omitempty"`
	// stream_options is not understood by every gateway, so it is only sent on
	// the streaming path where the final usage chunk is worth having. A gateway
	// that rejects it fails the stream, and the caller falls back to Generate.
	StreamOptions *streamOptions `json:"stream_options,omitempty"`
}

type streamOptions struct {
	IncludeUsage bool `json:"include_usage"`
}

type usagePayload struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

type completionResponse struct {
	Choices []struct {
		Message Message `json:"message"`
	} `json:"choices"`
	Usage *usagePayload `json:"usage"`
	Error *struct {
		Message string `json:"message"`
		Type    string `json:"type"`
	} `json:"error"`
}

// streamChunk is one server-sent event from a streaming completion. The delta
// carries a partial answer, and the last event before [DONE] usually carries the
// run's token counts.
type streamChunk struct {
	Choices []struct {
		Delta struct {
			Content string `json:"content"`
		} `json:"delta"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
	Usage *usagePayload `json:"usage"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error"`
}

func (p *openAIProvider) Complete(ctx context.Context, messages []Message) (string, error) {
	answer, _, err := p.Generate(ctx, messages)
	if err != nil {
		return "", err
	}
	return answer, nil
}

func (p *openAIProvider) Generate(ctx context.Context, messages []Message) (string, Usage, error) {
	parsed, err := p.post(ctx, completionRequest{
		Model:       p.model,
		Messages:    messages,
		Temperature: p.temperature,
		MaxTokens:   p.maxTokens,
	})
	if err != nil {
		return "", Usage{}, err
	}
	if parsed.Error != nil {
		return "", Usage{}, errors.New(parsed.Error.Message)
	}
	if len(parsed.Choices) == 0 {
		return "", Usage{}, errors.New("model returned no choices")
	}
	return strings.TrimSpace(parsed.Choices[0].Message.Content), usageOf(parsed.Usage), nil
}

// Stream forwards answer fragments as the model writes them. The channel closes
// when the stream ends; the caller can abandon it early by cancelling ctx, which
// is what happens when an agent takes over the conversation mid-answer.
func (p *openAIProvider) Stream(ctx context.Context, messages []Message) (<-chan string, error) {
	if !p.Available() {
		return nil, errors.New("AI provider credentials are missing")
	}
	body, err := json.Marshal(completionRequest{
		Model:         p.model,
		Messages:      messages,
		Temperature:   p.temperature,
		MaxTokens:     p.maxTokens,
		Stream:        true,
		StreamOptions: &streamOptions{IncludeUsage: true},
	})
	if err != nil {
		return nil, err
	}
	// The response body streams, so the request needs its own context rather
	// than the shared client timeout: a long answer would otherwise be cut off
	// mid-sentence by a deadline meant for a whole request.
	streamCtx, cancel := context.WithCancel(ctx)
	request, err := http.NewRequestWithContext(streamCtx, http.MethodPost, p.baseURL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		cancel()
		return nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+p.apiKey)
	request.Header.Set("Accept", "text/event-stream")
	response, err := p.client.Do(request)
	if err != nil {
		cancel()
		return nil, err
	}
	if response.StatusCode >= 300 {
		payload, _ := io.ReadAll(io.LimitReader(response.Body, 1<<16))
		response.Body.Close()
		cancel()
		return nil, fmt.Errorf("model gateway returned %d: %s", response.StatusCode, truncate(string(payload), 300))
	}

	out := make(chan string, 16)
	go func() {
		defer close(out)
		defer response.Body.Close()
		defer cancel()
		scanner := bufio.NewScanner(response.Body)
		scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			// SSE frames are "data: {json}". Comments and blank separators
			// carry nothing.
			if !strings.HasPrefix(line, "data:") {
				continue
			}
			payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
			if payload == "" || payload == "[DONE]" {
				continue
			}
			var chunk streamChunk
			if json.Unmarshal([]byte(payload), &chunk) != nil {
				continue
			}
			if chunk.Error != nil {
				return
			}
			for _, choice := range chunk.Choices {
				if choice.Delta.Content == "" {
					continue
				}
				select {
				case out <- choice.Delta.Content:
				case <-streamCtx.Done():
					return
				}
			}
		}
	}()
	return out, nil
}

func (p *openAIProvider) post(ctx context.Context, payload completionRequest) (completionResponse, error) {
	var parsed completionResponse
	if !p.Available() {
		return parsed, errors.New("AI provider credentials are missing")
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return parsed, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, p.baseURL+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return parsed, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+p.apiKey)
	response, err := p.client.Do(request)
	if err != nil {
		return parsed, err
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return parsed, err
	}
	if response.StatusCode >= 300 {
		return parsed, fmt.Errorf("model gateway returned %d: %s", response.StatusCode, truncate(string(raw), 300))
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return parsed, fmt.Errorf("decode model response: %w", err)
	}
	return parsed, nil
}

func usageOf(payload *usagePayload) Usage {
	if payload == nil {
		return Usage{}
	}
	total := payload.TotalTokens
	if total == 0 {
		total = payload.PromptTokens + payload.CompletionTokens
	}
	return Usage{
		PromptTokens:     payload.PromptTokens,
		CompletionTokens: payload.CompletionTokens,
		TotalTokens:      total,
	}
}

func truncate(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	return value[:limit] + "..."
}
