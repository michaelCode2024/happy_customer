package server

import (
	"errors"
	"html"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/relaydesk/relaydesk/internal/auth"
)

// registerAdmin is the tenant administration API. Everything here is reachable
// by OWNER and ADMIN only: inboxes, agents, tags, webhooks and API keys.
func (a *API) registerAdmin(mux *http.ServeMux) {
	manage := []string{auth.RoleOwner, auth.RoleAdmin}

	// Tenant
	mux.HandleFunc("GET /api/v1/admin/tenant", a.requireRole(manage, a.adminTenant))
	mux.HandleFunc("PATCH /api/v1/admin/tenant", a.requireRole(manage, a.adminUpdateTenant))
	mux.HandleFunc("GET /api/v1/admin/subscription", a.requireRole(manage, a.adminSubscription))
	mux.HandleFunc("GET /api/v1/admin/audit", a.requireRole(manage, a.adminAudit))

	// Inboxes
	mux.HandleFunc("GET /api/v1/admin/inboxes", a.requireRole(manage, a.adminInboxes))
	mux.HandleFunc("POST /api/v1/admin/inboxes", a.requireRole(manage, a.adminCreateInbox))
	mux.HandleFunc("GET /api/v1/admin/inboxes/{id}", a.requireRole(manage, a.adminInbox))
	mux.HandleFunc("PATCH /api/v1/admin/inboxes/{id}", a.requireRole(manage, a.adminUpdateInbox))
	mux.HandleFunc("DELETE /api/v1/admin/inboxes/{id}", a.requireRole(manage, a.adminDeleteInbox))
	mux.HandleFunc("PATCH /api/v1/admin/inboxes/{id}/ai", a.requireRole(manage, a.adminInboxAI))
	mux.HandleFunc("PUT /api/v1/admin/inboxes/{id}/routing", a.requireRole(manage, a.adminInboxRouting))
	mux.HandleFunc("GET /api/v1/admin/inboxes/{id}/snippet", a.requireRole(manage, a.adminSnippet))

	// Agents
	mux.HandleFunc("GET /api/v1/admin/agents", a.requireRole(manage, a.adminAgents))
	mux.HandleFunc("POST /api/v1/admin/agents", a.requireRole(manage, a.adminCreateAgent))
	mux.HandleFunc("PATCH /api/v1/admin/agents/{id}", a.requireRole(manage, a.adminUpdateAgent))
	mux.HandleFunc("DELETE /api/v1/admin/agents/{id}", a.requireRole(manage, a.adminDeleteAgent))
	mux.HandleFunc("POST /api/v1/admin/agents/{id}/password", a.requireRole(manage, a.adminResetPassword))
	mux.HandleFunc("PUT /api/v1/admin/agents/{id}/inboxes", a.requireRole(manage, a.adminAgentInboxes))

	// Tags and canned responses are shared with the console API, but admins may
	// also rename and recolour tags here.
	mux.HandleFunc("POST /api/v1/admin/tags", a.requireRole(manage, a.adminCreateTag))
	mux.HandleFunc("PATCH /api/v1/admin/tags/{id}", a.requireRole(manage, a.adminUpdateTag))
	mux.HandleFunc("DELETE /api/v1/admin/tags/{id}", a.requireRole(manage, a.adminDeleteTag))

	// Webhooks
	mux.HandleFunc("GET /api/v1/admin/webhooks", a.requireRole(manage, a.adminWebhooks))
	mux.HandleFunc("POST /api/v1/admin/webhooks", a.requireRole(manage, a.adminCreateWebhook))
	mux.HandleFunc("PATCH /api/v1/admin/webhooks/{id}", a.requireRole(manage, a.adminUpdateWebhook))
	mux.HandleFunc("DELETE /api/v1/admin/webhooks/{id}", a.requireRole(manage, a.adminDeleteWebhook))
	mux.HandleFunc("GET /api/v1/admin/webhooks/{id}/deliveries", a.requireRole(manage, a.adminWebhookDeliveries))
	mux.HandleFunc("POST /api/v1/admin/webhooks/{id}/test", a.requireRole(manage, a.adminTestWebhook))

	// API keys for the open API
	mux.HandleFunc("GET /api/v1/admin/api-keys", a.requireRole(manage, a.adminAPIKeys))
	mux.HandleFunc("POST /api/v1/admin/api-keys", a.requireRole(manage, a.adminCreateAPIKey))
	mux.HandleFunc("DELETE /api/v1/admin/api-keys/{id}", a.requireRole(manage, a.adminRevokeAPIKey))

	// Knowledge categories
	mux.HandleFunc("GET /api/v1/admin/knowledge-categories", a.requireRole(manage, a.adminKnowledgeCategories))
	mux.HandleFunc("POST /api/v1/admin/knowledge-categories", a.requireRole(manage, a.adminCreateKnowledgeCategory))
	mux.HandleFunc("DELETE /api/v1/admin/knowledge-categories/{id}", a.requireRole(manage, a.adminDeleteKnowledgeCategory))

	// Knowledge entries: the corpus the AI answers from.
	mux.HandleFunc("GET /api/v1/admin/knowledge", a.requireRole(manage, a.adminKnowledgeEntries))
	mux.HandleFunc("POST /api/v1/admin/knowledge", a.requireRole(manage, a.adminCreateKnowledgeEntry))
	mux.HandleFunc("GET /api/v1/admin/knowledge/{id}", a.requireRole(manage, a.adminKnowledgeEntry))
	mux.HandleFunc("PATCH /api/v1/admin/knowledge/{id}", a.requireRole(manage, a.adminUpdateKnowledgeEntry))
	mux.HandleFunc("DELETE /api/v1/admin/knowledge/{id}", a.requireRole(manage, a.adminDeleteKnowledgeEntry))
	mux.HandleFunc("POST /api/v1/admin/knowledge/import", a.requireRole(manage, a.adminImportKnowledge))
	mux.HandleFunc("GET /api/v1/admin/knowledge-gaps", a.requireRole(manage, a.adminKnowledgeGaps))

	// Platform operations console live socket: tenant suspension, plan changes
	// and instance-wide counters.
	mux.HandleFunc("GET /ws/platform", a.platformSocket)
}

// ---------------------------------------------------------------- tenant

func (a *API) adminTenant(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var name, slug, status string
	var createdAt time.Time
	var settings []byte
	err := a.db.QueryRow(r.Context(), `select name, slug, status, coalesce(settings,'{}'::jsonb), created_at
		from tenant where id = $1`, p.TenantID).Scan(&name, &slug, &status, &settings, &createdAt)
	if err != nil {
		fail(w, 404, "企业不存在")
		return
	}
	var agents, inboxes, conversations int
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from agent where tenant_id=$1 and email <> 'bot@relaydesk.local'`, p.TenantID).Scan(&agents)
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from inbox where tenant_id=$1`, p.TenantID).Scan(&inboxes)
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from conversation where tenant_id=$1`, p.TenantID).Scan(&conversations)
	respond(w, 200, map[string]any{
		"id": p.TenantID, "name": name, "slug": slug, "status": status,
		"settings": rawJSON(settings), "createdAt": createdAt,
		"agentCount": agents, "inboxCount": inboxes, "conversationCount": conversations,
	})
}

func (a *API) adminUpdateTenant(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Name     string         `json:"name"`
		Settings map[string]any `json:"settings"`
	}
	if !decode(w, r, &in) {
		return
	}
	settings, _ := jsonBytes(orEmpty(in.Settings))
	if _, err := a.db.Exec(r.Context(), `update tenant
		set name = coalesce(nullif($2,''), name),
		    settings = settings || $3::jsonb,
		    updated_at = now()
		where id = $1`, p.TenantID, in.Name, settings); err != nil {
		fail(w, 500, "更新企业信息失败")
		return
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "tenant.update", "tenant", p.TenantID, in.Settings)
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) adminSubscription(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var plan, status string
	var seatLimit, messageLimit int
	var trialEnds *time.Time
	var updatedAt time.Time
	err := a.db.QueryRow(r.Context(), `select plan, status, seat_limit, monthly_message_limit, trial_ends_at, updated_at
		from tenant_subscription where tenant_id = $1`, p.TenantID).
		Scan(&plan, &status, &seatLimit, &messageLimit, &trialEnds, &updatedAt)
	if err != nil {
		respond(w, 200, map[string]any{"plan": "TRIAL", "status": "ACTIVE", "seatLimit": 3, "monthlyMessageLimit": 5000})
		return
	}
	var usedMessages, usedSeats int
	_ = a.db.QueryRow(r.Context(), `select coalesce(sum(messages_in + messages_out),0)::int from tenant_daily_stat
		where tenant_id = $1 and stat_date >= date_trunc('month', current_date)`, p.TenantID).Scan(&usedMessages)
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from agent where tenant_id=$1 and status='ACTIVE' and email <> 'bot@relaydesk.local'`, p.TenantID).Scan(&usedSeats)
	respond(w, 200, map[string]any{
		"plan": plan, "status": status, "seatLimit": seatLimit, "monthlyMessageLimit": messageLimit,
		"trialEndsAt": trialEnds, "updatedAt": updatedAt,
		"usedSeats": usedSeats, "usedMessages": usedMessages,
		"monthStart": time.Now().UTC().Format("2006-01"),
	})
}

