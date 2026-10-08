package server

import (
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/relaydesk/relaydesk/internal/ai"
	"github.com/relaydesk/relaydesk/internal/auth"
)

func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	negative := value < 0
	if negative {
		value = -value
	}
	digits := make([]byte, 0, 8)
	for value > 0 {
		digits = append([]byte{byte('0' + value%10)}, digits...)
		value /= 10
	}
	if negative {
		return "-" + string(digits)
	}
	return string(digits)
}

func rawJSON(payload []byte) any {
	if len(payload) == 0 {
		return map[string]any{}
	}
	var decoded any
	if err := decodeJSONBytes(payload, &decoded); err != nil {
		return map[string]any{}
	}
	return decoded
}

// ---------------------------------------------------------------- productivity

func (a *API) consoleCannedResponses(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	rows, err := a.db.Query(r.Context(), `select id, coalesce(inbox_id, '00000000-0000-0000-0000-000000000000'::uuid),
			title, content, updated_at
		  from canned_response
		 where tenant_id = $1
		 order by title`, p.TenantID)
	if err != nil {
		fail(w, 500, "查询快捷回复失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 16)
	for rows.Next() {
		var id, inboxID uuid.UUID
		var title, content string
		var updatedAt time.Time
		if err := rows.Scan(&id, &inboxID, &title, &content, &updatedAt); err != nil {
			fail(w, 500, "查询快捷回复失败")
			return
		}
		item := map[string]any{"id": id, "title": title, "content": content, "updatedAt": updatedAt}
		if inboxID != uuid.Nil {
			item["inboxId"] = inboxID
		}
		items = append(items, item)
	}
	respond(w, 200, map[string]any{"items": items})
}

func (a *API) consoleCreateCannedResponse(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Title   string `json:"title"`
		Content string `json:"content"`
		InboxID string `json:"inboxId"`
	}
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.Title) == "" || strings.TrimSpace(in.Content) == "" {
		fail(w, 400, "标题和内容都不能为空")
		return
	}
	var inboxID *uuid.UUID
	if in.InboxID != "" {
		parsed, err := uuid.Parse(in.InboxID)
		if err != nil {
			fail(w, 400, "inboxId 不合法")
			return
		}
		inboxID = &parsed
	}
	id := uuid.New()
	if _, err := a.db.Exec(r.Context(), `insert into canned_response(id, tenant_id, inbox_id, title, content)
		values($1,$2,$3,$4,$5)`, id, p.TenantID, inboxID, in.Title, in.Content); err != nil {
		fail(w, 500, "创建快捷回复失败")
		return
	}
	respond(w, 201, map[string]any{"id": id, "title": in.Title, "content": in.Content})
}

