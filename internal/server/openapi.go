package server

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/realtime"
	"github.com/relaydesk/relaydesk/internal/webhook"
)

// The open API is what a tenant's own backend talks to: their CRM syncing
// conversations, their order system pushing a confirmation into a chat, their
// BI pulling statistics. It authenticates with a tenant API key in the
// X-RelayDesk-Key header rather than with an agent session, because the caller
// is a server with no human behind it.
//
// Everything a key can do is scoped to its own tenant by construction: the
// tenant id comes from the key row, never from the request body or the path.
func (a *API) registerOpen(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/open/unread", a.requireAPIKey("read", a.openUnread))
	mux.HandleFunc("GET /api/v1/open/conversations/{id}/receipts", a.requireAPIKey("read", a.openReceipts))
	mux.HandleFunc("POST /api/v1/open/conversations/{id}/read", a.requireAPIKey("write", a.openReceipt))
	mux.HandleFunc("POST /api/v1/open/conversations/{id}/delivered", a.requireAPIKey("write", a.openReceipt))
	mux.HandleFunc("GET /api/v1/open/me", a.requireAPIKey("read", a.openMe))
	mux.HandleFunc("POST /api/v1/open/visitor-identity", a.requireAPIKey("write", a.openVisitorIdentity))

	mux.HandleFunc("GET /api/v1/open/conversations", a.requireAPIKey("read", a.openListConversations))
	mux.HandleFunc("GET /api/v1/open/conversations/{id}", a.requireAPIKey("read", a.openGetConversation))
	mux.HandleFunc("GET /api/v1/open/conversations/{id}/messages", a.requireAPIKey("read", a.openListMessages))
	mux.HandleFunc("POST /api/v1/open/conversations/{id}/messages", a.requireAPIKey("write", a.openPostMessage))
	mux.HandleFunc("PATCH /api/v1/open/conversations/{id}", a.requireAPIKey("write", a.openUpdateConversation))

	mux.HandleFunc("GET /api/v1/open/visitors", a.requireAPIKey("read", a.openListVisitors))
	mux.HandleFunc("GET /api/v1/open/visitors/{id}", a.requireAPIKey("read", a.openGetVisitor))
	mux.HandleFunc("POST /api/v1/open/visitors/{id}/conversations", a.requireAPIKey("write", a.openCreateConversation))

	mux.HandleFunc("GET /api/v1/open/agents", a.requireAPIKey("read", a.openListAgents))
	mux.HandleFunc("GET /api/v1/open/stats", a.requireAPIKey("read", a.openStats))
	a.registerOpenGroups(mux)
}

func (a *API) openVisitorIdentity(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	var in struct {
		InboxKey    string `json:"inboxKey"`
		ExternalID  string `json:"externalId"`
		DisplayName string `json:"displayName"`
	}
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.ExternalID) == "" || len(in.ExternalID) > 200 {
		fail(w, 400, "externalId 必须为 1 到 200 个字符")
		return
	}
	inbox, err := a.loadInbox(r.Context(), in.InboxKey)
	if err != nil || inbox.TenantID != p.TenantID {
		fail(w, 404, "客服入口不存在或不属于当前企业")
		return
	}
	token, err := a.tokens.IssueVisitorIdentity(p.TenantID, inbox.ID, strings.TrimSpace(in.ExternalID), strings.TrimSpace(in.DisplayName))
	if err != nil {
		fail(w, 500, "签发身份票据失败")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	respond(w, 200, map[string]any{"identityToken": token, "expiresIn": 300, "inboxKey": in.InboxKey})
}

// apiKeyPrincipal is the authenticated caller of the open API.
type apiKeyPrincipal struct {
	KeyID    uuid.UUID
	TenantID uuid.UUID
	Tenant   string
	Name     string
	Scopes   []string
}