func (a *API) adminAudit(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	limit := queryInt(r, "limit", 100)
	if limit > 500 {
		limit = 500
	}
	rows, err := a.db.Query(r.Context(), `select id, actor_type, coalesce(actor_id, '00000000-0000-0000-0000-000000000000'::uuid),
			action, coalesce(target_type,''), coalesce(target_id, '00000000-0000-0000-0000-000000000000'::uuid), detail, created_at
		from audit_log where tenant_id = $1 order by created_at desc limit $2`, p.TenantID, limit)
	if err != nil {
		fail(w, 500, "查询审计日志失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, limit)
	for rows.Next() {
		var id, actorID, targetID uuid.UUID
		var actorType, action, targetType string
		var detail []byte
		var createdAt time.Time
		if err := rows.Scan(&id, &actorType, &actorID, &action, &targetType, &targetID, &detail, &createdAt); err != nil {
			fail(w, 500, "查询审计日志失败")
			return
		}
		item := map[string]any{"id": id, "actorType": actorType, "action": action,
			"targetType": targetType, "detail": rawJSON(detail), "createdAt": createdAt}
		if actorID != uuid.Nil {
			item["actorId"] = actorID
		}
		if targetID != uuid.Nil {
			item["targetId"] = targetID
		}
		items = append(items, item)
	}
	respond(w, 200, map[string]any{"items": items})
}

// ---------------------------------------------------------------- inboxes

func (a *API) adminInboxes(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	rows, err := a.db.Query(r.Context(), `
		select i.id, i.name, i.public_key, i.status, i.auto_assign, i.updated_at,
		       coalesce(i.allowed_domains, '{}'), coalesce(i.welcome_message,''), coalesce(i.offline_message,''),
		       coalesce(s.enabled,false), coalesce(s.confidence_threshold, 0.35),
		       (select count(*)::int from agent_inbox ai where ai.inbox_id = i.id),
		       (select count(*)::int from conversation c where c.inbox_id = i.id and c.status <> 'RESOLVED')
		  from inbox i
		  left join ai_setting s on s.inbox_id = i.id
		 where i.tenant_id = $1
		 order by i.created_at`, p.TenantID)
	if err != nil {
		fail(w, 500, "查询客服入口失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 8)
	for rows.Next() {
		var id uuid.UUID
		var name, publicKey, status string
		var autoAssign, aiEnabled bool
		var updatedAt time.Time
		var domains []string
		var welcome, offline string
		var threshold float64
		var agentCount, openCount int
		if err := rows.Scan(&id, &name, &publicKey, &status, &autoAssign, &updatedAt, &domains, &welcome, &offline,
			&aiEnabled, &threshold, &agentCount, &openCount); err != nil {
			fail(w, 500, "查询客服入口失败")
			return
		}
		items = append(items, map[string]any{
			"id": id, "name": name, "publicKey": publicKey, "status": status, "autoAssign": autoAssign,
			"allowedDomains": domains, "welcomeMessage": welcome, "offlineMessage": offline,
			"aiEnabled": aiEnabled, "confidenceThreshold": threshold,
			"agentCount": agentCount, "openConversations": openCount, "updatedAt": updatedAt,
		})
	}
	respond(w, 200, map[string]any{"items": items})
}

func (a *API) adminInbox(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.tenantInbox(w, r, p)
	if !ok {
		return
	}
	var name, publicKey, status string
	var autoAssign bool
	var domains []string
	var welcome, offline *string
	var createdAt, updatedAt time.Time
	var aiEnabled bool
	var handoff string
	var threshold float64
	err := a.db.QueryRow(r.Context(), `
		select i.name, i.public_key, i.status, i.auto_assign, i.allowed_domains, i.welcome_message,
		       i.offline_message, i.created_at, i.updated_at,
		       coalesce(s.enabled,false), coalesce(s.handoff_message,'正在为你转接人工客服，请稍候。'),
		       coalesce(s.confidence_threshold, 0.35)
		  from inbox i left join ai_setting s on s.inbox_id = i.id
		 where i.id = $1 and i.tenant_id = $2`, id, p.TenantID).
		Scan(&name, &publicKey, &status, &autoAssign, &domains, &welcome, &offline, &createdAt, &updatedAt,
			&aiEnabled, &handoff, &threshold)
	if err != nil {
		fail(w, 404, "客服入口不存在")
		return
	}
	var strategy, fixedAgent string
	var maxConcurrent int
	_ = a.db.QueryRow(r.Context(), `select strategy, coalesce(fixed_agent_id::text,''), max_concurrent
		from routing_rule where inbox_id = $1 and tenant_id = $2`, id, p.TenantID).
		Scan(&strategy, &fixedAgent, &maxConcurrent)
	respond(w, 200, map[string]any{
		"id": id, "name": name, "publicKey": publicKey, "status": status, "autoAssign": autoAssign,
		"allowedDomains": domains, "welcomeMessage": welcome, "offlineMessage": offline,
		"aiEnabled": aiEnabled, "handoffMessage": handoff, "confidenceThreshold": threshold,
		"routing":     map[string]any{"strategy": strategy, "fixedAgentId": fixedAgent, "maxConcurrent": maxConcurrent},
		"createdAt":   createdAt,
		"updatedAt":   updatedAt,
		"publicUrl":   a.cfg.PublicBaseURL,
		"socketPath":  "/ws/widget",
		"installPath": a.cfg.PublicBaseURL + "/widget.js",
	})
}

func (a *API) adminCreateInbox(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Name           string   `json:"name"`
		PublicKey      string   `json:"publicKey"`
		AllowedDomains []string `json:"allowedDomains"`
		WelcomeMessage string   `json:"welcomeMessage"`
		OfflineMessage string   `json:"offlineMessage"`
		AutoAssign     *bool    `json:"autoAssign"`
	}
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.Name) == "" {
		fail(w, 400, "客服入口名称不能为空")
		return
	}
	publicKey := strings.TrimSpace(in.PublicKey)
	if publicKey == "" {
		publicKey = "inbox_" + strings.ReplaceAll(uuid.NewString(), "-", "")[:16]
	}
	if len(publicKey) < 6 || len(publicKey) > 80 {
		fail(w, 400, "publicKey 长度需要在 6 到 80 之间")
		return
	}
	autoAssign := true
	if in.AutoAssign != nil {
		autoAssign = *in.AutoAssign
	}
	id := uuid.New()
	if _, err := a.db.Exec(r.Context(), `insert into inbox(id, tenant_id, name, public_key, status, auto_assign,
			allowed_domains, welcome_message, offline_message)
		values($1,$2,$3,$4,'ACTIVE',$5,$6,$7,$8)`,
		id, p.TenantID, in.Name, publicKey, autoAssign, in.AllowedDomains,
		nullable(in.WelcomeMessage), nullable(in.OfflineMessage)); err != nil {
		if isUniqueViolation(err) {
			failCode(w, 409, "PUBLIC_KEY_TAKEN", "该 publicKey 已被占用")
			return
		}
		fail(w, 500, "创建客服入口失败")
		return
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "inbox.create", "inbox", id, map[string]any{"name": in.Name})
	respond(w, 201, map[string]any{"id": id, "publicKey": publicKey})
}

func (a *API) adminUpdateInbox(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.tenantInbox(w, r, p)
	if !ok {
		return
	}
	var in struct {
		Name           string   `json:"name"`
		Status         string   `json:"status"`
		AllowedDomains []string `json:"allowedDomains"`
		WelcomeMessage *string  `json:"welcomeMessage"`
		OfflineMessage *string  `json:"offlineMessage"`
		AutoAssign     *bool    `json:"autoAssign"`
	}
	if !decode(w, r, &in) {
		return
	}
	status := strings.ToUpper(strings.TrimSpace(in.Status))
	if status != "" && status != "ACTIVE" && status != "DISABLED" {
		fail(w, 400, "status 只能是 ACTIVE 或 DISABLED")
		return
	}
	if _, err := a.db.Exec(r.Context(), `update inbox
		set name = coalesce(nullif($3,''), name),
		    status = coalesce(nullif($4,''), status),
		    allowed_domains = coalesce($5, allowed_domains),
		    welcome_message = coalesce($6, welcome_message),
		    offline_message = coalesce($7, offline_message),
		    auto_assign = coalesce($8, auto_assign),
		    updated_at = now()
		where id = $1 and tenant_id = $2`,
		id, p.TenantID, in.Name, status, in.AllowedDomains,
		nullableIfSet(in.WelcomeMessage), nullableIfSet(in.OfflineMessage), in.AutoAssign); err != nil {
		fail(w, 500, "更新客服入口失败")
		return
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "inbox.update", "inbox", id, map[string]any{"status": status})
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) adminDeleteInbox(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.tenantInbox(w, r, p)
	if !ok {
		return
	}
	var open int
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from conversation where inbox_id=$1 and status <> 'RESOLVED'`, id).Scan(&open)
	if open > 0 {
		failCode(w, 409, "INBOX_HAS_OPEN_CONVERSATIONS", "该入口还有未结束的会话，请先处理或关闭")
		return
	}
	if _, err := a.db.Exec(r.Context(), `delete from inbox where id=$1 and tenant_id=$2`, id, p.TenantID); err != nil {
		fail(w, 500, "删除客服入口失败")
		return
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "inbox.delete", "inbox", id, nil)
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) adminInboxAI(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.tenantInbox(w, r, p)
	if !ok {
		return
	}
	var in struct {
		Enabled             *bool   `json:"enabled"`
		Greeting            *string `json:"greeting"`
		HandoffMessage      *string `json:"handoffMessage"`
		ConfidenceThreshold float64 `json:"confidenceThreshold"`
	}
	if !decode(w, r, &in) {
		return
	}
	threshold := in.ConfidenceThreshold
	if threshold <= 0 || threshold > 1 {
		threshold = a.cfg.AI.ConfidenceThreshold
	}
	if _, err := a.db.Exec(r.Context(), `
		insert into ai_setting(inbox_id, tenant_id, enabled, greeting, handoff_message, confidence_threshold, updated_at)
		values($1,$2,coalesce($3,false),$4,coalesce($5,'正在为你转接人工客服，请稍候。'),$6, now())
		on conflict (inbox_id) do update set
			enabled = coalesce($3, ai_setting.enabled),
			greeting = coalesce($4, ai_setting.greeting),
			handoff_message = coalesce($5, ai_setting.handoff_message),
			confidence_threshold = $6,
			updated_at = now()`,
		id, p.TenantID, in.Enabled, nullableIfSet(in.Greeting), nullableIfSet(in.HandoffMessage), threshold); err != nil {
		fail(w, 500, "更新 AI 设置失败")
		return
	}
	respond(w, 200, map[string]any{"status": "OK", "providerAvailable": a.ai.Available(), "provider": a.ai.ProviderName()})
}

func (a *API) adminInboxRouting(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.tenantInbox(w, r, p)
	if !ok {
		return
	}
	var in struct {
		Strategy      string         `json:"strategy"`
		FixedAgentID  string         `json:"fixedAgentId"`
		MaxConcurrent int            `json:"maxConcurrent"`
		WorkingHours  map[string]any `json:"workingHours"`
		Enabled       *bool          `json:"enabled"`
	}
	if !decode(w, r, &in) {
		return
	}
	strategy := strings.ToUpper(strings.TrimSpace(in.Strategy))
	switch strategy {
	case "ROUND_ROBIN", "LOAD_BALANCED", "FIXED":
	default:
		fail(w, 400, "strategy 只能是 ROUND_ROBIN、LOAD_BALANCED 或 FIXED")
		return
	}
	var fixed *uuid.UUID
	if in.FixedAgentID != "" {
		parsed, err := uuid.Parse(in.FixedAgentID)
		if err != nil {
			fail(w, 400, "fixedAgentId 不合法")
			return
		}
		var sameTenant bool
		if a.db.QueryRow(r.Context(), `select tenant_id = $2 from agent where id = $1`, parsed, p.TenantID).Scan(&sameTenant) != nil || !sameTenant {
			fail(w, 404, "目标坐席不存在")
			return
		}
		fixed = &parsed
	}
	if strategy == "FIXED" && fixed == nil {
		fail(w, 400, "FIXED 策略必须指定 fixedAgentId")
		return
	}
	if in.MaxConcurrent < 1 || in.MaxConcurrent > 100 {
		in.MaxConcurrent = 5
	}
	enabled := true
	if in.Enabled != nil {
		enabled = *in.Enabled
	}
	hours, _ := jsonBytes(orEmpty(in.WorkingHours))
	// One rule per inbox: replace instead of accumulating duplicates.
	if _, err := a.db.Exec(r.Context(), `delete from routing_rule where inbox_id = $1 and tenant_id = $2`, id, p.TenantID); err != nil {
		fail(w, 500, "保存分配规则失败")
		return
	}
	if _, err := a.db.Exec(r.Context(), `insert into routing_rule(id, tenant_id, inbox_id, strategy, fixed_agent_id, working_hours, max_concurrent, enabled)
		values($1,$2,$3,$4,$5,$6,$7,$8)`,
		uuid.New(), p.TenantID, id, strategy, fixed, hours, in.MaxConcurrent, enabled); err != nil {
		fail(w, 500, "保存分配规则失败")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

// adminSnippet returns copy-paste installation code for the tenant website.
func (a *API) adminSnippet(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.tenantInbox(w, r, p)
	if !ok {
		return
	}
	var publicKey string
	if a.db.QueryRow(r.Context(), `select public_key from inbox where id=$1 and tenant_id=$2`, id, p.TenantID).
		Scan(&publicKey) != nil {
		fail(w, 404, "客服入口不存在")
		return
	}
	base := a.cfg.PublicBaseURL
	h5URL := base + "/h5/" + url.PathEscape(publicKey)
	snippet := "<script defer src=\"" + html.EscapeString(base) + "/widget.js\" data-endpoint=\"" +
		html.EscapeString(base) + "\" data-inbox-key=\"" + html.EscapeString(publicKey) + "\"></script>"
	// 宿主项目用 iframe 嵌 H5：宽高由父页控制；parentOrigin 限制 postMessage 目标。
	iframeTag := `<iframe src="` + html.EscapeString(h5URL) + `?parentOrigin=*"` +
		` title="连语客服" style="border:0;width:100%;height:100%;min-height:520px" allow="microphone;clipboard-write"></iframe>`
	respond(w, 200, map[string]any{
		"inboxKey":   publicKey,
		"script":     snippet,
		"scriptUrl":  base + "/widget.js",
		"iframe":     h5URL,
		"iframeHtml": iframeTag,
		"openApiBase": base + "/api/v1/open",
		"hostNotes": []string{
			"网站脚本：把 script 贴进页面即可",
			"业务系统 iframe：用 iframeHtml，或自行指向 iframe URL 并监听 window.message（source=relaydesk）",
			"服务端对接：创建 API Key 后以 X-RelayDesk-Key 调用 openApiBase",
		},
	})
}

// ---------------------------------------------------------------- agents

func (a *API) adminAgents(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	rows, err := a.db.Query(r.Context(), `
		select ag.id, ag.email, ag.display_name, ag.role, ag.status, ag.max_concurrent, ag.updated_at,
		       coalesce(ap.status,'OFFLINE'),
		       coalesce(array_agg(ai.inbox_id::text) filter (where ai.inbox_id is not null), '{}'),
		       (select count(*)::int from conversation c where c.assignee_id = ag.id and c.status <> 'RESOLVED')
		  from agent ag
		  left join agent_presence ap on ap.agent_id = ag.id
		  left join agent_inbox ai on ai.agent_id = ag.id
		 where ag.tenant_id = $1 and ag.email <> 'bot@relaydesk.local'
		 group by ag.id, ap.status
		 order by ag.created_at`, p.TenantID)
	if err != nil {
		fail(w, 500, "查询坐席失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 16)
	for rows.Next() {
		var id uuid.UUID
		var email, displayName, role, status, presence string
		var maxConcurrent, open int
		var updatedAt time.Time
		var inboxes []string
		if err := rows.Scan(&id, &email, &displayName, &role, &status, &maxConcurrent, &updatedAt,
			&presence, &inboxes, &open); err != nil {
			fail(w, 500, "查询坐席失败")
			return
		}
		items = append(items, map[string]any{"id": id, "email": email, "displayName": displayName,
			"role": role, "status": status, "presence": presence, "maxConcurrent": maxConcurrent,
			"inboxIds": inboxes, "openConversations": open, "updatedAt": updatedAt})
	}
	respond(w, 200, map[string]any{"items": items})
}

func (a *API) adminCreateAgent(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Email         string   `json:"email"`
		DisplayName   string   `json:"displayName"`
		Password      string   `json:"password"`
		Role          string   `json:"role"`
		MaxConcurrent int      `json:"maxConcurrent"`
		InboxIDs      []string `json:"inboxIds"`
	}
	if !decode(w, r, &in) {
		return
	}
	email := strings.ToLower(strings.TrimSpace(in.Email))
	if !strings.Contains(email, "@") || len(email) > 200 {
		fail(w, 400, "邮箱格式不正确")
		return
	}
	if strings.TrimSpace(in.DisplayName) == "" {
		fail(w, 400, "坐席名称不能为空")
		return
	}
	role := strings.ToUpper(strings.TrimSpace(in.Role))
	if role == "" {
		role = auth.RoleAgent
	}
	if !auth.ValidRole(role) {
		fail(w, 400, "role 只能是 OWNER、ADMIN、SUPERVISOR 或 AGENT")
		return
	}
	if role == auth.RoleOwner && p.Role != auth.RoleOwner {
		failCode(w, 403, "OWNER_REQUIRED", "只有企业所有者可以创建所有者账号")
		return
	}
	password := in.Password
	if password == "" {
		// Convenience for onboarding: generate a random password and return it once.
		var err error
		password, _, err = auth.NewOpaqueToken()
		if err != nil {
			fail(w, 500, "生成初始密码失败")
			return
		}
		password = password[:16]
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		fail(w, 400, err.Error())
		return
	}
	if err := a.checkSeatLimit(r, p.TenantID); err != nil {
		failCode(w, 409, "SEAT_LIMIT_REACHED", err.Error())
		return
	}
	id := uuid.New()
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "创建坐席失败")
		return
	}
	defer tx.Rollback(r.Context()) //nolint:errcheck
	if _, err := tx.Exec(r.Context(), `insert into agent(id, tenant_id, email, display_name, password_hash, role, status, max_concurrent)
		values($1,$2,$3,$4,$5,$6,'ACTIVE',$7)`, id, p.TenantID, email, in.DisplayName, hash, role, in.MaxConcurrent); err != nil {
		if isUniqueViolation(err) {
			failCode(w, 409, "EMAIL_TAKEN", "该邮箱已被使用")
			return
		}
		fail(w, 500, "创建坐席失败")
		return
	}
	for _, raw := range in.InboxIDs {
		inboxID, err := uuid.Parse(raw)
		if err != nil {
			continue
		}
		if _, err := tx.Exec(r.Context(), `insert into agent_inbox(agent_id, inbox_id)
			select $1, i.id from inbox i where i.id = $2 and i.tenant_id = $3
			on conflict do nothing`, id, inboxID, p.TenantID); err != nil {
			fail(w, 500, "分配客服入口失败")
			return
		}
	}
	if err := tx.Commit(r.Context()); err != nil {
		fail(w, 500, "创建坐席失败")
		return
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "agent.create", "agent", id, map[string]any{"email": email, "role": role})
	respond(w, 201, map[string]any{"id": id, "email": email, "role": role, "initialPassword": password})
}

func (a *API) adminUpdateAgent(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "坐席 ID 不合法")
		return
	}
	var in struct {
		DisplayName   string `json:"displayName"`
		Status        string `json:"status"`
		Role          string `json:"role"`
		MaxConcurrent *int   `json:"maxConcurrent"`
	}
	if !decode(w, r, &in) {
		return
	}
	status := strings.ToUpper(strings.TrimSpace(in.Status))
	if status != "" && status != "ACTIVE" && status != "DISABLED" {
		fail(w, 400, "status 只能是 ACTIVE 或 DISABLED")
		return
	}
	role := strings.ToUpper(strings.TrimSpace(in.Role))
	if role != "" && !auth.ValidRole(role) {
		fail(w, 400, "role 不合法")
		return
	}
	if id == p.AgentID && status == "DISABLED" {
		fail(w, 400, "不能停用当前登录的账号")
		return
	}
	if role == auth.RoleOwner && p.Role != auth.RoleOwner {
		failCode(w, 403, "OWNER_REQUIRED", "只有企业所有者可以转移所有权")
		return
	}
	tag, err := a.db.Exec(r.Context(), `update agent
		set display_name = coalesce(nullif($3,''), display_name),
		    status = coalesce(nullif($4,''), status),
		    role = coalesce(nullif($5,''), role),
		    max_concurrent = coalesce($6, max_concurrent),
		    updated_at = now()
		where id = $1 and tenant_id = $2`,
		id, p.TenantID, in.DisplayName, status, role, in.MaxConcurrent)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "坐席不存在")
		return
	}
	if status == "DISABLED" {
		_ = a.authn.RevokeAllSessions(r.Context(), id)
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "agent.update", "agent", id, map[string]any{"status": status, "role": role})
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) adminDeleteAgent(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "坐席 ID 不合法")
		return
	}
	if id == p.AgentID {
		fail(w, 400, "不能删除当前登录的账号")
		return
	}
	var role string
	if a.db.QueryRow(r.Context(), `select role from agent where id=$1 and tenant_id=$2`, id, p.TenantID).Scan(&role) != nil {
		fail(w, 404, "坐席不存在")
		return
	}
	if role == auth.RoleOwner {
		fail(w, 400, "企业所有者账号不可删除")
		return
	}
	var open int
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from conversation where assignee_id=$1 and status <> 'RESOLVED'`, id).Scan(&open)
	if open > 0 {
		failCode(w, 409, "AGENT_HAS_OPEN_CONVERSATIONS", "该坐席还有进行中的会话，请先转接")
		return
	}
	_ = a.authn.RevokeAllSessions(r.Context(), id)
	// Preserve history: the agent row is disabled instead of deleted so old
	// messages keep a resolvable sender name.
	if _, err := a.db.Exec(r.Context(), `update agent set status='DISABLED', updated_at=now() where id=$1 and tenant_id=$2`, id, p.TenantID); err != nil {
		fail(w, 500, "删除坐席失败")
		return
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "agent.delete", "agent", id, nil)
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) adminResetPassword(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "坐席 ID 不合法")
		return
	}
	var in struct {
		Password string `json:"password"`
	}
	if !decode(w, r, &in) {
		return
	}
	password := in.Password
	if password == "" {
		token, _, err := auth.NewOpaqueToken()
		if err != nil {
			fail(w, 500, "生成密码失败")
			return
		}
		password = token[:16]
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		fail(w, 400, err.Error())
		return
	}
	tag, err := a.db.Exec(r.Context(), `update agent set password_hash=$3, updated_at=now() where id=$1 and tenant_id=$2`,
		id, p.TenantID, hash)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "坐席不存在")
		return
	}
	_ = a.authn.RevokeAllSessions(r.Context(), id)
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "agent.password_reset", "agent", id, nil)
	respond(w, 200, map[string]any{"status": "OK", "password": password})
}

