package server

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/google/uuid"

	"github.com/relaydesk/relaydesk/internal/ai"
	"github.com/relaydesk/relaydesk/internal/auth"
)

// The assistant endpoints. They are split from console_extra.go because they
// share one shape — resolve a task, gather the material, hand it to the AI
// service, account for the tokens — and because none of them may write to a
// conversation. Everything an operator gets here is a draft they have to send.

type assistRequest struct {
	Task           string `json:"task"`
	Question       string `json:"question"`
	ConversationID string `json:"conversationId"`
	Language       string `json:"language"`
	Tone           string `json:"tone"`
	// History turns is how many prior messages to attach. Zero means the
	// server's default, which is what the console sends.
	HistoryTurns int `json:"historyTurns"`
}

// assistTasks is the closed vocabulary the console may ask for. Accepting an
// arbitrary task name would let a caller reach the default prompt and turn the
// endpoint into a general-purpose model proxy on the tenant's bill.
var assistTasks = map[string]ai.Task{
	"SUGGEST":     ai.TaskSuggest,
	"SUMMARIZE":   ai.TaskSummarize,
	"SENTIMENT":   ai.TaskSentiment,
	"TRANSLATE":   ai.TaskTranslate,
	"POLISH":      ai.TaskPolish,
	"NEXT_ACTION": ai.TaskNextAction,
}

// consoleAssist runs one assistant task and returns the text. It records the
// call before responding: token usage is the tenant's only view of what the
// assistant costs, and a failure to log it would understate consumption.
func (a *API) consoleAssist(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in assistRequest
	if !decode(w, r, &in) {
		return
	}
	task, ok := assistTasks[strings.ToUpper(strings.TrimSpace(in.Task))]
	if !ok {
		fail(w, 400, "不支持的助手任务")
		return
	}
	// A conversation is optional. Summarising a whole thread needs one; tone
	// rewriting a sentence the agent typed does not.
	var conversationID uuid.UUID
	if value := strings.TrimSpace(in.ConversationID); value != "" {
		parsed, err := uuid.Parse(value)
		if err != nil {
			fail(w, 400, "会话 ID 不合法")
			return
		}
		// The same membership rule every console route uses, so the assistant
		// cannot be used to read a transcript the agent cannot open.
		if !a.agentCanSee(r, p, parsed) {
			failCode(w, 404, "CONVERSATION_NOT_FOUND", "会话不存在或你没有权限")
			return
		}
		conversationID = parsed
	}

	request := ai.AssistRequest{
		TenantID: p.TenantID,
		Task:     task,
		Question: strings.TrimSpace(in.Question),
		Language: strings.TrimSpace(in.Language),
		Tone:     strings.TrimSpace(in.Tone),
	}
	if conversationID != uuid.Nil {
		limit := in.HistoryTurns
		if limit <= 0 {
			limit = 20
		}
		if limit > 60 {
			limit = 60
		}
		// Summarising and next-action need the visitor's side of the story most,
		// so the transcript is read in the agent view and trimmed to the tail.
		request.History = a.recentTranscript(r.Context(), conversationID, 0, limit)
	}

	// Pass tenant ID into context so tool handlers can query with proper scoping.
	ctx := withTenantID(r.Context(), p.TenantID)
	finish, quotaErr := a.reserveAIQuota(ctx, p.TenantID)
	if quotaErr != nil {
		if !failServiceError(w, quotaErr) {
			fail(w, 503, "暂时无法读取AI额度")
		}
		return
	}
	success := false
	defer func() { finish(success) }()
	result, err := a.ai.AssistWithTools(ctx, request)
	success = err == nil && strings.TrimSpace(result.Text) != ""
	if err != nil {
		a.logger.Error("assist failed", "error", err, "task", task, "tenant", p.TenantID)
		fail(w, 502, "AI 调用失败，请稍后重试")
		return
	}
	a.recordAssistUsage(ctx, p, conversationID, string(task), result)
	respond(w, 200, map[string]any{
		"task": result.Task, "text": result.Text, "label": result.Label, "score": result.Score,
		"sources": result.Sources, "provider": result.Provider, "usage": result.Usage,
		"available": a.ai.Available(),
	})
}