// requireAPIKey authenticates a tenant API key and enforces the scope the
// handler needs. The key is hashed and matched against api_key.key_hash, so a
// database leak does not hand over usable credentials.
func (a *API) requireAPIKey(scope string, next func(http.ResponseWriter, *http.Request, apiKeyPrincipal)) http.HandlerFunc {
	return a.limit(a.openRate, func(w http.ResponseWriter, r *http.Request) {
		token := apiKeyFrom(r)
		if token == "" {
			failCode(w, 401, "API_KEY_REQUIRED", "缺少 X-RelayDesk-Key 请求头")
			return
		}
		var p apiKeyPrincipal
		var keyStatus, tenantStatus string
		var scopes []string
		var expiresAt *time.Time
		err := a.db.QueryRow(r.Context(), `
			select k.id, k.tenant_id, k.name, k.status, k.scopes,
			       t.name, t.status, k.expires_at
			  from api_key k
			  join tenant t on t.id = k.tenant_id
			 where k.key_hash = $1`, auth.HashToken(token)).
			Scan(&p.KeyID, &p.TenantID, &p.Name, &keyStatus, &scopes, &p.Tenant, &tenantStatus, &expiresAt)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				failCode(w, 401, "API_KEY_INVALID", "API 密钥无效")
				return
			}
			fail(w, 500, "校验 API 密钥失败")
			return
		}
		if keyStatus != "ACTIVE" {
			failCode(w, 401, "API_KEY_REVOKED", "API 密钥已被撤销")
			return
		}
		if expiresAt != nil && expiresAt.Before(nowUTC()) {
			failCode(w, 401, "API_KEY_EXPIRED", "API 密钥已过期")
			return
		}
		if tenantStatus != "ACTIVE" {
			failCode(w, 403, "TENANT_SUSPENDED", "租户已停用，请联系平台管理员")
			return
		}
		if !scopeAllowed(scopes, scope) {
			failCode(w, 403, "SCOPE_REQUIRED", "该密钥没有 "+scope+" 权限")
			return
		}
		if !a.allowPlanRoute(w, r, auth.Principal{TenantID: p.TenantID}) {
			return
		}
		p.Scopes = scopes
		// The usage timestamp is best-effort: a slow write must never fail the
		// request the tenant is waiting on.
		_, _ = a.db.Exec(r.Context(), `update api_key
			set last_used_at = now(), request_count = request_count + 1 where id = $1`, p.KeyID)
		next(w, r, p)
	})
}

// scopeAllowed treats an empty scope list as full access so keys created before
// scopes existed keep working.
func scopeAllowed(scopes []string, needed string) bool {
	if len(scopes) == 0 {
		return true
	}
	for _, scope := range scopes {
		if scope == needed || scope == "*" || scope == "admin" {
			return true
		}
	}
	return false
}

func apiKeyFrom(r *http.Request) string {
	if key := strings.TrimSpace(r.Header.Get("X-RelayDesk-Key")); key != "" {
		return key
	}
	// A Bearer header is accepted too so the same client helper works against the
	// open API and the console API.
	return strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
}

// ------------------------------------------------------------------ identity

func (a *API) openMe(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	var inboxes, agents, open int
	_ = a.db.QueryRow(r.Context(), `select
		(select count(*)::int from inbox where tenant_id = $1),
		(select count(*)::int from agent where tenant_id = $1 and status = 'ACTIVE'),
		(select count(*)::int from conversation where tenant_id = $1 and status <> 'RESOLVED')`,
		p.TenantID).Scan(&inboxes, &agents, &open)
	respond(w, 200, map[string]any{
		"tenantId":          p.TenantID,
		"tenant":            p.Tenant,
		"keyName":           p.Name,
		"scopes":            p.Scopes,
		"inboxes":           inboxes,
		"agents":            agents,
		"openConversations": open,
	})
}

// ------------------------------------------------------------- conversations