func (a *API) adminAgentInboxes(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "坐席 ID 不合法")
		return
	}
	var in struct {
		InboxIDs []string `json:"inboxIds"`
	}
	if !decode(w, r, &in) {
		return
	}
	var exists bool
	if a.db.QueryRow(r.Context(), `select exists(select 1 from agent where id=$1 and tenant_id=$2)`, id, p.TenantID).Scan(&exists) != nil || !exists {
		fail(w, 404, "坐席不存在")
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "更新权限失败")
		return
	}
	defer tx.Rollback(r.Context()) //nolint:errcheck
	if _, err := tx.Exec(r.Context(), `delete from agent_inbox where agent_id=$1`, id); err != nil {
		fail(w, 500, "更新权限失败")
		return
	}
	for _, raw := range in.InboxIDs {
		inboxID, err := uuid.Parse(raw)
		if err != nil {
			continue
		}
		if _, err := tx.Exec(r.Context(), `insert into agent_inbox(agent_id, inbox_id)
			select $1, i.id from inbox i where i.id=$2 and i.tenant_id=$3 on conflict do nothing`, id, inboxID, p.TenantID); err != nil {
			fail(w, 500, "更新权限失败")
			return
		}
	}
	if err := tx.Commit(r.Context()); err != nil {
		fail(w, 500, "更新权限失败")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) checkSeatLimit(r *http.Request, tenantID uuid.UUID) error {
	var limit int
	if a.db.QueryRow(r.Context(), `select seat_limit from tenant_subscription where tenant_id=$1`, tenantID).Scan(&limit) != nil || limit <= 0 {
		return nil
	}
	var used int
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from agent
		where tenant_id=$1 and status='ACTIVE' and email <> 'bot@relaydesk.local'`, tenantID).Scan(&used)
	if used >= limit {
		return errSeatLimit(limit)
	}
	return nil
}

type seatLimitError struct{ limit int }

func (e seatLimitError) Error() string {
	return "当前套餐最多 " + itoa(e.limit) + " 个坐席，请升级套餐后重试"
}

func errSeatLimit(limit int) error { return seatLimitError{limit: limit} }

// ---------------------------------------------------------------- tags

func (a *API) adminCreateTag(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Name  string `json:"name"`
		Color string `json:"color"`
	}
	if !decode(w, r, &in) {
		return
	}
	name := strings.TrimSpace(in.Name)
	if name == "" || len([]rune(name)) > 40 {
		fail(w, 400, "标签名称不能为空且不超过 40 字")
		return
	}
	color := strings.TrimSpace(in.Color)
	if color == "" {
		color = "#356ae6"
	}
	id := uuid.New()
	if _, err := a.db.Exec(r.Context(), `insert into tag(id, tenant_id, name, color) values($1,$2,$3,$4)
		on conflict (tenant_id, lower(name)) do update set color = excluded.color`, id, p.TenantID, name, color); err != nil {
		fail(w, 500, "创建标签失败")
		return
	}
	_ = a.db.QueryRow(r.Context(), `select id from tag where tenant_id=$1 and lower(name)=lower($2)`, p.TenantID, name).Scan(&id)
	respond(w, 201, map[string]any{"id": id, "name": name, "color": color})
}

func (a *API) adminUpdateTag(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "标签 ID 不合法")
		return
	}
	var in struct {
		Name  string `json:"name"`
		Color string `json:"color"`
	}
	if !decode(w, r, &in) {
		return
	}
	tag, err := a.db.Exec(r.Context(), `update tag set name = coalesce(nullif($3,''), name), color = coalesce(nullif($4,''), color)
		where id=$1 and tenant_id=$2`, id, p.TenantID, in.Name, in.Color)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "标签不存在")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) adminDeleteTag(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "标签 ID 不合法")
		return
	}
	tag, err := a.db.Exec(r.Context(), `delete from tag where id=$1 and tenant_id=$2`, id, p.TenantID)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "标签不存在")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

// ---------------------------------------------------------------- webhooks

func (a *API) adminWebhooks(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	rows, err := a.db.Query(r.Context(), `select id, url, status, events, created_at,
			(select count(*)::int from webhook_delivery d where d.endpoint_id = e.id and d.status='FAILED')
		  from webhook_endpoint e where tenant_id = $1 order by created_at`, p.TenantID)
	if err != nil {
		fail(w, 500, "查询回调地址失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 4)
	for rows.Next() {
		var id uuid.UUID
		var url, status string
		var events []string
		var createdAt time.Time
		var failed int
		if err := rows.Scan(&id, &url, &status, &events, &createdAt, &failed); err != nil {
			fail(w, 500, "查询回调地址失败")
			return
		}
		items = append(items, map[string]any{"id": id, "url": url, "status": status,
			"events": events, "createdAt": createdAt, "failedDeliveries": failed})
	}
	respond(w, 200, map[string]any{"items": items, "availableEvents": []string{
		"conversation.created", "conversation.updated", "conversation.closed",
		"message.created", "message.agent", "visitor.created",
	}, "signatureAlgorithm": "HMAC-SHA256 over \"<timestamp>.<raw body>\""})
}

func (a *API) adminCreateWebhook(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		URL    string   `json:"url"`
		Events []string `json:"events"`
		Secret string   `json:"secret"`
	}
	if !decode(w, r, &in) {
		return
	}
	url := strings.TrimSpace(in.URL)
	if !strings.HasPrefix(url, "https://") && !strings.HasPrefix(url, "http://") {
		fail(w, 400, "回调地址必须以 http:// 或 https:// 开头")
		return
	}
	events := validWebhookEvents(in.Events)
	if len(events) == 0 {
		fail(w, 400, "请至少选择一个事件")
		return
	}
	secret := in.Secret
	if secret == "" {
		token, _, err := auth.NewOpaqueToken()
		if err != nil {
			fail(w, 500, "生成签名密钥失败")
			return
		}
		secret = token
	}
	id := uuid.New()
	if _, err := a.db.Exec(r.Context(), `insert into webhook_endpoint(id, tenant_id, url, secret, events, status)
		values($1,$2,$3,$4,$5,'ACTIVE')`, id, p.TenantID, url, secret, events); err != nil {
		fail(w, 500, "创建回调地址失败")
		return
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "webhook.create", "webhook", id, map[string]any{"url": url})
	respond(w, 201, map[string]any{"id": id, "url": url, "secret": secret, "events": events})
}

func (a *API) adminUpdateWebhook(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "ID 不合法")
		return
	}
	var in struct {
		URL    string   `json:"url"`
		Status string   `json:"status"`
		Events []string `json:"events"`
		Rotate bool     `json:"rotateSecret"`
	}
	if !decode(w, r, &in) {
		return
	}
	status := strings.ToUpper(strings.TrimSpace(in.Status))
	if status != "" && status != "ACTIVE" && status != "DISABLED" {
		fail(w, 400, "status 只能是 ACTIVE 或 DISABLED")
		return
	}
	if in.URL != "" && !strings.HasPrefix(in.URL, "http") {
		fail(w, 400, "回调地址必须以 http:// 或 https:// 开头")
		return
	}
	events := validWebhookEvents(in.Events)
	var newSecret string
	if in.Rotate {
		token, _, err := auth.NewOpaqueToken()
		if err != nil {
			fail(w, 500, "生成签名密钥失败")
			return
		}
		newSecret = token
	}
	tag, err := a.db.Exec(r.Context(), `update webhook_endpoint
		set url = coalesce(nullif($3,''), url),
		    status = coalesce(nullif($4,''), status),
		    events = case when $5::text[] is null then events else $5 end,
		    secret = coalesce(nullif($6,''), secret)
		where id=$1 and tenant_id=$2`, id, p.TenantID, in.URL, status, nullableEvents(events), newSecret)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "回调地址不存在")
		return
	}
	respond(w, 200, map[string]any{"status": "OK", "secret": newSecret})
}

func (a *API) adminDeleteWebhook(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "ID 不合法")
		return
	}
	tag, err := a.db.Exec(r.Context(), `delete from webhook_endpoint where id=$1 and tenant_id=$2`, id, p.TenantID)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "回调地址不存在")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) adminWebhookDeliveries(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "ID 不合法")
		return
	}
	var owned bool
	if a.db.QueryRow(r.Context(), `select exists(select 1 from webhook_endpoint where id=$1 and tenant_id=$2)`,
		id, p.TenantID).Scan(&owned) != nil || !owned {
		fail(w, 404, "回调地址不存在")
		return
	}
	limit := queryInt(r, "limit", 50)
	if limit > 200 {
		limit = 200
	}
	rows, err := a.db.Query(r.Context(), `select id, event_type, status, attempts, response_status, last_error, created_at, delivered_at
		from webhook_delivery where endpoint_id = $1 order by created_at desc limit $2`, id, limit)
	if err != nil {
		fail(w, 500, "查询投递记录失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, limit)
	for rows.Next() {
		var deliveryID uuid.UUID
		var eventType, status string
		var attempts int
		var responseStatus *int
		var lastError *string
		var createdAt time.Time
		var deliveredAt *time.Time
		if err := rows.Scan(&deliveryID, &eventType, &status, &attempts, &responseStatus, &lastError, &createdAt, &deliveredAt); err != nil {
			fail(w, 500, "查询投递记录失败")
			return
		}
		items = append(items, map[string]any{"id": deliveryID, "eventType": eventType, "status": status,
			"attempts": attempts, "responseStatus": responseStatus, "lastError": lastError,
			"createdAt": createdAt, "deliveredAt": deliveredAt})
	}
	respond(w, 200, map[string]any{"items": items})
}

func (a *API) adminTestWebhook(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "ID 不合法")
		return
	}
	var owned bool
	if a.db.QueryRow(r.Context(), `select exists(select 1 from webhook_endpoint where id=$1 and tenant_id=$2)`,
		id, p.TenantID).Scan(&owned) != nil || !owned {
		fail(w, 404, "回调地址不存在")
		return
	}
	// Queue a real delivery so the customer tests the same code path as
	// production, including signature and retry behaviour. pgx encodes the map
	// as jsonb directly.
	if _, err := a.db.Exec(r.Context(), `insert into webhook_delivery(id, endpoint_id, tenant_id, event_type, payload, status, next_attempt_at)
		values($1,$2,$3,'webhook.test',$4,'PENDING', now())`,
		uuid.New(), id, p.TenantID, map[string]any{
			"test": true, "tenantId": p.TenantID, "sentAt": nowUTC(),
			"message": "这是一条 RelayDesk 测试回调",
		}); err != nil {
		fail(w, 500, "创建测试回调失败")
		return
	}
	respond(w, 202, map[string]any{"status": "QUEUED", "message": "测试回调已入队，请在投递记录中查看结果"})
}

// ---------------------------------------------------------------- api keys

func (a *API) adminAPIKeys(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	rows, err := a.db.Query(r.Context(), `select id, name, key_prefix, status, created_at, last_used_at,
			scopes, coalesce(description,''), request_count, expires_at, revoked_at
		from api_key where tenant_id = $1 order by created_at desc`, p.TenantID)
	if err != nil {
		fail(w, 500, "查询 API 密钥失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 4)
	for rows.Next() {
		var id uuid.UUID
		var name, prefix, status string
		var createdAt time.Time
		var lastUsed, expiresAt, revokedAt *time.Time
		var scopes []string
		var description string
		var requestCount int64
		if err := rows.Scan(&id, &name, &prefix, &status, &createdAt, &lastUsed,
			&scopes, &description, &requestCount, &expiresAt, &revokedAt); err != nil {
			fail(w, 500, "查询 API 密钥失败")
			return
		}
		items = append(items, map[string]any{"id": id, "name": name, "keyPrefix": prefix,
			"status": status, "createdAt": createdAt, "lastUsedAt": lastUsed,
			"scopes": scopes, "description": description, "requestCount": requestCount,
			"expiresAt": expiresAt, "revokedAt": revokedAt})
	}
	respond(w, 200, map[string]any{"items": items})
}

func (a *API) adminCreateAPIKey(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Name        string   `json:"name"`
		Scopes      []string `json:"scopes"`
		Description string   `json:"description"`
	}
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.Name) == "" {
		fail(w, 400, "密钥名称不能为空")
		return
	}
	scopes := make([]string, 0, len(in.Scopes))
	for _, scope := range in.Scopes {
		scope = strings.ToLower(strings.TrimSpace(scope))
		switch scope {
		case "read", "write", "admin":
			scopes = append(scopes, scope)
		case "":
		default:
			fail(w, 400, "权限只能是 read、write 或 admin")
			return
		}
	}
	token, hash, prefix, err := auth.NewAPIKey()
	if err != nil {
		fail(w, 500, "生成密钥失败")
		return
	}
	id := uuid.New()
	if _, err := a.db.Exec(r.Context(), `insert into api_key(id, tenant_id, name, key_prefix, key_hash, status, scopes, description)
		values($1,$2,$3,$4,$5,'ACTIVE',$6,$7)`,
		id, p.TenantID, in.Name, prefix, hash, scopes, nullable(in.Description)); err != nil {
		fail(w, 500, "创建密钥失败")
		return
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "api_key.create", "api_key", id, map[string]any{"prefix": prefix})
	// The plaintext key is shown exactly once.
	respond(w, 201, map[string]any{"id": id, "name": in.Name, "key": token, "keyPrefix": prefix, "scopes": scopes})
}

func (a *API) adminRevokeAPIKey(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "ID 不合法")
		return
	}
	tag, err := a.db.Exec(r.Context(), `update api_key set status='REVOKED' where id=$1 and tenant_id=$2`, id, p.TenantID)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "密钥不存在")
		return
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "api_key.revoke", "api_key", id, nil)
	respond(w, 200, map[string]any{"status": "OK"})
}

// ---------------------------------------------------------------- knowledge categories

func (a *API) adminKnowledgeCategories(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	rows, err := a.db.Query(r.Context(), `select c.id, c.name, c.sort_order,
			(select count(*)::int from knowledge_entry e where e.category_id = c.id)
		  from knowledge_category c where c.tenant_id = $1 order by c.sort_order, c.name`, p.TenantID)
	if err != nil {
		fail(w, 500, "查询知识分类失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 8)
	for rows.Next() {
		var id uuid.UUID
		var name string
		var sortOrder, entries int
		if err := rows.Scan(&id, &name, &sortOrder, &entries); err != nil {
			fail(w, 500, "查询知识分类失败")
			return
		}
		items = append(items, map[string]any{"id": id, "name": name, "sortOrder": sortOrder, "entryCount": entries})
	}
	respond(w, 200, map[string]any{"items": items})
}

func (a *API) adminCreateKnowledgeCategory(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Name      string `json:"name"`
		SortOrder int    `json:"sortOrder"`
	}
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.Name) == "" {
		fail(w, 400, "分类名称不能为空")
		return
	}
	id := uuid.New()
	if _, err := a.db.Exec(r.Context(), `insert into knowledge_category(id, tenant_id, name, sort_order)
		values($1,$2,$3,$4) on conflict (tenant_id, lower(name)) do update set sort_order = excluded.sort_order`,
		id, p.TenantID, in.Name, in.SortOrder); err != nil {
		fail(w, 500, "创建知识分类失败")
		return
	}
	_ = a.db.QueryRow(r.Context(), `select id from knowledge_category where tenant_id=$1 and lower(name)=lower($2)`,
		p.TenantID, in.Name).Scan(&id)
	respond(w, 201, map[string]any{"id": id, "name": in.Name})
}

func (a *API) adminDeleteKnowledgeCategory(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "ID 不合法")
		return
	}
	tag, err := a.db.Exec(r.Context(), `delete from knowledge_category where id=$1 and tenant_id=$2`, id, p.TenantID)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "知识分类不存在")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

// ---------------------------------------------------------------- knowledge entries

// adminKnowledgeEntries lists the corpus. The bot only ever cites entries that
// are ACTIVE, but disabled entries stay visible here so an operator can see what
// they turned off.
func (a *API) adminKnowledgeEntries(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	limit := queryInt(r, "limit", 50)
	if limit > 200 {
		limit = 200
	}
	offset := queryInt(r, "offset", 0)
	if offset < 0 {
		offset = 0
	}
	status := strings.ToUpper(strings.TrimSpace(r.URL.Query().Get("status")))
	search := strings.TrimSpace(r.URL.Query().Get("q"))

	conditions := []string{"e.tenant_id = $1"}
	args := []any{p.TenantID}
	if status == "ACTIVE" || status == "DISABLED" {
		args = append(args, status)
		conditions = append(conditions, "e.status = $"+itoa(len(args)))
	}
	if categoryID := strings.TrimSpace(r.URL.Query().Get("categoryId")); categoryID != "" {
		if parsed, err := uuid.Parse(categoryID); err == nil {
			args = append(args, parsed)
			conditions = append(conditions, "e.category_id = $"+itoa(len(args)))
		}
	}
	if search != "" {
		args = append(args, search)
		index := itoa(len(args))
		conditions = append(conditions, "(e.title ilike '%' || $"+index+" || '%' or e.content ilike '%' || $"+index+" || '%')")
	}
	where := strings.Join(conditions, " and ")

	var total int
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from knowledge_entry e where `+where, args...).Scan(&total)

	args = append(args, limit, offset)
	rows, err := a.db.Query(r.Context(), `
		select e.id, e.category_id, coalesce(c.name,''), e.title, e.content, e.question_examples,
		       e.status, e.hit_count, e.created_at, e.updated_at
		  from knowledge_entry e
		  left join knowledge_category c on c.id = e.category_id
		 where `+where+`
		 order by e.updated_at desc
		 limit $`+itoa(len(args)-1)+` offset $`+itoa(len(args)), args...)
	if err != nil {
		a.logger.Error("list knowledge failed", "error", err)
		fail(w, 500, "查询知识库失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, limit)
	for rows.Next() {
		var id, categoryID *uuid.UUID
		var categoryName, title, content, examples, entryStatus string
		var hitCount int64
		var createdAt, updatedAt time.Time
		if err := rows.Scan(&id, &categoryID, &categoryName, &title, &content, &examples,
			&entryStatus, &hitCount, &createdAt, &updatedAt); err != nil {
			fail(w, 500, "查询知识库失败")
			return
		}
		items = append(items, map[string]any{
			"id": id, "categoryId": categoryID, "categoryName": categoryName, "title": title,
			"content": content, "questionExamples": examples, "status": entryStatus,
			"hitCount": hitCount, "createdAt": createdAt, "updatedAt": updatedAt,
			"summary": summarize(content, 120),
		})
	}
	respond(w, 200, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
}

func (a *API) adminKnowledgeEntry(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.knowledgeEntryID(w, r, p)
	if !ok {
		return
	}
	var categoryID *uuid.UUID
	var categoryName, title, content, examples, entryStatus string
	var hitCount int64
	var createdAt, updatedAt time.Time
	if err := a.db.QueryRow(r.Context(), `
		select e.category_id, coalesce(c.name,''), e.title, e.content, e.question_examples,
		       e.status, e.hit_count, e.created_at, e.updated_at
		  from knowledge_entry e
		  left join knowledge_category c on c.id = e.category_id
		 where e.id = $1 and e.tenant_id = $2`, id, p.TenantID).
		Scan(&categoryID, &categoryName, &title, &content, &examples, &entryStatus, &hitCount, &createdAt, &updatedAt); err != nil {
		fail(w, 404, "知识条目不存在")
		return
	}
	respond(w, 200, map[string]any{
		"id": id, "categoryId": categoryID, "categoryName": categoryName, "title": title,
		"content": content, "questionExamples": examples, "status": entryStatus,
		"hitCount": hitCount, "createdAt": createdAt, "updatedAt": updatedAt,
	})
}

type knowledgeEntryRequest struct {
	CategoryID       string `json:"categoryId"`
	Title            string `json:"title"`
	Content          string `json:"content"`
	QuestionExamples string `json:"questionExamples"`
	Status           string `json:"status"`
}

func (a *API) adminCreateKnowledgeEntry(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in knowledgeEntryRequest
	if !decode(w, r, &in) {
		return
	}
	title := strings.TrimSpace(in.Title)
	content := strings.TrimSpace(in.Content)
	if title == "" || content == "" {
		fail(w, 400, "标题和内容不能为空")
		return
	}
	categoryID, ok := a.knowledgeCategory(w, r, p, in.CategoryID)
	if !ok {
		return
	}
	id := uuid.New()
	if _, err := a.db.Exec(r.Context(), `
		insert into knowledge_entry(id, tenant_id, category_id, title, content, question_examples, status)
		values($1,$2,$3,$4,$5,$6,$7)`,
		id, p.TenantID, categoryID, title, content, strings.TrimSpace(in.QuestionExamples),
		knowledgeStatus(in.Status)); err != nil {
		a.logger.Error("create knowledge entry failed", "error", err)
		fail(w, 500, "创建知识条目失败")
		return
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "knowledge.create", "knowledge_entry", id, map[string]any{"title": title})
	respond(w, 201, map[string]any{"id": id, "title": title})
}

func (a *API) adminUpdateKnowledgeEntry(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.knowledgeEntryID(w, r, p)
	if !ok {
		return
	}
	var in knowledgeEntryRequest
	if !decode(w, r, &in) {
		return
	}
	categoryID, ok := a.knowledgeCategory(w, r, p, in.CategoryID)
	if !ok {
		return
	}
	// Every field is optional: an unset one keeps its current value, so the
	// console can save a single toggled switch without resending the article.
	var status any
	if strings.TrimSpace(in.Status) != "" {
		status = knowledgeStatus(in.Status)
	}
	tag, err := a.db.Exec(r.Context(), `
		update knowledge_entry set
		    category_id = coalesce($3, category_id),
		    title = coalesce($4, title),
		    content = coalesce($5, content),
		    question_examples = coalesce($6, question_examples),
		    status = coalesce($7, status),
		    updated_at = now()
		where id = $1 and tenant_id = $2`,
		id, p.TenantID, categoryID, nullable(in.Title), nullable(in.Content),
		nullable(in.QuestionExamples), status)
	if err != nil {
		a.logger.Error("update knowledge entry failed", "error", err)
		fail(w, 500, "更新知识条目失败")
		return
	}
	if tag.RowsAffected() == 0 {
		fail(w, 404, "知识条目不存在")
		return
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "knowledge.update", "knowledge_entry", id, nil)
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) adminDeleteKnowledgeEntry(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.knowledgeEntryID(w, r, p)
	if !ok {
		return
	}
	tag, err := a.db.Exec(r.Context(), `delete from knowledge_entry where id=$1 and tenant_id=$2`, id, p.TenantID)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "知识条目不存在")
		return
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "knowledge.delete", "knowledge_entry", id, nil)
	respond(w, 200, map[string]any{"status": "OK"})
}