func (a *API) consoleUpdateCannedResponse(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "ID 不合法")
		return
	}
	var in struct {
		Title   string `json:"title"`
		Content string `json:"content"`
	}
	if !decode(w, r, &in) {
		return
	}
	tag, err := a.db.Exec(r.Context(), `update canned_response
		set title = coalesce(nullif($3,''), title), content = coalesce(nullif($4,''), content), updated_at = now()
		where id=$1 and tenant_id=$2`, id, p.TenantID, in.Title, in.Content)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "快捷回复不存在")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) consoleDeleteCannedResponse(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "ID 不合法")
		return
	}
	tag, err := a.db.Exec(r.Context(), `delete from canned_response where id=$1 and tenant_id=$2`, id, p.TenantID)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "快捷回复不存在")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) consoleTags(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	rows, err := a.db.Query(r.Context(), `select t.id, t.name, t.color, count(ct.conversation_id)::int
		  from tag t left join conversation_tag ct on ct.tag_id = t.id
		 where t.tenant_id = $1
		 group by t.id, t.name, t.color
		 order by t.name`, p.TenantID)
	if err != nil {
		fail(w, 500, "查询标签失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 16)
	for rows.Next() {
		var id uuid.UUID
		var name, color string
		var usage int
		if err := rows.Scan(&id, &name, &color, &usage); err != nil {
			fail(w, 500, "查询标签失败")
			return
		}
		items = append(items, map[string]any{"id": id, "name": name, "color": color, "conversations": usage})
	}
	respond(w, 200, map[string]any{"items": items})
}

func (a *API) consoleAgents(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	rows, err := a.db.Query(r.Context(), `
		select ag.id, ag.display_name, ag.email, ag.role, ag.status,
		       coalesce(ap.status,'OFFLINE'), coalesce(ap.last_seen_at, ag.created_at),
		       (select count(*)::int from conversation c where c.assignee_id = ag.id and c.status <> 'RESOLVED')
		  from agent ag left join agent_presence ap on ap.agent_id = ag.id
		 where ag.tenant_id = $1 and ag.status = 'ACTIVE' and ag.email <> 'bot@relaydesk.local'
		 order by ag.display_name`, p.TenantID)
	if err != nil {
		fail(w, 500, "查询坐席失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 16)
	for rows.Next() {
		var id uuid.UUID
		var displayName, email, role, status, presence string
		var lastSeen time.Time
		var open int
		if err := rows.Scan(&id, &displayName, &email, &role, &status, &presence, &lastSeen, &open); err != nil {
			fail(w, 500, "查询坐席失败")
			return
		}
		items = append(items, map[string]any{"id": id, "displayName": displayName, "email": email, "role": role,
			"status": status, "presence": presence, "lastSeenAt": lastSeen, "openConversations": open})
	}
	respond(w, 200, map[string]any{"items": items})
}

// consoleStats powers the operations dashboard: today's numbers, the trend for
// the last two weeks, agent leaderboard and AI deflection rate.
func (a *API) consoleStats(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	if !auth.CanViewReports(p.Role) {
		// Ordinary agents still get their own workload.
		var mine int
		_ = a.db.QueryRow(r.Context(), `select count(*)::int from conversation
			where tenant_id=$1 and assignee_id=$2 and status <> 'RESOLVED'`, p.TenantID, p.AgentID).Scan(&mine)
		respond(w, 200, map[string]any{"scope": "agent", "openConversations": mine})
		return
	}
	days := queryInt(r, "days", 14)
	if days < 1 || days > 90 {
		days = 14
	}
	rows, err := a.db.Query(r.Context(), `
		select stat_date, conversations_started, conversations_closed, messages_in, messages_out,
		       ai_answered, ai_handoff, first_response_seconds, first_response_samples, rating_sum, rating_count
		  from tenant_daily_stat
		 where tenant_id = $1 and stat_date >= current_date - $2::int
		 order by stat_date`, p.TenantID, days)
	if err != nil {
		fail(w, 500, "查询统计失败")
		return
	}
	defer rows.Close()
	series := make([]map[string]any, 0, days)
	var totals struct {
		started, closed, in, out, aiAnswered, aiHandoff, ratingSum, ratingCount int
		firstResponseSeconds                                                    int64
		firstResponseSamples                                                    int64
	}
	for rows.Next() {
		var statDate time.Time
		var started, closed, in, out, aiAnswered, aiHandoff, ratingSum, ratingCount int
		var firstResponseSeconds int64
		var firstResponseSamples int64
		if err := rows.Scan(&statDate, &started, &closed, &in, &out, &aiAnswered, &aiHandoff,
			&firstResponseSeconds, &firstResponseSamples, &ratingSum, &ratingCount); err != nil {
			fail(w, 500, "查询统计失败")
			return
		}
		average := 0.0
		if firstResponseSamples > 0 {
			average = float64(firstResponseSeconds) / float64(firstResponseSamples)
		}
		series = append(series, map[string]any{
			"date": statDate.Format("2006-01-02"), "conversationsStarted": started, "conversationsClosed": closed,
			"messagesIn": in, "messagesOut": out, "aiAnswered": aiAnswered, "aiHandoff": aiHandoff,
			"avgFirstResponseSeconds": average,
		})
		totals.started += started
		totals.closed += closed
		totals.in += in
		totals.out += out
		totals.aiAnswered += aiAnswered
		totals.aiHandoff += aiHandoff
		totals.firstResponseSeconds += firstResponseSeconds
		totals.firstResponseSamples += firstResponseSamples
		totals.ratingSum += ratingSum
		totals.ratingCount += ratingCount
	}

	var openConversations, queued, onlineAgents int
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from conversation
		where tenant_id=$1 and status <> 'RESOLVED'`, p.TenantID).Scan(&openConversations)
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from conversation
		where tenant_id=$1 and assignee_id is null and status <> 'RESOLVED'`, p.TenantID).Scan(&queued)
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from agent_presence ap
		join agent ag on ag.id = ap.agent_id
		where ag.tenant_id=$1 and ap.status = 'ONLINE' and ag.status='ACTIVE'`, p.TenantID).Scan(&onlineAgents)

	leaderboard := make([]map[string]any, 0, 8)
	leaderRows, err := a.db.Query(r.Context(), `
		select ag.id, ag.display_name,
		       count(*) filter (where c.status = 'RESOLVED')::int as resolved,
		       count(*) filter (where c.status <> 'RESOLVED')::int as open,
		       coalesce(avg(case when c.first_response_at is not null
		           then extract(epoch from (c.first_response_at - c.created_at)) end)::int, 0) as avg_first_response,
		       coalesce(avg(r.score)::float8, 0) as avg_rating
		  from agent ag
		  left join conversation c on c.assignee_id = ag.id and c.created_at >= now() - interval '30 days'
		  left join conversation_rating r on r.conversation_id = c.id
		 where ag.tenant_id = $1 and ag.status = 'ACTIVE' and ag.email <> 'bot@relaydesk.local'
		 group by ag.id, ag.display_name
		 order by resolved desc, open asc`, p.TenantID)
	if err == nil {
		defer leaderRows.Close()
		for leaderRows.Next() {
			var id uuid.UUID
			var displayName string
			var resolved, open, avgFirstResponse int
			var avgRating float64
			if err := leaderRows.Scan(&id, &displayName, &resolved, &open, &avgFirstResponse, &avgRating); err != nil {
				break
			}
			leaderboard = append(leaderboard, map[string]any{"agentId": id, "displayName": displayName,
				"resolved": resolved, "open": open, "avgFirstResponseSeconds": avgFirstResponse, "avgRating": avgRating})
		}
	}

	averageFirstResponse := 0.0
	if totals.firstResponseSamples > 0 {
		averageFirstResponse = float64(totals.firstResponseSeconds) / float64(totals.firstResponseSamples)
	}
	averageRating := 0.0
	if totals.ratingCount > 0 {
		averageRating = float64(totals.ratingSum) / float64(totals.ratingCount)
	}
	deflection := 0.0
	if total := totals.aiAnswered + totals.aiHandoff; total > 0 {
		deflection = float64(totals.aiAnswered) / float64(total)
	}
	respond(w, 200, map[string]any{
		"scope":                   "tenant",
		"days":                    days,
		"openConversations":       openConversations,
		"queued":                  queued,
		"onlineAgents":            onlineAgents,
		"conversationsStarted":    totals.started,
		"conversationsClosed":     totals.closed,
		"messagesIn":              totals.in,
		"messagesOut":             totals.out,
		"aiAnswered":              totals.aiAnswered,
		"aiHandoff":               totals.aiHandoff,
		"aiDeflectionRate":        deflection,
		"avgFirstResponseSeconds": averageFirstResponse,
		"avgRating":               averageRating,
		"series":                  series,
		"leaderboard":             leaderboard,
	})
}

// ---------------------------------------------------------------- knowledge base

func (a *API) consoleKnowledgeList(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	search := strings.TrimSpace(r.URL.Query().Get("q"))
	rows, err := a.db.Query(r.Context(), `select id, title, content, question_examples, status, hit_count, updated_at
		  from knowledge_entry
		 where tenant_id = $1 and ($2 = '' or title ilike '%' || $2 || '%' or content ilike '%' || $2 || '%')
		 order by updated_at desc limit 200`, p.TenantID, search)
	if err != nil {
		fail(w, 500, "查询知识库失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 32)
	for rows.Next() {
		var id uuid.UUID
		var title, content, examples, status string
		var hits int64
		var updatedAt time.Time
		if err := rows.Scan(&id, &title, &content, &examples, &status, &hits, &updatedAt); err != nil {
			fail(w, 500, "查询知识库失败")
			return
		}
		items = append(items, map[string]any{"id": id, "title": title, "content": content,
			"questionExamples": examples, "status": status, "hitCount": hits, "updatedAt": updatedAt})
	}
	respond(w, 200, map[string]any{"items": items})
}

func (a *API) consoleKnowledgeCreate(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Title            string `json:"title"`
		Content          string `json:"content"`
		QuestionExamples string `json:"questionExamples"`
		CategoryID       string `json:"categoryId"`
		Status           string `json:"status"`
	}
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.Title) == "" || strings.TrimSpace(in.Content) == "" {
		fail(w, 400, "标题和内容都不能为空")
		return
	}
	status := strings.ToUpper(strings.TrimSpace(in.Status))
	if status != "DISABLED" {
		status = "ACTIVE"
	}
	var categoryID *uuid.UUID
	if in.CategoryID != "" {
		if parsed, err := uuid.Parse(in.CategoryID); err == nil {
			categoryID = &parsed
		}
	}
	id := uuid.New()
	if _, err := a.db.Exec(r.Context(), `insert into knowledge_entry(id, tenant_id, category_id, title, content, question_examples, status)
		values($1,$2,$3,$4,$5,$6,$7)`, id, p.TenantID, categoryID, in.Title, in.Content, in.QuestionExamples, status); err != nil {
		fail(w, 500, "创建知识条目失败")
		return
	}
	respond(w, 201, map[string]any{"id": id})
}

func (a *API) consoleKnowledgeUpdate(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "ID 不合法")
		return
	}
	var in struct {
		Title            string `json:"title"`
		Content          string `json:"content"`
		QuestionExamples string `json:"questionExamples"`
		Status           string `json:"status"`
	}
	if !decode(w, r, &in) {
		return
	}
	status := strings.ToUpper(strings.TrimSpace(in.Status))
	if status != "ACTIVE" && status != "DISABLED" {
		status = ""
	}
	tag, err := a.db.Exec(r.Context(), `update knowledge_entry
		set title = coalesce(nullif($3,''), title),
		    content = coalesce(nullif($4,''), content),
		    question_examples = coalesce(nullif($5,''), question_examples),
		    status = coalesce(nullif($6,''), status),
		    updated_at = now()
		where id=$1 and tenant_id=$2`, id, p.TenantID, in.Title, in.Content, in.QuestionExamples, status)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "知识条目不存在")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) consoleKnowledgeDelete(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "ID 不合法")
		return
	}
	tag, err := a.db.Exec(r.Context(), `delete from knowledge_entry where id=$1 and tenant_id=$2`, id, p.TenantID)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "知识条目不存在")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

// consoleKnowledgeSearch lets an operator preview exactly what the bot will see.
func (a *API) consoleKnowledgeSearch(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Question string `json:"question"`
	}
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.Question) == "" {
		fail(w, 400, "请输入测试问题")
		return
	}
	reply, err := a.ai.Answer(r.Context(), p.TenantID, in.Question)
	if err != nil && reply.Reason != ai.ReasonProviderFail {
		fail(w, 500, "AI 调用失败："+err.Error())
		return
	}
	respond(w, 200, map[string]any{
		"answer":   reply.Content,
		"score":    reply.Score,
		"provider": reply.Provider,
		"handoff":  reply.Handoff,
		"reason":   string(reply.Reason),
		"sources":  reply.Sources,
	})
}

// consoleKnowledgePreview runs retrieval only. It answers "would the knowledge
// base have anything for this question?" without spending a model call, which is
// the first thing to check when a tenant reports bad answers.
func (a *API) consoleKnowledgePreview(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Question string `json:"question"`
	}
	if !decode(w, r, &in) {
		return
	}
	question := strings.TrimSpace(in.Question)
	if question == "" {
		fail(w, 400, "请输入检索内容")
		return
	}
	hits, err := a.ai.Retrieve(r.Context(), p.TenantID, question)
	if err != nil {
		a.logger.Error("knowledge retrieval failed", "error", err, "tenant", p.TenantID)
		fail(w, 500, "知识库检索失败")
		return
	}
	respond(w, 200, map[string]any{
		"items": hits, "count": len(hits), "aiAvailable": a.ai.Available(),
		"provider": a.ai.ProviderName(), "threshold": a.cfg.AI.ConfidenceThreshold,
	})
}
