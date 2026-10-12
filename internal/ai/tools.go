package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// Tool is one executable capability the model can call during assistant
// tasks. Each tool is a named function with a JSON Schema description; the
// model decides which tool to call based on the conversation, and the
// server runs the handler before handing the result back to the model.
type Tool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters"`
	Handler     ToolHandler     `json:"-"`
}

// ToolHandler is the executable body of a tool. It receives the parsed
// arguments and returns a text result the model can reason about. Errors
// are rendered as model-visible error messages rather than exceptions so
// the model can retry with corrected arguments.
type ToolHandler func(ctx context.Context, args map[string]any) (string, error)

// ToolCall is one invocation the model asked for in a completion response.
type ToolCall struct {
	ID       string
	Name     string
	ArgsJSON string
	Raw      map[string]any
}

// ToolResult carries the text a handler produced back to the model as a
// system-side message so the model can continue the conversation.
type ToolResult struct {
	CallID  string
	Content string
	Error   string
}

func parseToolCall(raw map[string]any) (*ToolCall, error) {
	rawName, _ := raw["name"].(string)
	rawArgs, _ := json.Marshal(raw["arguments"])
	id, _ := raw["id"].(string)
	if id == "" || rawName == "" {
		return nil, fmt.Errorf("tool call missing id or name")
	}
	return &ToolCall{ID: id, Name: rawName, ArgsJSON: string(rawArgs)}, nil
}

func invokeTools(ctx context.Context, tools []Tool, calls []map[string]any) ([]ToolResult, error) {
	results := make([]ToolResult, 0, len(calls))
	for _, raw := range calls {
		call, err := parseToolCall(raw)
		if err != nil {
			results = append(results, ToolResult{
				CallID:  asString(raw["id"]),
				Error:   fmt.Sprintf("tool call parse failed: %v", err),
			})
			continue
		}
		var handler ToolHandler
		for _, t := range tools {
			if t.Name == call.Name {
				handler = t.Handler
				break
			}
		}
		if handler == nil {
			results = append(results, ToolResult{
				CallID: call.ID,
				Error:  fmt.Sprintf("unknown tool: %s", call.Name),
			})
			continue
		}
		var argsMap map[string]any
		_ = json.Unmarshal([]byte(call.ArgsJSON), &argsMap)
		content, err := handler(ctx, argsMap)
		results = append(results, ToolResult{
			CallID:  call.ID,
			Content: content,
			Error:   errorMessage(err),
		})
	}
	return results, nil
}

func asString(v any) string {
	if v == nil {
		return ""
	}
	switch s := v.(type) {
	case string:
		return s
	case fmt.Stringer:
		return s.String()
	default:
		b, _ := json.Marshal(v)
		return string(b)
	}
}

func errorMessage(err error) string {
	if err == nil {
		return ""
	}
	return strings.TrimSpace(err.Error())
}

// ToolMessages builds the assistant+tool messages to feed back after
// invoking the tools the model requested.
func ToolMessages(toolResults []ToolResult) []Message {
	messages := make([]Message, 0, len(toolResults)*2)
	for _, r := range toolResults {
		content := r.Content
		if r.Error != "" {
			content = "ERROR: " + r.Error
		}
		messages = append(messages,
			Message{Role: "assistant", Content: ""},
			Message{Role: "tool", Content: content},
		)
	}
	return messages
}