// adminImportKnowledge bulk-loads a tenant's existing FAQ export. Each row is
// upserted on the title so re-importing an edited spreadsheet updates rather
// than duplicates, which is how tenants actually maintain these files.
func (a *API) adminImportKnowledge(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		CategoryID string `json:"categoryId"`
		Category   string `json:"category"`
		Entries    []struct {
			Title            string `json:"title"`
			Content          string `json:"content"`
			QuestionExamples string `json:"questionExamples"`
			Status           string `json:"status"`
		} `json:"entries"`
	}
	if !decode(w, r, &in) {
		return
	}
	if len(in.Entries) == 0 {
		fail(w, 400, "没有可导入的内容")
		return
	}
	if len(in.Entries) > 2000 {
		fail(w, 400, "单次最多导入 2000 条")
		return
	}
	categoryID, ok := a.knowledgeCategory(w, r, p, in.CategoryID)
	if !ok {
		return
	}
	if categoryID == nil && strings.TrimSpace(in.Category) != "" {
		// Importing under a new category name is the common case for a first
		// upload, so the category is created on the fly.
		created := uuid.New()
		if _, err := a.db.Exec(r.Context(), `insert into knowledge_category(id, tenant_id, name)
			values($1,$2,$3) on conflict (tenant_id, lower(name)) do update set name = excluded.name`,
			created, p.TenantID, strings.TrimSpace(in.Category)); err != nil {
			fail(w, 500, "创建知识分类失败")
			return
		}
		_ = a.db.QueryRow(r.Context(), `select id from knowledge_category
			where tenant_id=$1 and lower(name)=lower($2)`, p.TenantID, strings.TrimSpace(in.Category)).Scan(&created)
		categoryID = &created
	}

	imported, updated, skipped := 0, 0, 0
	for _, entry := range in.Entries {
		title := strings.TrimSpace(entry.Title)
		content := strings.TrimSpace(entry.Content)
		if title == "" || content == "" {
			skipped++
			continue
		}
		status := knowledgeStatus(entry.Status)
		examples := strings.TrimSpace(entry.QuestionExamples)
		// Matched on title: a tenant re-uploading an edited FAQ replaces the old
		// answer instead of accumulating near-duplicates the bot then has to
		// choose between.
		var existing uuid.UUID
		err := a.db.QueryRow(r.Context(), `select id from knowledge_entry
			where tenant_id=$1 and lower(title)=lower($2) limit 1`, p.TenantID, title).Scan(&existing)
		switch {
		case err == nil:
			if _, err := a.db.Exec(r.Context(), `
				update knowledge_entry set content=$3, question_examples=$4, status=$5,
				    category_id = coalesce($6, category_id), updated_at = now()
				where id=$1 and tenant_id=$2`, existing, p.TenantID, content, examples, status, categoryID); err != nil {
				skipped++
				continue
			}
			updated++
		case errors.Is(err, pgx.ErrNoRows):
			if _, err := a.db.Exec(r.Context(), `
				insert into knowledge_entry(id, tenant_id, category_id, title, content, question_examples, status)
				values($1,$2,$3,$4,$5,$6,$7)`,
				uuid.New(), p.TenantID, categoryID, title, content, examples, status); err != nil {
				skipped++
				continue
			}
			imported++
		default:
			skipped++
		}
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "knowledge.import", "knowledge_entry", uuid.Nil,
		map[string]any{"imported": imported, "updated": updated, "skipped": skipped})
	respond(w, 201, map[string]any{"imported": imported, "updated": updated, "skipped": skipped})
}