func (a *API) openListConversations(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	limit := queryInt(r, "limit", 50)
	if limit > 200 {
		limit = 200
	}
	offset := queryInt(r, "offset", 0)
	status := strings.ToUpper(strings.TrimSpace(r.URL.Query().Get("status")))
	assignee := strings.TrimSpace(r.URL.Query().Get("assigneeId"))
	inboxID := strings.TrimSpace(r.URL.Query().Get("inboxId"))
	since := strings.TrimSpace(r.URL.Query().Get("updatedSince"))

	var assigneeID *uuid.UUID
	onlyUnassigned := false
	if assignee != "" {
		if assignee == "none" || assignee == "unassigned" {
			onlyUnassigned = true
		} else {
			parsed, err := uuid.Parse(assignee)
			if err != nil {
				fail(w, 400, "assigneeId 必须是 UUID 或 unassigned")
				return
			}
			assigneeID = &parsed
		}
	}
	var parsedInbox *uuid.UUID
	if inboxID != "" {
		parsed, err := uuid.Parse(inboxID)
		if err != nil {
			fail(w, 400, "inboxId 必须是 UUID")
			return
		}
		parsedInbox = &parsed
	}
	var sinceTime *time.Time
	if since != "" {
		parsed, err := time.Parse(time.RFC3339, since)
		if err != nil {
			fail(w, 400, "updatedSince 必须是 RFC3339 时间")
			return
		}
		sinceTime = &parsed
	}

	rows, err := a.db.Query(r.Context(), `
		select c.id, c.inbox_id, c.visitor_id, coalesce(c.subject,''), c.status, c.priority, c.source,
		       c.assignee_id, coalesce(ag.display_name,''), c.last_sequence,
		       coalesce(c.last_message_preview,''), c.last_message_at, c.agent_unread, c.visitor_unread,
		       coalesce(v.display_name,''), c.created_at, c.updated_at, c.accepted_at, c.assignment_expires_at,
		       coalesce((select array_agg(t.name order by t.name) from conversation_tag ct
		                  join tag t on t.id = ct.tag_id where ct.conversation_id = c.id), '{}')
		  from conversation c
		  join visitor v on v.id = c.visitor_id
		  left join agent ag on ag.id = c.assignee_id
		 where c.tenant_id = $1
		   and ($2 = '' or c.status = $2)
		   and ($3::uuid is null or c.inbox_id = $3::uuid)
		   -- $4 selects unassigned only, $5 pins a specific assignee; both null
		   -- means no assignee filter at all.
		   and (not $4::bool or c.assignee_id is null)
		   and ($5::uuid is null or c.assignee_id = $5::uuid)
		   and ($6::timestamptz is null or c.updated_at >= $6::timestamptz)
		 order by c.last_message_at desc nulls last, c.created_at desc
		 limit $7 offset $8`,
		p.TenantID, status, parsedInbox, onlyUnassigned, assigneeID, sinceTime, limit, offset)
	if err != nil {
		fail(w, 500, "查询会话失败")
		return
	}
	defer rows.Close()
	items := make([]conversationView, 0, limit)
	for rows.Next() {
		var view conversationView
		var tags []string
		if err := rows.Scan(&view.ID, &view.InboxID, &view.VisitorID, &view.Subject, &view.Status,
			&view.Priority, &view.Source, &view.AssigneeID, &view.AssigneeName, &view.LastSequence,
			&view.LastMessagePreview, &view.LastMessageAt, &view.AgentUnread, &view.VisitorUnread,
			&view.VisitorName, &view.CreatedAt, &view.UpdatedAt, &view.AcceptedAt, &view.AssignmentExpiresAt, &tags); err != nil {
			fail(w, 500, "查询会话失败")
			return
		}
		view.TenantID = p.TenantID
		view.Tags = tags
		items = append(items, view)
	}
	if err := rows.Err(); err != nil {
		fail(w, 500, "查询会话失败")
		return
	}
	var total int
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from conversation c
		 where c.tenant_id = $1
		   and ($2 = '' or c.status = $2)
		   and ($3::uuid is null or c.inbox_id = $3::uuid)
		   and (not $4::bool or c.assignee_id is null)
		   and ($5::uuid is null or c.assignee_id = $5::uuid)
		   and ($6::timestamptz is null or c.updated_at >= $6::timestamptz)`,
		p.TenantID, status, parsedInbox, onlyUnassigned, assigneeID, sinceTime).Scan(&total)
	respond(w, 200, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
}

func (a *API) openGetConversation(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	id, ok := a.openConversationID(w, r, p)
	if !ok {
		return
	}
	view, err := a.loadConversation(r.Context(), p.TenantID, id)
	if err != nil {
		if err == pgx.ErrNoRows {
			fail(w, 404, "会话不存在")
			return
		}
		fail(w, 500, "查询会话失败")
		return
	}
	respond(w, 200, view)
}

func (a *API) openListMessages(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	id, ok := a.openConversationID(w, r, p)
	if !ok {
		return
	}
	after := queryInt64(r, "after", 0)
	before := queryInt64(r, "before", 0)
	limit := queryInt(r, "limit", 50)
	// The tenant's own backend is the visitor's counterpart, not an agent, so an
	// internal note is withheld by default. A tenant that genuinely needs its own
	// notes back (to sync them into its CRM) asks for them explicitly.
	view := visitorVisibility
	if truthy(r.URL.Query().Get("includePrivate")) {
		view = agentVisibility
	}
	page, err := a.pageMessages(r.Context(), id, after, before, limit, view)
	if err != nil {
		fail(w, 500, "查询消息失败")
		return
	}
	var lastSequence int64
	_ = a.db.QueryRow(r.Context(), `select last_sequence from conversation where id = $1`, id).Scan(&lastSequence)
	if page.LastSequence == 0 {
		page.LastSequence = lastSequence
	}
	respond(w, 200, map[string]any{
		"items": page.Items, "hasMore": page.HasMore, "hasOlder": page.HasOlder,
		"firstSequence": page.FirstSequence, "lastSequence": page.LastSequence,
	})
}

func (a *API) openPostMessage(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	id, ok := a.openConversationID(w, r, p)
	if !ok {
		return
	}
	var in struct {
		ClientMessageID string         `json:"clientMessageId"`
		Content         string         `json:"content"`
		MessageType     string         `json:"messageType"`
		SenderName      string         `json:"senderName"`
		Metadata        map[string]any `json:"metadata"`
	}
	if !decode(w, r, &in) {
		return
	}
	messageType := strings.ToUpper(strings.TrimSpace(in.MessageType))
	if messageType == "" {
		messageType = "TEXT"
	}
	// A message injected by the tenant's own system is authored by AGENT: it is
	// an outward-facing reply from a human or a bot the tenant controls, which is
	// what triggers the visitor-facing realtime event. It is attributed to the
	// tenant's integration agent rather than to nobody, so agent statistics and
	// the reply-author display both have a real row to point at.
	metadata := orEmpty(in.Metadata)
	if in.SenderName != "" {
		metadata["senderName"] = in.SenderName
	}
	metadata["source"] = "open_api"
	view, err := a.appendMessage(r.Context(), p.TenantID, id, messageInput{
		ReceptionExempt: true,
		SenderType:      "AGENT",
		SenderID:        a.integrationAgentID(r.Context(), p.TenantID),
		ClientMessageID: in.ClientMessageID,
		MessageType:     messageType,
		Content:         in.Content,
		Metadata:        metadata,
	})
	if err != nil {
		a.logger.Error("open api message failed", "error", err)
		if failServiceError(w, err) {
			return
		}
		fail(w, 500, "发送消息失败："+err.Error())
		return
	}
	if in.SenderName != "" {
		view.SenderName = in.SenderName
	}
	respond(w, 201, view)
}

func (a *API) openUpdateConversation(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	id, ok := a.openConversationID(w, r, p)
	if !ok {
		return
	}
	var in struct {
		Status   string   `json:"status"`
		Priority *int16   `json:"priority"`
		Tags     []string `json:"tags"`
		Subject  string   `json:"subject"`
	}
	if !decode(w, r, &in) {
		return
	}
	status := strings.ToUpper(strings.TrimSpace(in.Status))
	if status != "" && status != "OPEN" && status != "PENDING" && status != "RESOLVED" {
		fail(w, 400, "status 只能是 OPEN、PENDING 或 RESOLVED")
		return
	}
	// $3 carries the new status and is typed once by the cast; $6 repeats the
	// same value for the resolved/closed bookkeeping. Sharing one placeholder
	// between the varchar column and the comparisons above it is what produced
	// SQLSTATE 42P08 elsewhere in this codebase.
	tag, err := a.db.Exec(r.Context(), `update conversation
		set status = coalesce(nullif($3::varchar(20), ''), status),
		    priority = coalesce($4, priority),
		    subject = coalesce(nullif($5, ''), subject),
		    closed_at = case
		                    when $6::text = 'RESOLVED' then now()
		                    when $6::text = '' then closed_at
		                    else null
		                end,
		    updated_at = now()
		where id = $1 and tenant_id = $2`,
		id, p.TenantID, status, in.Priority, in.Subject, status)
	if err != nil {
		fail(w, 500, "更新会话失败")
		return
	}
	if tag.RowsAffected() == 0 {
		fail(w, 404, "会话不存在")
		return
	}
	if in.Tags != nil {
		if !a.applyConversationTags(r.Context(), p.TenantID, id, in.Tags) {
			fail(w, 500, "更新标签失败")
			return
		}
	}
	a.publish(r.Context(), a.conversationChannels(r.Context(), id), realtime.Event{
		Type: "conversation.updated", TenantID: p.TenantID.String(), ConversationID: id.String(),
		Data: map[string]any{"status": status, "source": "open_api"},
	})
	a.notifyWebhook(r.Context(), p.TenantID, webhook.EventConversationUpdated, map[string]any{
		"conversationId": id, "status": status,
	})
	view, err := a.loadConversation(r.Context(), p.TenantID, id)
	if err != nil {
		respond(w, 200, map[string]any{"status": "OK"})
		return
	}
	respond(w, 200, view)
}

// ------------------------------------------------------------------ visitors

func (a *API) openListVisitors(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	limit := queryInt(r, "limit", 50)
	if limit > 200 {
		limit = 200
	}
	offset := queryInt(r, "offset", 0)
	search := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("search")))
	rows, err := a.db.Query(r.Context(), `
		select v.id, coalesce(v.display_name,''), coalesce(v.email,''), coalesce(v.phone,''),
		       coalesce(v.external_id,''), coalesce(v.locale,''), coalesce(v.country,''),
		       coalesce(v.custom_attributes, '{}'::jsonb),
		       (select count(*)::int from conversation c
		         where c.visitor_id = v.id and c.tenant_id = v.tenant_id),
		       v.created_at, coalesce(v.last_seen_at, v.created_at)
		  from visitor v
		 where v.tenant_id = $1
		   and ($2 = '' or lower(coalesce(v.display_name,'')) like '%' || $2 || '%'
		                or lower(coalesce(v.email,'')) like '%' || $2 || '%'
		                or lower(coalesce(v.external_id,'')) like '%' || $2 || '%')
		 order by coalesce(v.last_seen_at, v.created_at) desc
		 limit $3 offset $4`, p.TenantID, search, limit, offset)
	if err != nil {
		fail(w, 500, "查询客户失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, limit)
	for rows.Next() {
		var id uuid.UUID
		var displayName, email, phone, externalID, locale, country string
		var attributes []byte
		var conversations int
		var createdAt, lastSeen time.Time
		if err := rows.Scan(&id, &displayName, &email, &phone, &externalID, &locale, &country,
			&attributes, &conversations, &createdAt, &lastSeen); err != nil {
			fail(w, 500, "查询客户失败")
			return
		}
		items = append(items, map[string]any{
			"id": id, "displayName": displayName, "email": email, "phone": phone,
			"externalId": externalID, "locale": locale, "country": country,
			"customAttributes": rawJSON(attributes), "conversations": conversations,
			"createdAt": createdAt, "lastSeenAt": lastSeen,
		})
	}
	if err := rows.Err(); err != nil {
		fail(w, 500, "查询客户失败")
		return
	}
	var total int
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from visitor v
		 where v.tenant_id = $1
		   and ($2 = '' or lower(coalesce(v.display_name,'')) like '%' || $2 || '%'
		                or lower(coalesce(v.email,'')) like '%' || $2 || '%'
		                or lower(coalesce(v.external_id,'')) like '%' || $2 || '%')`,
		p.TenantID, search).Scan(&total)
	respond(w, 200, map[string]any{"items": items, "total": total, "limit": limit, "offset": offset})
}

