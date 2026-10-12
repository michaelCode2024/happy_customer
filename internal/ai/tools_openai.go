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
)

// completionRequestWithTools extends completionRequest to carry the OpenAI
// tools field, which is how function calling is expressed. The model replies
// with a tool_calls array in each choice instead of a plain message content
// field.
type completionRequestWithTools struct {
	Model       string      `json:"model"`
	Messages    []Message   `json:"messages"`
	Temperature float64     `json:"temperature,omitempty"`
	MaxTokens   int         `json:"max_tokens,omitempty"`
	Tools       []toolDef   `json:"tools,omitempty"`
	ToolChoice  any         `json:"tool_choice,omitempty"`
}

type toolDef struct {
	Type     string          `json:"type"`
	Function json.RawMessage `json:"function"`
}

// completionResponseWithTools carries the tool_calls array alongside the
// regular choice shape so the caller can see whether the model asked to
// run a tool or returned plain text.
type completionResponseWithTools struct {
	Choices []struct {
		Message MessageWithToolCalls `json:"message"`
	} `json:"choices"`
	Usage *usagePayload `json:"usage"`
	Error *struct {
		Message string `json:"message"`
		Type    string `json:"type"`
	} `json:"error"`
}

type MessageWithToolCalls struct {
	Role      string        `json:"role"`
	Content   string        `json:"content,omitempty"`
	ToolCalls []toolCallDef `json:"tool_calls,omitempty"`
}

type toolCallDef struct {
	ID       string      `json:"id"`
	Type     string      `json:"type"`
	Function toolFuncDef `json:"function"`
}

type toolFuncDef struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

// GenerateWithTools runs a chat completion that may emit tool calls. It
// loops until the model returns plain text (finish_reason=stop) or gives
// up after maxToolRounds so a misbehaving model cannot spin forever.
func (p *openAIProvider) GenerateWithTools(ctx context.Context, messages []Message, tools []Tool, maxToolRounds int) (string, Usage, error) {
	if !p.Available() {
		return "", Usage{}, errors.New("AI provider credentials are missing")
	}
	toolDefs := make([]toolDef, 0, len(tools))
	for _, t := range tools {
		toolDefs = append(toolDefs, toolDef{
			Type:     "function",
			Function: t.Parameters,
		})
	}
	round := 0
	for {
		body := completionRequestWithTools{
			Model:       p.model,
			Messages:    messages,
			Temperature: p.temperature,
			MaxTokens:   p.maxTokens,
			Tools:       toolDefs,
			ToolChoice:  "auto",
		}
		payload, err := json.Marshal(body)
		if err != nil {
			return "", Usage{}, err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost,
			p.baseURL+"/chat/completions", bytes.NewReader(payload))
		if err != nil {
			return "", Usage{}, err
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+p.apiKey)
		resp, err := p.client.Do(req)
		if err != nil {
			return "", Usage{}, err
		}
		raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		resp.Body.Close()
		if err != nil {
			return "", Usage{}, err
		}
		if resp.StatusCode >= 300 {
			return "", Usage{}, fmt.Errorf("model gateway returned %d: %s", resp.StatusCode, truncate(string(raw), 300))
		}
		var parsed completionResponseWithTools
		if err := json.Unmarshal(raw, &parsed); err != nil {
			return "", Usage{}, fmt.Errorf("decode model response: %w", err)
		}
		if parsed.Error != nil {
			return "", Usage{}, errors.New(parsed.Error.Message)
		}
		if len(parsed.Choices) == 0 {
			return "", Usage{}, errors.New("model returned no choices")
		}
		choice := parsed.Choices[0]
		if len(choice.Message.ToolCalls) == 0 {
			usage := usageOf(parsed.Usage)
			return strings.TrimSpace(choice.Message.Content), usage, nil
		}
		if round >= maxToolRounds {
			return "", Usage{}, fmt.Errorf("tool call depth exceeded (%d rounds)", maxToolRounds)
		}
		round++
		// Build raw calls for dispatch.
		rawCalls := make([]map[string]any, 0, len(choice.Message.ToolCalls))
		for _, tc := range choice.Message.ToolCalls {
			var args map[string]any
			_ = json.Unmarshal([]byte(tc.Function.Arguments), &args)
			rawCalls = append(rawCalls, map[string]any{
				"id":        tc.ID,
				"name":      tc.Function.Name,
				"arguments": args,
			})
		}
		results, err := invokeTools(ctx, tools, rawCalls)
		if err != nil {
			return "", Usage{}, err
		}
		// Append assistant tool_calls message then tool result messages.
		messages = append(messages, Message{Role: "assistant", Content: ""})
		for _, r := range results {
			content := r.Content
			if r.Error != "" {
				content = "ERROR: " + r.Error
			}
			messages = append(messages, Message{Role: "tool", Content: content})
		}
	}
}