// adminKnowledgeGaps reports questions the bot could not answer. This is what
// turns the knowledge base into a product loop: the operator reads the list and
// writes the missing article.
func (a *API) adminKnowledgeGaps(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	days := queryInt(r, "days", 30)
	if days < 1 || days > 365 {
		days = 30
	}
	rows, err := a.db.Query(r.Context(), `
		select coalesce(m.content, ''), coalesce(i.reason, ''), count(*)::int, max(i.created_at)
		  from ai_interaction i
		  left join message m on m.id = i.question_message_id
		 where i.tenant_id = $1 and i.answered = false
		   and i.created_at >= now() - make_interval(days => $2::int)
		 group by 1, 2
		 order by 3 desc, 4 desc
		 limit 50`, p.TenantID, days)
	if err != nil {
		a.logger.Error("knowledge gaps failed", "error", err)
		fail(w, 500, "查询未命中问题失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 20)
	for rows.Next() {
		var question, reason string
		var count int
		var lastAt time.Time
		if err := rows.Scan(&question, &reason, &count, &lastAt); err != nil {
			fail(w, 500, "查询未命中问题失败")
			return
		}
		items = append(items, map[string]any{
			"question": question, "reason": reason, "count": count, "lastAskedAt": lastAt,
		})
	}
	respond(w, 200, map[string]any{"items": items, "days": days})
}

// knowledgeEntryID parses {id} and confirms the entry belongs to the tenant.
func (a *API) knowledgeEntryID(w http.ResponseWriter, r *http.Request, p auth.Principal) (uuid.UUID, bool) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "知识条目 ID 不合法")
		return uuid.Nil, false
	}
	var exists bool
	if err := a.db.QueryRow(r.Context(), `select exists(select 1 from knowledge_entry where id=$1 and tenant_id=$2)`,
		id, p.TenantID).Scan(&exists); err != nil || !exists {
		fail(w, 404, "知识条目不存在")
		return uuid.Nil, false
	}
	return id, true
}