func (a *API) openGetVisitor(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "ID 不合法")
		return
	}
	var displayName, email, phone, externalID, locale, country string
	var attributes []byte
	var createdAt, lastSeen time.Time
	err = a.db.QueryRow(r.Context(), `
		select coalesce(display_name,''), coalesce(email,''), coalesce(phone,''),
		       coalesce(external_id,''), coalesce(locale,''), coalesce(country,''),
		       coalesce(custom_attributes,'{}'::jsonb), created_at, coalesce(last_seen_at, created_at)
		  from visitor where id = $1 and tenant_id = $2`, id, p.TenantID).
		Scan(&displayName, &email, &phone, &externalID, &locale, &country, &attributes, &createdAt, &lastSeen)
	if err != nil {
		if err == pgx.ErrNoRows {
			fail(w, 404, "客户不存在")
			return
		}
		fail(w, 500, "查询客户失败")
		return
	}
	rows, err := a.db.Query(r.Context(), `select id, coalesce(subject,''), status, priority, last_sequence,
			coalesce(last_message_preview,''), last_message_at, created_at, updated_at
		  from conversation where tenant_id = $1 and visitor_id = $2
		 order by created_at desc limit 50`, p.TenantID, id)
	if err != nil {
		fail(w, 500, "查询客户会话失败")
		return
	}
	defer rows.Close()
	conversations := make([]map[string]any, 0, 8)
	for rows.Next() {
		var conversationID uuid.UUID
		var subject, status, preview string
		var priority int16
		var lastSequence int64
		var lastMessageAt *time.Time
		var createdAt, updatedAt time.Time
		if err := rows.Scan(&conversationID, &subject, &status, &priority, &lastSequence,
			&preview, &lastMessageAt, &createdAt, &updatedAt); err != nil {
			fail(w, 500, "查询客户会话失败")
			return
		}
		conversations = append(conversations, map[string]any{
			"id": conversationID, "subject": subject, "status": status, "priority": priority,
			"lastSequence": lastSequence, "lastMessagePreview": preview,
			"lastMessageAt": lastMessageAt, "createdAt": createdAt, "updatedAt": updatedAt,
		})
	}
	if err := rows.Err(); err != nil {
		fail(w, 500, "查询客户会话失败")
		return
	}
	respond(w, 200, map[string]any{
		"id": id, "displayName": displayName, "email": email, "phone": phone,
		"externalId": externalID, "locale": locale, "country": country,
		"customAttributes": rawJSON(attributes), "createdAt": createdAt, "lastSeenAt": lastSeen,
		"conversations": conversations,
	})
}