// consoleAssistStream writes a suggestion as it is produced. Server-sent events
// rather than the websocket: the console already holds a socket for conversation
// traffic, and putting a half-finished draft on it would make every other tab of
// the same agent render a message that does not exist.
func (a *API) consoleAssistStream(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in assistRequest
	if !decode(w, r, &in) {
		return
	}
	if task, ok := assistTasks[strings.ToUpper(strings.TrimSpace(in.Task))]; !ok || task != ai.TaskSuggest {
		fail(w, 400, "仅回复建议支持流式输出")
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		fail(w, 500, "当前服务不支持流式输出")
		return
	}
	if !a.ai.Available() {
		failCode(w, 503, "AI_UNAVAILABLE", "AI 未配置")
		return
	}

	request := ai.AssistRequest{TenantID: p.TenantID, Task: ai.TaskSuggest, Question: strings.TrimSpace(in.Question), Tone: strings.TrimSpace(in.Tone)}
	if value := strings.TrimSpace(in.ConversationID); value != "" {
		if parsed, err := uuid.Parse(value); err == nil && a.agentCanSee(r, p, parsed) {
			request.History = a.recentTranscript(r.Context(), parsed, 0, 20)
		}
	}
	ctx := withTenantID(r.Context(), p.TenantID)
	finish, quotaErr := a.reserveAIQuota(ctx, p.TenantID)
	if quotaErr != nil {
		if !failServiceError(w, quotaErr) {
			fail(w, 503, "暂时无法读取AI额度")
		}
		return
	}
	success := false
	defer func() { finish(success) }()
	stream, err := a.ai.StreamSuggest(ctx, request)
	if err != nil {
		a.logger.Error("assist stream failed", "error", err, "tenant", p.TenantID)
		fail(w, 502, "AI 调用失败，请稍后重试")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(200)
	send := func(payload any) {
		body, err := json.Marshal(payload)
		if err != nil {
			return
		}
		_, _ = w.Write([]byte("data: "))
		_, _ = w.Write(body)
		_, _ = w.Write([]byte("\n\n"))
		flusher.Flush()
	}
	if stream == nil {
		send(map[string]any{"done": true, "text": ""})
		return
	}
	var builder strings.Builder
	for fragment := range stream {
		builder.WriteString(fragment)
		success = true
		send(map[string]any{"delta": fragment})
	}
	send(map[string]any{"done": true, "text": builder.String()})
}

// recordAssistUsage writes the accounting row. Failures are logged and dropped:
// a metering write must never turn a successful answer into an error response.
func (a *API) recordAssistUsage(ctx context.Context, p auth.Principal, conversationID uuid.UUID, task string, result ai.AssistResult) {
	var conversation any
	if conversationID != uuid.Nil {
		conversation = conversationID
	}
	_, err := a.db.Exec(ctx, `insert into ai_interaction(
			id, tenant_id, conversation_id, provider, score, answered, reason,
			sources, task, prompt_tokens, completion_tokens, total_tokens, agent_id)
		values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`,
		uuid.New(), p.TenantID, conversation, result.Provider, result.Score,
		strings.TrimSpace(result.Text) != "", task, result.Sources, task,
		result.Usage.PromptTokens, result.Usage.CompletionTokens, result.Usage.TotalTokens, p.AgentID)
	if err != nil {
		a.logger.Warn("assist usage not recorded", "error", err, "task", task)
	}
}

// consoleAIUsage summarises model consumption for the tenant. It groups by task
// because that is the question an operator asks — "what is the assistant spending
// my budget on" — and by day so the series can be charted without a second
// round trip.
func (a *API) consoleAIUsage(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	days := queryInt(r, "days", 30)
	if days <= 0 || days > 180 {
		days = 30
	}
	rows, err := a.db.Query(r.Context(), `
		select coalesce(task, 'AUTO_ANSWER') as task,
		       count(*)::int,
		       coalesce(sum(prompt_tokens),0)::bigint,
		       coalesce(sum(completion_tokens),0)::bigint,
		       coalesce(sum(total_tokens),0)::bigint,
		       coalesce(sum(case when answered then 1 else 0 end),0)::int
		  from ai_interaction
		 where tenant_id = $1 and created_at >= now() - ($2 || ' days')::interval
		 group by 1
		 order by 5 desc`, p.TenantID, itoa(days))
	if err != nil {
		fail(w, 500, "查询用量失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 8)
	var totalTokens int64
	var totalCalls int
	for rows.Next() {
		var task string
		var calls int
		var prompt, completion, total int64
		var answered int
		if rows.Scan(&task, &calls, &prompt, &completion, &total, &answered) != nil {
			continue
		}
		totalTokens += total
		totalCalls += calls
		items = append(items, map[string]any{
			"task": task, "calls": calls, "answered": answered,
			"promptTokens": prompt, "completionTokens": completion, "totalTokens": total,
		})
	}
	series, _ := a.aiUsageSeries(r.Context(), p.TenantID, days)
	respond(w, 200, map[string]any{
		"items": items, "series": series, "days": days,
		"totalTokens": totalTokens, "totalCalls": totalCalls,
		"provider": a.ai.ProviderName(), "available": a.ai.Available(),
	})
}

func (a *API) aiUsageSeries(ctx context.Context, tenantID uuid.UUID, days int) ([]map[string]any, error) {
	rows, err := a.db.Query(ctx, `
		select to_char(date_trunc('day', created_at), 'MM-DD') as day,
		       count(*)::int, coalesce(sum(total_tokens),0)::bigint
		  from ai_interaction
		 where tenant_id = $1 and created_at >= now() - ($2 || ' days')::interval
		 group by 1, date_trunc('day', created_at)
		 order by date_trunc('day', created_at)`, tenantID, itoa(days))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	series := make([]map[string]any, 0, days)
	for rows.Next() {
		var day string
		var calls int
		var tokens int64
		if rows.Scan(&day, &calls, &tokens) != nil {
			continue
		}
		series = append(series, map[string]any{"day": day, "calls": calls, "tokens": tokens})
	}
	return series, nil
}