// knowledgeCategory resolves an optional category reference, returning nil when
// the caller passed nothing. A non-empty but unknown id is rejected instead of
// silently dropped, because that always means a stale console.
func (a *API) knowledgeCategory(w http.ResponseWriter, r *http.Request, p auth.Principal, raw string) (*uuid.UUID, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, true
	}
	id, err := uuid.Parse(raw)
	if err != nil {
		fail(w, 400, "知识分类 ID 不合法")
		return nil, false
	}
	var exists bool
	if err := a.db.QueryRow(r.Context(), `select exists(select 1 from knowledge_category where id=$1 and tenant_id=$2)`,
		id, p.TenantID).Scan(&exists); err != nil || !exists {
		fail(w, 404, "知识分类不存在")
		return nil, false
	}
	return &id, true
}

// knowledgeStatus defaults to ACTIVE: an entry created without an explicit
// status is meant to be used by the bot right away.
func knowledgeStatus(raw string) string {
	switch strings.ToUpper(strings.TrimSpace(raw)) {
	case "DISABLED":
		return "DISABLED"
	default:
		return "ACTIVE"
	}
}

// summarize produces the list preview. It counts runes, not bytes, so a Chinese
// answer is not cut in the middle of a character.
func summarize(content string, limit int) string {
	content = strings.Join(strings.Fields(content), " ")
	if content == "" {
		return ""
	}
	runes := []rune(content)
	if len(runes) <= limit {
		return content
	}
	return string(runes[:limit]) + "…"
}