// openCreateConversation lets a tenant's backend open a chat on behalf of a
// known customer, for example from an order confirmation page.
func (a *API) openCreateConversation(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	visitorID, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "ID 不合法")
		return
	}
	var in struct {
		InboxKey string         `json:"inboxKey"`
		Subject  string         `json:"subject"`
		Content  string         `json:"content"`
		Priority *int16         `json:"priority"`
		Tags     []string       `json:"tags"`
		Metadata map[string]any `json:"metadata"`
	}
	if !decode(w, r, &in) {
		return
	}
	inboxKey := strings.TrimSpace(in.InboxKey)
	if inboxKey == "" {
		fail(w, 400, "inboxKey 不能为空")
		return
	}
	// The inbox must belong to this tenant: the public key alone is not proof.
	var inboxID uuid.UUID
	if a.db.QueryRow(r.Context(), `select id from inbox where tenant_id = $1 and public_key = $2`,
		p.TenantID, inboxKey).Scan(&inboxID) != nil {
		fail(w, 404, "渠道不存在")
		return
	}
	var visitorExists bool
	if a.db.QueryRow(r.Context(), `select exists(select 1 from visitor where id = $1 and tenant_id = $2)`,
		visitorID, p.TenantID).Scan(&visitorExists) != nil || !visitorExists {
		fail(w, 404, "客户不存在")
		return
	}

	conversationID := uuid.New()
	priority := int16(0)
	if in.Priority != nil {
		priority = *in.Priority
	}
	if _, err := a.db.Exec(r.Context(), `insert into conversation(id, tenant_id, inbox_id, visitor_id, subject, status, priority, source)
		values($1,$2,$3,$4,$5,'OPEN',$6,'API')`,
		conversationID, p.TenantID, inboxID, visitorID, nullable(in.Subject), priority); err != nil {
		fail(w, 500, "创建会话失败")
		return
	}
	if len(in.Tags) > 0 {
		a.applyConversationTags(r.Context(), p.TenantID, conversationID, in.Tags)
	}
	view, err := a.loadConversation(r.Context(), p.TenantID, conversationID)
	if err != nil {
		fail(w, 500, "创建会话失败")
		return
	}
	if strings.TrimSpace(in.Content) != "" {
		metadata := orEmpty(in.Metadata)
		metadata["source"] = "open_api"
		message, err := a.appendMessage(r.Context(), p.TenantID, conversationID, messageInput{
			ReceptionExempt: true,
			SenderType:      "AGENT", SenderID: a.integrationAgentID(r.Context(), p.TenantID),
			MessageType: "TEXT", Content: in.Content, Metadata: metadata,
		})
		if err != nil {
			a.logger.Error("open api first message failed", "error", err, "conversation", conversationID)
		} else {
			view.LastSequence = message.Sequence
			view.LastMessagePreview = trimPreview(message.Content)
		}
	}
	a.publish(r.Context(), a.conversationChannels(r.Context(), conversationID), realtime.Event{
		Type: "conversation.created", TenantID: p.TenantID.String(), ConversationID: conversationID.String(),
		Data: map[string]any{"source": "API", "inboxId": inboxID},
	})
	a.notifyWebhook(r.Context(), p.TenantID, webhook.EventConversationCreated, map[string]any{
		"conversationId": conversationID, "visitorId": visitorID, "inboxId": inboxID,
	})
	respond(w, 201, view)
}

