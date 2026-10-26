package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/tongyu/tongyu/internal/ai"
	"github.com/tongyu/tongyu/internal/auth"
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
		var own bool
		if err := a.db.QueryRow(r.Context(), `select exists(select 1 from inbox where id=$1 and tenant_id=$2)`, parsed, p.TenantID).Scan(&own); err != nil || !own {
			fail(w, 400, "入口不存在或不属于当前企业")
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
	a.assetsChanged(r, p)
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
	a.assetsChanged(r, p)
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
	a.assetsChanged(r, p)
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
		 where ag.tenant_id = $1 and ag.status = 'ACTIVE' and ag.email <> 'bot@tongyu.local'
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
		 where ag.tenant_id = $1 and ag.status = 'ACTIVE' and ag.email <> 'bot@tongyu.local'
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
	rows, err := a.db.Query(r.Context(), `select id, title, content, question_examples, status, hit_count, updated_at,coalesce(category_id::text,'')
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
		var title, content, examples, status, category string
		var hits int64
		var updatedAt time.Time
		if err := rows.Scan(&id, &title, &content, &examples, &status, &hits, &updatedAt, &category); err != nil {
			fail(w, 500, "查询知识库失败")
			return
		}
		items = append(items, map[string]any{"id": id, "title": title, "content": content,
			"questionExamples": examples, "status": status, "hitCount": hits, "updatedAt": updatedAt, "categoryId": category})
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
		SourceQuestion   string `json:"sourceQuestion"`
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
	categoryID, ok := a.knowledgeCategory(w, r, p, in.CategoryID)
	if !ok {
		return
	}
	id := uuid.New()
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "创建知识条目失败")
		return
	}
	defer tx.Rollback(r.Context())
	if in.SourceQuestion != "" {
		var exists bool
		err := tx.QueryRow(r.Context(), `select exists(select 1 from ai_interaction i join message m on m.id=i.question_message_id
		 where i.tenant_id=$1 and m.content=$2 and m.deleted_at is null and i.reason in ('NO_KNOWLEDGE_BASE','LOW_CONFIDENCE'))`, p.TenantID, in.SourceQuestion).Scan(&exists)
		if err != nil || !exists || status != "ACTIVE" {
			fail(w, 400, "原问题不存在或知识尚未启用")
			return
		}
	}
	if _, err := tx.Exec(r.Context(), `insert into knowledge_entry(id, tenant_id, category_id, title, content, question_examples, status)
		values($1,$2,$3,$4,$5,$6,$7)`, id, p.TenantID, categoryID, in.Title, in.Content, in.QuestionExamples, status); err != nil {
		if isUniqueViolation(err) {
			fail(w, 409, "该标题已存在，请编辑原条目")
			return
		}
		fail(w, 500, "创建知识条目失败")
		return
	}
	if in.SourceQuestion != "" {
		_, err = tx.Exec(r.Context(), `insert into knowledge_gap_resolution(tenant_id,question_hash,question,knowledge_id,resolved_by)
		 values($1,md5($2),$2,$3,$4) on conflict(tenant_id,question_hash) do update set knowledge_id=excluded.knowledge_id,resolved_by=excluded.resolved_by,resolved_at=now()`, p.TenantID, in.SourceQuestion, id, p.AgentID)
		if err != nil {
			fail(w, 500, "关联原问题失败，知识未保存，请重试")
			return
		}
	}
	if err := tx.Commit(r.Context()); err != nil {
		fail(w, 500, "保存知识失败，请重试")
		return
	}
	a.asyncEmbedKnowledgeEntry(id, in.Title, in.Content)
	respond(w, 201, map[string]any{"id": id})
}

func (a *API) consoleKnowledgeUpdate(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "ID 不合法")
		return
	}
	var in struct {
		CategoryID       *string `json:"categoryId"`
		Title            string  `json:"title"`
		Content          string  `json:"content"`
		QuestionExamples *string `json:"questionExamples"`
		Status           string  `json:"status"`
	}
	if !decode(w, r, &in) {
		return
	}
	status := strings.ToUpper(strings.TrimSpace(in.Status))
	if status != "ACTIVE" && status != "DISABLED" {
		if status != "" {
			fail(w, 400, "状态不合法")
			return
		}
	}
	var category *uuid.UUID
	if in.CategoryID != nil {
		var ok bool
		category, ok = a.knowledgeCategory(w, r, p, *in.CategoryID)
		if !ok {
			return
		}
	}
	tag, err := a.db.Exec(r.Context(), `update knowledge_entry
		set title = coalesce(nullif($3,''), title),
		    content = coalesce(nullif($4,''), content),
		    question_examples = coalesce($5, question_examples),
		    status = coalesce(nullif($6,''), status),category_id=case when $7 then $8 else category_id end,
		    updated_at = now()
		where id=$1 and tenant_id=$2`, id, p.TenantID, in.Title, in.Content, in.QuestionExamples, status, in.CategoryID != nil, category)
	if isUniqueViolation(err) {
		fail(w, 409, "该标题已存在，请修改后重试")
		return
	}
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "知识条目不存在")
		return
	}
	a.asyncEmbedKnowledgeEntry(id, in.Title, in.Content)
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
	finish, quotaErr := a.reserveAIQuota(r.Context(), p.TenantID)
	if quotaErr != nil {
		if !failServiceError(w, quotaErr) {
			fail(w, 503, "暂时无法读取AI额度")
		}
		return
	}
	success := false
	defer func() { finish(success) }()
	reply, err := a.ai.Answer(r.Context(), p.TenantID, in.Question)
	success = err == nil && !reply.Handoff && strings.TrimSpace(reply.Content) != ""
	if err != nil && reply.Reason != ai.ReasonProviderFail {
		fail(w, 500, "AI 调用失败："+err.Error())
		return
	}
	respond(w, 200, map[string]any{
		"answer":   reply.Content,
		"score":    reply.Score,
		"provider": "",
		"handoff":  reply.Handoff,
		"reason":   string(reply.Reason),
		// 测试台需要本次检索的正文；自动回复和开放 API 仍保留原有标题列表协议。
		"sources": reply.SourceDetails,
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
		"threshold": a.cfg.AI.ConfidenceThreshold,
	})
}

// asyncEmbedKnowledgeEntry queues a knowledge entry for embedding on a background
// goroutine so the create/update response is not blocked by the network call.
func (a *API) asyncEmbedKnowledgeEntry(id uuid.UUID, title, content string) {
	if !a.ai.HasEmbeddings() {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if _, err := a.ai.EmbedEntry(ctx, id, title, content); err != nil {
			a.logger.Error("knowledge embedding failed", "id", id, "error", err)
		}
	}()
}

// initTools registers built-in tool handlers that the AI assistant can invoke.
// Each tool is a named function the model may call; the server executes it and
// feeds the text result back to the model so it can reason over real data.
func (a *API) initTools() []ai.Tool {
	return []ai.Tool{
		{
			Name:        "lookup_order",
			Description: "查询订单状态和物流信息。需传入 orderId（订单号）。",
			Parameters:  json.RawMessage(`{"type":"object","properties":{"orderId":{"type":"string","description":"订单编号"}},"required":["orderId"]}`),
			Handler:     a.toolLookupOrder,
		},
		{
			Name:        "query_product",
			Description: "查询产品信息，包括价格、库存、规格。需传入 productName 或 productId。",
			Parameters:  json.RawMessage(`{"type":"object","properties":{"productName":{"type":"string","description":"产品名称或关键词"},"productId":{"type":"string","description":"产品 ID"}},"required":["productName","productId"]}`),
			Handler:     a.toolQueryProduct,
		},
		{
			Name:        "get_refund_policy",
			Description: "查询退换货政策和流程说明。",
			Parameters:  json.RawMessage(`{"type":"object","properties":{}}`),
			Handler:     a.toolGetRefundPolicy,
		},
	}
}

func (a *API) toolLookupOrder(ctx context.Context, args map[string]any) (string, error) {
	orderID, _ := args["orderId"].(string)
	if orderID == "" {
		return "", fmt.Errorf("orderId 不能为空")
	}
	// TODO: replace with real DB query against order table
	tenantID := tenantIDFromContext(ctx)
	if tenantID == uuid.Nil {
		return "", fmt.Errorf("无法获取租户信息")
	}
	var status, tracking string
	err := a.db.QueryRow(ctx, `SELECT status, tracking_number FROM orders WHERE order_id=$1 AND tenant_id=$2`, orderID, tenantID).Scan(&status, &tracking)
	if err != nil {
		return "", fmt.Errorf("订单 %s 不存在或无权限查询", orderID)
	}
	return fmt.Sprintf("订单 %s 状态：%s，物流单号：%s", orderID, status, tracking), nil
}

func (a *API) toolQueryProduct(ctx context.Context, args map[string]any) (string, error) {
	name, _ := args["productName"].(string)
	id, _ := args["productId"].(string)
	if name == "" && id == "" {
		return "", fmt.Errorf("productName 或 productId 至少提供一个")
	}
	// TODO: replace with real DB query against product table
	return fmt.Sprintf("产品 %s 暂无实时库存数据，请咨询人工客服。", name), nil
}

func (a *API) toolGetRefundPolicy(ctx context.Context, args map[string]any) (string, error) {
	return "退换货政策：7 天无理由退换，商品需保持原包装完好。运费险覆盖首程运费，退货运费由买家承担。特殊情况请联系人工客服协商。", nil
}

type tenantContextKey struct{}

func withTenantID(ctx context.Context, id uuid.UUID) context.Context {
	return context.WithValue(ctx, tenantContextKey{}, id)
}

func tenantIDFromContext(ctx context.Context) uuid.UUID {
	if id, ok := ctx.Value(tenantContextKey{}).(uuid.UUID); ok {
		return id
	}
	return uuid.Nil
}

func (a *API) currentTenantID(ctx context.Context) uuid.UUID {
	return tenantIDFromContext(ctx)
}