// ---------------------------------------------------------------- helpers

// tenantInbox parses the {id} path value and verifies tenant ownership.
func (a *API) tenantInbox(w http.ResponseWriter, r *http.Request, p auth.Principal) (uuid.UUID, bool) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "客服入口 ID 不合法")
		return uuid.Nil, false
	}
	var exists bool
	if a.db.QueryRow(r.Context(), `select exists(select 1 from inbox where id=$1 and tenant_id=$2)`,
		id, p.TenantID).Scan(&exists) != nil || !exists {
		fail(w, 404, "客服入口不存在")
		return uuid.Nil, false
	}
	return id, true
}

func validWebhookEvents(events []string) []string {
	allowed := map[string]struct{}{
		"conversation.created": {}, "conversation.updated": {}, "conversation.closed": {},
		"message.created": {}, "message.agent": {}, "visitor.created": {},
	}
	result := make([]string, 0, len(events))
	seen := make(map[string]struct{})
	for _, event := range events {
		event = strings.TrimSpace(event)
		if _, ok := allowed[event]; !ok {
			continue
		}
		if _, ok := seen[event]; ok {
			continue
		}
		seen[event] = struct{}{}
		result = append(result, event)
	}
	return result
}

func nullableEvents(events []string) any {
	if len(events) == 0 {
		return nil
	}
	return events
}

// nullableIfSet distinguishes "field omitted" (nil) from "set to empty string".
func nullableIfSet(value *string) any {
	if value == nil {
		return nil
	}
	return strings.TrimSpace(*value)
}