// -------------------------------------------------------------------- agents

func (a *API) openListAgents(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	rows, err := a.db.Query(r.Context(), `
		select ag.id, ag.display_name, ag.role, ag.status,
		       coalesce(p.status, 'OFFLINE'),
		       (select count(*)::int from conversation c
		         where c.assignee_id = ag.id and c.status <> 'RESOLVED')
		  from agent ag
		  left join agent_presence p on p.agent_id = ag.id
		 where ag.tenant_id = $1 and ag.email <> 'bot@relaydesk.local'
		 order by ag.display_name`, p.TenantID)
	if err != nil {
		fail(w, 500, "查询坐席失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 8)
	for rows.Next() {
		var id uuid.UUID
		var displayName, role, status, presence string
		var openConversations int
		if err := rows.Scan(&id, &displayName, &role, &status, &presence, &openConversations); err != nil {
			fail(w, 500, "查询坐席失败")
			return
		}
		items = append(items, map[string]any{
			"id": id, "displayName": displayName, "role": role, "status": status,
			"presence": presence, "openConversations": openConversations,
		})
	}
	if err := rows.Err(); err != nil {
		fail(w, 500, "查询坐席失败")
		return
	}
	respond(w, 200, map[string]any{"items": items})
}

// --------------------------------------------------------------------- stats

// openStats exposes the same tenant_daily_stat aggregates the console dashboard
// reads, so a tenant can chart them next to their own business data.
func (a *API) openStats(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	days := queryInt(r, "days", 30)
	if days < 1 || days > 365 {
		days = 30
	}
	rows, err := a.db.Query(r.Context(), `
		select stat_date, conversations_started, conversations_closed, messages_in, messages_out,
		       ai_answered, ai_handoff, first_response_seconds, first_response_samples,
		       rating_sum, rating_count
		  from tenant_daily_stat
		 where tenant_id = $1 and stat_date >= current_date - $2::int
		 order by stat_date`, p.TenantID, days)
	if err != nil {
		fail(w, 500, "查询统计失败")
		return
	}
	defer rows.Close()
	series := make([]map[string]any, 0, days)
	var started, closed, in, out, aiAnswered, aiHandoff, ratingSum, ratingCount int64
	var responseSeconds, responseSamples int64
	for rows.Next() {
		var statDate time.Time
		var sStarted, sClosed, sIn, sOut, sAIAnswered, sAIHandoff, sResponseSeconds, sResponseSamples, sRatingSum, sRatingCount int64
		if err := rows.Scan(&statDate, &sStarted, &sClosed, &sIn, &sOut, &sAIAnswered, &sAIHandoff,
			&sResponseSeconds, &sResponseSamples, &sRatingSum, &sRatingCount); err != nil {
			fail(w, 500, "查询统计失败")
			return
		}
		series = append(series, map[string]any{
			"date":                 statDate.Format("2006-01-02"),
			"conversationsStarted": sStarted, "conversationsClosed": sClosed,
			"messagesIn": sIn, "messagesOut": sOut,
			"aiAnswered": sAIAnswered, "aiHandoff": sAIHandoff,
			"ratingSum": sRatingSum, "ratingCount": sRatingCount,
		})
		started += sStarted
		closed += sClosed
		in += sIn
		out += sOut
		aiAnswered += sAIAnswered
		aiHandoff += sAIHandoff
		ratingSum += sRatingSum
		ratingCount += sRatingCount
		responseSeconds += sResponseSeconds
		responseSamples += sResponseSamples
	}
	if err := rows.Err(); err != nil {
		fail(w, 500, "查询统计失败")
		return
	}
	averageFirstResponse := 0.0
	if responseSamples > 0 {
		averageFirstResponse = float64(responseSeconds) / float64(responseSamples)
	}
	averageRating := 0.0
	if ratingCount > 0 {
		averageRating = float64(ratingSum) / float64(ratingCount)
	}
	deflection := 0.0
	if total := aiAnswered + aiHandoff; total > 0 {
		deflection = float64(aiAnswered) / float64(total)
	}
	respond(w, 200, map[string]any{
		"days": days, "series": series,
		"totals": map[string]any{
			"conversationsStarted": started, "conversationsClosed": closed,
			"messagesIn": in, "messagesOut": out,
			"aiAnswered": aiAnswered, "aiHandoff": aiHandoff,
			"aiDeflectionRate":        deflection,
			"avgFirstResponseSeconds": averageFirstResponse,
			"avgRating":               averageRating,
		},
	})
}

// ------------------------------------------------------------------- helpers

// openConversationID parses and authorises the conversation in the path. The
// tenant check is part of the lookup, so a valid id from another tenant is
// indistinguishable from a missing one.
func (a *API) openConversationID(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) (uuid.UUID, bool) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "ID 不合法")
		return uuid.Nil, false
	}
	var exists bool
	if a.db.QueryRow(r.Context(), `select exists(select 1 from conversation where id = $1 and tenant_id = $2)`,
		id, p.TenantID).Scan(&exists) != nil || !exists {
		fail(w, 404, "会话不存在")
		return uuid.Nil, false
	}
	return id, true
}

func (a *API) loadConversation(ctx handlerContext, tenantID, conversationID uuid.UUID) (conversationView, error) {
	var view conversationView
	var tags []string
	err := a.db.QueryRow(ctx, `
		select c.id, c.inbox_id, c.visitor_id, coalesce(c.subject,''), c.status, c.priority, c.source,
		       c.assignee_id, coalesce(ag.display_name,''), c.last_sequence,
		       coalesce(c.last_message_preview,''), c.last_message_at, c.agent_unread, c.visitor_unread,
		       coalesce(v.display_name,''), c.created_at, c.updated_at, c.accepted_at, c.assignment_expires_at,
		       coalesce((select array_agg(t.name order by t.name) from conversation_tag ct
		                  join tag t on t.id = ct.tag_id where ct.conversation_id = c.id), '{}')
		  from conversation c
		  join visitor v on v.id = c.visitor_id
		  left join agent ag on ag.id = c.assignee_id
		 where c.id = $1 and c.tenant_id = $2`, conversationID, tenantID).
		Scan(&view.ID, &view.InboxID, &view.VisitorID, &view.Subject, &view.Status, &view.Priority,
			&view.Source, &view.AssigneeID, &view.AssigneeName, &view.LastSequence,
			&view.LastMessagePreview, &view.LastMessageAt, &view.AgentUnread, &view.VisitorUnread,
			&view.VisitorName, &view.CreatedAt, &view.UpdatedAt, &view.AcceptedAt, &view.AssignmentExpiresAt, &tags)
	if err != nil {
		return conversationView{}, err
	}
	view.TenantID = tenantID
	view.Tags = tags
	return view, nil
}

// applyConversationTags replaces the conversation's tags. Tags are created on
// demand so an integration can tag a conversation without a prior setup step.
func (a *API) applyConversationTags(ctx handlerContext, tenantID, conversationID uuid.UUID, names []string) bool {
	cleaned := make([]string, 0, len(names))
	seen := make(map[string]struct{}, len(names))
	for _, name := range names {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		key := strings.ToLower(name)
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		cleaned = append(cleaned, name)
	}
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return false
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `delete from conversation_tag where conversation_id = $1`, conversationID); err != nil {
		return false
	}
	for _, name := range cleaned {
		var tagID uuid.UUID
		// Upsert on the per-tenant unique name, then read the id back so a
		// concurrent insert resolves to the same row instead of failing.
		if err := tx.QueryRow(ctx, `
			insert into tag(id, tenant_id, name, color, created_at)
			values($1,$2,$3,'#6366f1', now())
			on conflict (tenant_id, lower(name)) do update set name = excluded.name
			returning id`, uuid.New(), tenantID, name).Scan(&tagID); err != nil {
			return false
		}
		if _, err := tx.Exec(ctx, `insert into conversation_tag(conversation_id, tag_id)
			values($1,$2) on conflict do nothing`, conversationID, tagID); err != nil {
			return false
		}
	}
	return tx.Commit(ctx) == nil
}

func (a *API) openUnread(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	var agent, visitor, conversations int64
	err := a.db.QueryRow(r.Context(), `select coalesce(sum(agent_unread),0),coalesce(sum(visitor_unread),0),count(*) filter(where agent_unread>0 or visitor_unread>0) from conversation where tenant_id=$1`, p.TenantID).Scan(&agent, &visitor, &conversations)
	if err != nil {
		fail(w, 500, "查询未读失败")
		return
	}
	respond(w, 200, map[string]any{"agentUnread": agent, "visitorUnread": visitor, "unreadConversations": conversations})
}
func (a *API) openReceipts(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	id, ok := a.openConversationID(w, r, p)
	if !ok {
		return
	}
	rows, err := a.db.Query(r.Context(), `select reader_type,reader_id,last_read_sequence,last_delivered_sequence,updated_at from conversation_read where conversation_id=$1 order by reader_type,reader_id`, id)
	if err != nil {
		fail(w, 500, "查询回执失败")
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var kind string
		var actor uuid.UUID
		var read, delivered int64
		var updated time.Time
		if rows.Scan(&kind, &actor, &read, &delivered, &updated) != nil {
			fail(w, 500, "查询回执失败")
			return
		}
		items = append(items, map[string]any{"readerType": kind, "readerId": actor, "readSequence": read, "deliveredSequence": delivered, "updatedAt": updated})
	}
	if rows.Err() != nil {
		fail(w, 500, "查询回执失败")
		return
	}
	respond(w, 200, map[string]any{"items": items})
}
func (a *API) openReceipt(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	id, ok := a.openConversationID(w, r, p)
	if !ok {
		return
	}
	var in struct {
		ReaderType string    `json:"readerType"`
		ReaderID   uuid.UUID `json:"readerId"`
		Sequence   int64     `json:"sequence"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Sequence <= 0 || (in.ReaderType != "AGENT" && in.ReaderType != "VISITOR") {
		fail(w, 400, "readerType 为 AGENT/VISITOR，sequence 必须大于零")
		return
	}
	var valid bool
	if in.ReaderType == "VISITOR" {
		_ = a.db.QueryRow(r.Context(), `select exists(select 1 from conversation where id=$1 and tenant_id=$2 and visitor_id=$3)`, id, p.TenantID, in.ReaderID).Scan(&valid)
	} else {
		_ = a.db.QueryRow(r.Context(), `select exists(select 1 from agent where id=$1 and tenant_id=$2 and status='ACTIVE' and email<>'bot@relaydesk.local')`, in.ReaderID, p.TenantID).Scan(&valid)
	}
	if !valid {
		fail(w, 404, "读取者不存在或不属于当前会话/企业")
		return
	}
	err := a.advanceReceipt(r.Context(), id, p.TenantID, in.ReaderType, in.ReaderID, in.Sequence, strings.HasSuffix(r.URL.Path, "/read"))
	if err != nil {
		fail(w, 500, "更新回执失败")
		return
	}
	a.openReceipts(w, r, p)
}
