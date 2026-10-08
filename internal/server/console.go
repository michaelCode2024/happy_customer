package server

import (
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/realtime"
	"github.com/relaydesk/relaydesk/internal/webhook"
)

func (a *API) registerConsole(mux *http.ServeMux) {
	// Authentication
	mux.HandleFunc("POST /api/v1/console/login", a.limit(a.loginRate, a.consoleLogin))
	mux.HandleFunc("POST /api/v1/console/logout", a.requireAgent(a.consoleLogout))
	mux.HandleFunc("GET /api/v1/console/me", a.requireAgent(a.consoleMe))
	mux.HandleFunc("PATCH /api/v1/console/me", a.requireAgent(a.consoleUpdateMe))
	mux.HandleFunc("POST /api/v1/console/me/password", a.requireAgent(a.consoleChangePassword))
	mux.HandleFunc("POST /api/v1/console/me/presence", a.requireAgent(a.consolePresence))

	// Conversations
	mux.HandleFunc("GET /api/v1/console/inboxes", a.requireAgent(a.consoleInboxes))
	mux.HandleFunc("GET /api/v1/console/conversations", a.requireAgent(a.consoleConversations))
	mux.HandleFunc("GET /api/v1/console/conversations/{id}", a.requireAgent(a.consoleConversation))
	mux.HandleFunc("GET /api/v1/console/conversations/{id}/messages", a.requireAgent(a.consoleMessages))
	mux.HandleFunc("POST /api/v1/console/conversations/{id}/messages", a.requireAgent(a.consoleSend))
	mux.HandleFunc("POST /api/v1/console/conversations/{id}/claim", a.requireAgent(a.consoleClaim))
	mux.HandleFunc("POST /api/v1/console/conversations/{id}/transfer", a.requireAgent(a.consoleTransfer))
	mux.HandleFunc("POST /api/v1/console/conversations/{id}/status", a.requireAgent(a.consoleStatus))
	mux.HandleFunc("POST /api/v1/console/conversations/{id}/read", a.requireAgent(a.consoleRead))
	mux.HandleFunc("POST /api/v1/console/conversations/{id}/delivered", a.requireAgent(a.consoleDelivered))
	mux.HandleFunc("POST /api/v1/console/conversations/{id}/typing", a.requireAgent(a.consoleTyping))
	mux.HandleFunc("POST /api/v1/console/conversations/{id}/tags", a.requireAgent(a.consoleSetTags))
	mux.HandleFunc("POST /api/v1/console/conversations/{id}/priority", a.requireAgent(a.consolePriority))

	// Message layer: quoting, editing, recall, reactions, pins, drafts, search.
	mux.HandleFunc("GET /api/v1/console/conversations/{id}/pins", a.requireAgent(a.consolePinnedMessages))
	mux.HandleFunc("GET /api/v1/console/conversations/{id}/search", a.requireAgent(a.consoleFindInConversation))
	mux.HandleFunc("GET /api/v1/console/conversations/{id}/draft", a.requireAgent(a.consoleDraft))
	mux.HandleFunc("PUT /api/v1/console/conversations/{id}/draft", a.requireAgent(a.consoleSaveDraft))
	mux.HandleFunc("PATCH /api/v1/console/conversations/{id}/messages/{messageId}", a.requireAgent(a.consoleEditMessage))
	mux.HandleFunc("DELETE /api/v1/console/conversations/{id}/messages/{messageId}", a.requireAgent(a.consoleDeleteMessage))
	mux.HandleFunc("POST /api/v1/console/conversations/{id}/messages/{messageId}/reactions", a.requireAgent(a.consoleReactMessage))
	mux.HandleFunc("POST /api/v1/console/conversations/{id}/messages/{messageId}/pin", a.requireAgent(a.consolePinMessage))
	mux.HandleFunc("POST /api/v1/console/conversations/{id}/messages/{messageId}/forward", a.requireAgent(a.consoleForwardMessage))
	mux.HandleFunc("GET /api/v1/console/search/messages", a.requireAgent(a.consoleSearchMessages))

	// Assistant: drafts only, never sent automatically. These are limited
	// separately from the rest of the console because each call costs the tenant
	// money at a third-party model gateway.
	mux.HandleFunc("POST /api/v1/console/assist", a.limit(a.aiAssistRate, a.requireAgent(a.consoleAssist)))
	mux.HandleFunc("POST /api/v1/console/assist/stream", a.limit(a.aiAssistRate, a.requireAgent(a.consoleAssistStream)))
	mux.HandleFunc("GET /api/v1/console/ai/usage", a.requireAgent(a.consoleAIUsage))

	// Customer data
	mux.HandleFunc("GET /api/v1/console/visitors/{id}", a.requireAgent(a.consoleVisitor))
	mux.HandleFunc("PATCH /api/v1/console/visitors/{id}", a.requireAgent(a.consoleUpdateVisitor))
	mux.HandleFunc("GET /api/v1/console/visitors/{id}/conversations", a.requireAgent(a.consoleVisitorConversations))
	mux.HandleFunc("POST /api/v1/console/visitors/{id}/notes", a.requireAgent(a.consoleAddNote))
	mux.HandleFunc("GET /api/v1/console/visitors/{id}/notes", a.requireAgent(a.consoleNotes))

	// Productivity
	mux.HandleFunc("GET /api/v1/console/canned-responses", a.requireAgent(a.consoleCannedResponses))
	mux.HandleFunc("POST /api/v1/console/canned-responses", a.requireAgent(a.consoleCreateCannedResponse))
	mux.HandleFunc("PATCH /api/v1/console/canned-responses/{id}", a.requireAgent(a.consoleUpdateCannedResponse))
	mux.HandleFunc("DELETE /api/v1/console/canned-responses/{id}", a.requireAgent(a.consoleDeleteCannedResponse))
	mux.HandleFunc("GET /api/v1/console/tags", a.requireAgent(a.consoleTags))
	mux.HandleFunc("GET /api/v1/console/stats/overview", a.requireAgent(a.consoleStats))
	mux.HandleFunc("GET /api/v1/console/agents", a.requireAgent(a.consoleAgents))

	// Knowledge base (the AI reads from the same tables)
	mux.HandleFunc("GET /api/v1/console/knowledge", a.requireAgent(a.consoleKnowledgeList))
	mux.HandleFunc("POST /api/v1/console/knowledge", a.requireRole([]string{auth.RoleOwner, auth.RoleAdmin, auth.RoleSupervisor}, a.consoleKnowledgeCreate))
	mux.HandleFunc("PATCH /api/v1/console/knowledge/{id}", a.requireRole([]string{auth.RoleOwner, auth.RoleAdmin, auth.RoleSupervisor}, a.consoleKnowledgeUpdate))
	mux.HandleFunc("DELETE /api/v1/console/knowledge/{id}", a.requireRole([]string{auth.RoleOwner, auth.RoleAdmin, auth.RoleSupervisor}, a.consoleKnowledgeDelete))
	mux.HandleFunc("POST /api/v1/console/knowledge/search", a.requireAgent(a.consoleKnowledgeSearch))
	mux.HandleFunc("POST /api/v1/console/knowledge/preview", a.requireAgent(a.consoleKnowledgePreview))

	// Realtime: the console multiplexes every inbox, conversation and presence
	// event over this one socket.
	mux.HandleFunc("GET /ws/console", a.consoleSocket)
}

// ---------------------------------------------------------------- authentication

func (a *API) consoleLogin(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Email      string `json:"email"`
		Password   string `json:"password"`
		TenantSlug string `json:"tenantSlug"`
	}
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.Email) == "" || in.Password == "" {
		fail(w, 400, "请输入邮箱和密码")
		return
	}
	account, err := a.authn.Login(r.Context(), in.Email, in.Password, in.TenantSlug)
	if err != nil {
		failCode(w, 401, "LOGIN_FAILED", err.Error())
		return
	}
	sessionID, _, err := a.authn.CreateSession(r.Context(), account.ID, int(a.cfg.AgentSessionTTL.Hours()))
	if err != nil {
		fail(w, 500, "创建会话失败")
		return
	}
	token, err := a.tokens.IssueAgent(auth.Principal{
		TenantID:  account.TenantID,
		AgentID:   account.ID,
		Email:     account.Email,
		Name:      account.DisplayName,
		Role:      account.Role,
		SessionID: sessionID,
	})
	if err != nil {
		fail(w, 500, "签发令牌失败")
		return
	}
	_, _ = a.db.Exec(r.Context(), `insert into agent_presence(agent_id, status, last_seen_at)
		values($1,'ONLINE', now())
		on conflict (agent_id) do update set status='ONLINE', last_seen_at = now()`, account.ID)
	a.recordAudit(r.Context(), account.TenantID, "AGENT", account.ID, "agent.login", "agent", account.ID, nil)

	var tenantName string
	_ = a.db.QueryRow(r.Context(), `select name from tenant where id=$1`, account.TenantID).Scan(&tenantName)
	inboxes, _ := a.agentInboxes(r.Context(), account.TenantID, account.ID)
	respond(w, 200, map[string]any{
		"token":     token,
		"expiresIn": int(a.cfg.AgentSessionTTL.Seconds()),
		"agent": map[string]any{
			"id": account.ID, "email": account.Email, "displayName": account.DisplayName, "role": account.Role,
		},
		"tenant":  map[string]any{"id": account.TenantID, "name": tenantName},
		"inboxes": inboxes,
	})
}

func (a *API) consoleLogout(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	_ = a.authn.RevokeSession(r.Context(), p.SessionID)
	_, _ = a.db.Exec(r.Context(), `insert into agent_presence(agent_id, status, last_seen_at) values($1,'OFFLINE', now())
		on conflict (agent_id) do update set status='OFFLINE', last_seen_at = now()`, p.AgentID)
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) consoleMe(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var displayName, email, role, presence string
	var maxConcurrent int
	err := a.db.QueryRow(r.Context(), `
		select ag.display_name, ag.email, ag.role, ag.max_concurrent, coalesce(ap.status,'OFFLINE')
		  from agent ag left join agent_presence ap on ap.agent_id = ag.id
		 where ag.id = $1 and ag.tenant_id = $2`, p.AgentID, p.TenantID).
		Scan(&displayName, &email, &role, &maxConcurrent, &presence)
	if err != nil {
		fail(w, 404, "坐席不存在")
		return
	}
	inboxes, _ := a.agentInboxes(r.Context(), p.TenantID, p.AgentID)
	var openConversations int
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from conversation
		where tenant_id=$1 and assignee_id=$2 and status <> 'RESOLVED'`, p.TenantID, p.AgentID).Scan(&openConversations)
	respond(w, 200, map[string]any{
		"id": p.AgentID, "email": email, "displayName": displayName, "role": role,
		"presence": presence, "maxConcurrent": maxConcurrent, "openConversations": openConversations,
		"inboxes": inboxes,
	})
}

func (a *API) consoleUpdateMe(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		DisplayName string `json:"displayName"`
	}
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.DisplayName) == "" {
		fail(w, 400, "显示名称不能为空")
		return
	}
	if _, err := a.db.Exec(r.Context(), `update agent set display_name=$1, updated_at=now() where id=$2 and tenant_id=$3`,
		in.DisplayName, p.AgentID, p.TenantID); err != nil {
		fail(w, 500, "更新资料失败")
		return
	}
	respond(w, 200, map[string]any{"status": "OK", "displayName": in.DisplayName})
}

func (a *API) consoleChangePassword(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		CurrentPassword string `json:"currentPassword"`
		NewPassword     string `json:"newPassword"`
	}
	if !decode(w, r, &in) {
		return
	}
	account, err := a.authn.Login(r.Context(), p.Email, in.CurrentPassword, "")
	if err != nil {
		failCode(w, 400, "PASSWORD_MISMATCH", "当前密码不正确")
		return
	}
	hash, err := auth.HashPassword(in.NewPassword)
	if err != nil {
		fail(w, 400, err.Error())
		return
	}
	if _, err := a.db.Exec(r.Context(), `update agent set password_hash=$1, updated_at=now() where id=$2`, hash, account.ID); err != nil {
		fail(w, 500, "更新密码失败")
		return
	}
	// Force every other session to log in again.
	_ = a.authn.RevokeAllSessions(r.Context(), account.ID)
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "agent.password_changed", "agent", p.AgentID, nil)
	respond(w, 200, map[string]any{"status": "OK", "message": "密码已更新，请重新登录"})
}

func (a *API) consolePresence(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Status string `json:"status"`
	}
	if !decode(w, r, &in) {
		return
	}
	status := strings.ToUpper(strings.TrimSpace(in.Status))
	if status != "ONLINE" && status != "AWAY" && status != "OFFLINE" {
		fail(w, 400, "状态只能是 ONLINE、AWAY 或 OFFLINE")
		return
	}
	if _, err := a.db.Exec(r.Context(), `insert into agent_presence(agent_id, status, last_seen_at) values($1,$2, now())
		on conflict (agent_id) do update set status=$2, last_seen_at = now()`, p.AgentID, status); err != nil {
		fail(w, 500, "更新状态失败")
		return
	}
	a.publish(r.Context(), []string{realtime.TenantChannel(p.TenantID.String())}, realtime.Event{
		Type: "agent.presence", TenantID: p.TenantID.String(),
		Data: map[string]any{"agentId": p.AgentID, "status": status},
	})
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) agentInboxes(ctx handlerContext, tenantID, agentID uuid.UUID) ([]map[string]any, error) {
	rows, err := a.db.Query(ctx, `
		select i.id, i.name, i.public_key, i.auto_assign,
		       coalesce(s.enabled,false)
		  from inbox i
		  join agent_inbox ai on ai.inbox_id = i.id
		  left join ai_setting s on s.inbox_id = i.id
		 where i.tenant_id = $1 and ai.agent_id = $2 and i.status = 'ACTIVE'
		 order by i.name`, tenantID, agentID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 4)
	for rows.Next() {
		var id uuid.UUID
		var name, publicKey string
		var autoAssign, aiEnabled bool
		if err := rows.Scan(&id, &name, &publicKey, &autoAssign, &aiEnabled); err != nil {
			return nil, err
		}
		items = append(items, map[string]any{"id": id, "name": name, "publicKey": publicKey, "autoAssign": autoAssign, "aiEnabled": aiEnabled})
	}
	return items, rows.Err()
}

func (a *API) consoleInboxes(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	inboxes, err := a.agentInboxes(r.Context(), p.TenantID, p.AgentID)
	if err != nil {
		fail(w, 500, "查询客服入口失败")
		return
	}
	respond(w, 200, map[string]any{"items": inboxes})
}

// ---------------------------------------------------------------- conversations

func (a *API) consoleConversations(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	filter := r.URL.Query().Get("filter")
	if filter == "" {
		filter = "mine"
	}
	limit := queryInt(r, "limit", 30)
	if limit > 100 {
		limit = 100
	}
	inboxID := r.URL.Query().Get("inboxId")
	search := strings.TrimSpace(r.URL.Query().Get("q"))
	status := strings.ToUpper(strings.TrimSpace(r.URL.Query().Get("status")))

	conditions := []string{"c.tenant_id = $1"}
	args := []any{p.TenantID}
	switch filter {
	case "mine":
		args = append(args, p.AgentID)
		conditions = append(conditions, "c.assignee_id = $"+itoa(len(args)))
	case "unassigned":
		conditions = append(conditions, "c.assignee_id is null")
	case "all":
	default:
		args = append(args, p.AgentID)
		conditions = append(conditions, "c.assignee_id = $"+itoa(len(args)))
	}
	if status != "" {
		args = append(args, status)
		conditions = append(conditions, "c.status = $"+itoa(len(args)))
	} else {
		conditions = append(conditions, "c.status <> 'RESOLVED'")
	}
	if inboxID != "" {
		if parsed, err := uuid.Parse(inboxID); err == nil {
			args = append(args, parsed)
			conditions = append(conditions, "c.inbox_id = $"+itoa(len(args)))
		}
	}
	if search != "" {
		args = append(args, search)
		index := itoa(len(args))
		conditions = append(conditions, "(coalesce(v.display_name,'') ilike '%' || $"+index+" || '%' or coalesce(c.last_message_preview,'') ilike '%' || $"+index+" || '%')")
	}
	// Agents only see conversations from inboxes they belong to.
	args = append(args, p.AgentID)
	conditions = append(conditions, "exists (select 1 from agent_inbox ai where ai.inbox_id = c.inbox_id and ai.agent_id = $"+itoa(len(args))+")")
	args = append(args, limit)

	query := `
		select c.id, c.tenant_id, c.inbox_id, c.visitor_id, coalesce(c.subject,''), c.status, c.assignee_id,
		       coalesce(ag.display_name,''), c.priority, c.source, c.last_sequence,
		       coalesce(c.last_message_preview,''), c.last_message_at, c.agent_unread, c.visitor_unread,
		       coalesce(v.display_name,''), c.created_at, c.updated_at
		  from conversation c
		  join visitor v on v.id = c.visitor_id
		  left join agent ag on ag.id = c.assignee_id
		 where ` + strings.Join(conditions, " and ") + `
		 order by c.priority desc, coalesce(c.last_message_at, c.created_at) desc
		 limit $` + itoa(len(args))

	rows, err := a.db.Query(r.Context(), query, args...)
	if err != nil {
		a.logger.Error("list conversations failed", "error", err)
		fail(w, 500, "查询会话失败")
		return
	}
	defer rows.Close()
	items := make([]conversationView, 0, limit)
	for rows.Next() {
		var item conversationView
		if err := scanConversation(rows, &item); err != nil {
			fail(w, 500, "查询会话失败")
			return
		}
		items = append(items, item)
	}
	var queued int
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from conversation
		where tenant_id=$1 and assignee_id is null and status <> 'RESOLVED'`, p.TenantID).Scan(&queued)
	respond(w, 200, map[string]any{"items": items, "queued": queued})
}

func (a *API) consoleConversation(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	var view conversationView
	if err := a.queryConversation(r.Context(), id, &view); err != nil {
		fail(w, 404, "会话不存在")
		return
	}
	var visitor map[string]any
	var visitorID uuid.UUID
	var displayName, externalID, email, phone string
	var attributes []byte
	var lastSeen *time.Time
	if a.db.QueryRow(r.Context(), `select id, coalesce(display_name,''), coalesce(external_id,''),
			coalesce(custom_attributes->>'email',''), coalesce(custom_attributes->>'phone',''),
			custom_attributes, last_seen_at
		  from visitor where id=$1`, view.VisitorID).
		Scan(&visitorID, &displayName, &externalID, &email, &phone, &attributes, &lastSeen) == nil {
		visitor = map[string]any{"id": visitorID, "displayName": displayName, "externalId": externalID,
			"email": email, "phone": phone, "attributes": rawJSON(attributes), "lastSeenAt": lastSeen}
	}
	var rating map[string]any
	var score int
	var comment *string
	var ratedAt time.Time
	if a.db.QueryRow(r.Context(), `select score, comment, created_at from conversation_rating where conversation_id=$1`, id).
		Scan(&score, &comment, &ratedAt) == nil {
		rating = map[string]any{"score": score, "comment": comment, "createdAt": ratedAt}
	}
	respond(w, 200, map[string]any{"conversation": view, "visitor": visitor, "rating": rating})
}

func (a *API) consoleMessages(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	// The console needs both directions: after= while new messages arrive on a
	// socket, before= when the agent scrolls back through the history.
	after := queryInt64(r, "after", 0)
	before := queryInt64(r, "before", 0)
	limit := queryInt(r, "limit", 50)
	page, err := a.pageMessages(r.Context(), id, after, before, limit, agentVisibility)
	if err != nil {
		fail(w, 500, "查询消息失败")
		return
	}
	var lastSequence int64
	var agentUnread int
	var visitorUnread int
	_ = a.db.QueryRow(r.Context(), `select last_sequence, agent_unread, visitor_unread from conversation where id=$1`, id).
		Scan(&lastSequence, &agentUnread, &visitorUnread)
	if page.LastSequence == 0 {
		page.LastSequence = lastSequence
	}
	// The read cursor of the assigned agent is the "new messages" divider
	// position: everything after it is what this agent has not seen yet.
	var lastRead int64
	_ = a.db.QueryRow(r.Context(), `select coalesce(last_read_sequence,0) from conversation_read
		where conversation_id=$1 and reader_type='AGENT' and reader_id=$2`, id, p.AgentID).Scan(&lastRead)
	respond(w, 200, map[string]any{
		"items": page.Items, "hasMore": page.HasMore, "hasOlder": page.HasOlder,
		"firstSequence": page.FirstSequence, "lastSequence": page.LastSequence,
		"agentUnread": agentUnread, "visitorUnread": visitorUnread, "lastReadSequence": lastRead,
	})
}

func (a *API) consoleSend(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	var in struct {
		ClientMessageID string         `json:"clientMessageId"`
		Content         string         `json:"content"`
		MessageType     string         `json:"messageType"`
		AttachmentIDs   []string       `json:"attachmentIds"`
		Private         bool           `json:"private"`
		Metadata        map[string]any `json:"metadata"`
		ReplyToID       string         `json:"replyToId"`
	}
	if !decode(w, r, &in) {
		return
	}
	messageType := strings.ToUpper(strings.TrimSpace(in.MessageType))
	if messageType == "" {
		messageType = "TEXT"
	}
	switch messageType {
	case "TEXT", "IMAGE", "FILE", "AUDIO", "VIDEO", "LOCATION", "CARD", "RICH":
	default:
		fail(w, 400, "不支持的消息类型")
		return
	}
	var replyTo *uuid.UUID
	if strings.TrimSpace(in.ReplyToID) != "" {
		parsed, err := uuid.Parse(in.ReplyToID)
		if err != nil {
			fail(w, 400, "引用的消息不存在")
			return
		}
		var exists bool
		_ = a.db.QueryRow(r.Context(), `select exists(select 1 from message where id=$1 and conversation_id=$2)`,
			parsed, id).Scan(&exists)
		if !exists {
			fail(w, 400, "引用的消息不存在")
			return
		}
		replyTo = &parsed
	}
	if in.Private {
		// An internal note is an EVENT carrying is_private, an agent-only object.
		// It is stored with the flag as a real column rather than only in
		// metadata, because the read paths filter on the column: a note that
		// lived in metadata alone was one forgotten where-clause away from the
		// visitor.
		view, err := a.appendMessage(r.Context(), p.TenantID, id, messageInput{
			SenderType: "AGENT", SenderID: &p.AgentID, MessageType: "EVENT",
			Content: in.Content, Metadata: in.Metadata, Private: true, ReplyToID: replyTo,
		})
		if err != nil {
			fail(w, 500, "发送内部备注失败")
			return
		}
		view.SenderName = p.Name
		respond(w, 201, view)
		return
	}
	if messageType == "TEXT" && strings.TrimSpace(in.Content) == "" {
		fail(w, 400, "消息内容不能为空")
		return
	}
	if messageType != "TEXT" && messageType != "CARD" && messageType != "RICH" && len(in.AttachmentIDs) == 0 {
		fail(w, 400, "该消息类型必须先上传附件")
		return
	}
	view, err := a.appendMessage(r.Context(), p.TenantID, id, messageInput{
		SenderType:      "AGENT",
		SenderID:        &p.AgentID,
		ClientMessageID: in.ClientMessageID,
		MessageType:     messageType,
		Content:         in.Content,
		AttachmentIDs:   in.AttachmentIDs,
		Metadata:        in.Metadata,
		ReplyToID:       replyTo,
	})
	if err != nil {
		a.logger.Error("agent message failed", "error", err)
		fail(w, 500, "发送消息失败")
		return
	}
	// Sending an answer clears the draft: keeping it would hand the agent a
	// stale copy of text they already sent the next time they open the thread.
	_, _ = a.db.Exec(r.Context(), `delete from message_draft where conversation_id=$1 and agent_id=$2`, id, p.AgentID)
	view.SenderName = p.Name
	respond(w, 201, view)
}

func (a *API) consoleClaim(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	tag, err := a.db.Exec(r.Context(), `update conversation
		set assignee_id = $3, assigned_at = now(), updated_at = now()
		where id = $1 and tenant_id = $2 and (assignee_id is null or assignee_id = $3)`, id, p.TenantID, p.AgentID)
	if err != nil {
		fail(w, 500, "领取会话失败")
		return
	}
	if tag.RowsAffected() == 0 {
		var owner string
		_ = a.db.QueryRow(r.Context(), `select coalesce(ag.display_name,'其他坐席') from conversation c
			left join agent ag on ag.id = c.assignee_id where c.id = $1`, id).Scan(&owner)
		failCode(w, 409, "ALREADY_ASSIGNED", "该会话已被 "+owner+" 领取")
		return
	}
	a.publish(r.Context(), a.conversationChannels(r.Context(), id), realtime.Event{
		Type: "conversation.assigned", TenantID: p.TenantID.String(), ConversationID: id.String(),
		Data: map[string]any{"assigneeId": p.AgentID, "assigneeName": p.Name},
	})
	a.notifyWebhook(r.Context(), p.TenantID, webhook.EventConversationUpdated, map[string]any{
		"conversationId": id, "assigneeId": p.AgentID,
	})
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) consoleTransfer(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	var in struct {
		AgentID string `json:"agentId"`
		Note    string `json:"note"`
	}
	if !decode(w, r, &in) {
		return
	}
	target, err := uuid.Parse(in.AgentID)
	if err != nil {
		fail(w, 400, "目标坐席 ID 不合法")
		return
	}
	var targetName string
	var sameTenant bool
	err = a.db.QueryRow(r.Context(), `select display_name, tenant_id = $3 from agent
		where id = $1 and status = 'ACTIVE'`, target, target, p.TenantID).Scan(&targetName, &sameTenant)
	if err != nil || !sameTenant {
		fail(w, 404, "目标坐席不存在")
		return
	}
	if _, err := a.db.Exec(r.Context(), `update conversation set assignee_id=$3, assigned_at=now(), updated_at=now()
		where id=$1 and tenant_id=$2`, id, p.TenantID, target); err != nil {
		fail(w, 500, "转接失败")
		return
	}
	if strings.TrimSpace(in.Note) != "" {
		_, _ = a.appendMessage(r.Context(), p.TenantID, id, messageInput{
			SenderType: "AGENT", SenderID: &p.AgentID, MessageType: "EVENT",
			Content:  "转接给 " + targetName + "：" + in.Note,
			Metadata: map[string]any{"transfer": true, "to": target},
			Private:  true,
		})
	}
	a.publish(r.Context(), a.conversationChannels(r.Context(), id), realtime.Event{
		Type: "conversation.transferred", TenantID: p.TenantID.String(), ConversationID: id.String(),
		Data: map[string]any{"assigneeId": target, "assigneeName": targetName, "from": p.AgentID},
	})
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "conversation.transfer", "conversation", id,
		map[string]any{"to": target})
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) consoleStatus(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	var in struct {
		Status string `json:"status"`
	}
	if !decode(w, r, &in) {
		return
	}
	status := strings.ToUpper(strings.TrimSpace(in.Status))
	if status != "OPEN" && status != "PENDING" && status != "RESOLVED" {
		fail(w, 400, "状态只能是 OPEN、PENDING 或 RESOLVED")
		return
	}
	if status == "RESOLVED" {
		if _, err := a.db.Exec(r.Context(), `update conversation
			set status='RESOLVED', closed_at=now(), updated_at=now(), agent_unread=0
			where id=$1 and tenant_id=$2`, id, p.TenantID); err != nil {
			fail(w, 500, "更新状态失败")
			return
		}
		a.bumpDailyStat(r.Context(), p.TenantID, "conversations_closed")
		a.publish(r.Context(), a.conversationChannels(r.Context(), id), realtime.Event{
			Type: "conversation.closed", TenantID: p.TenantID.String(), ConversationID: id.String(),
			Data: map[string]any{"closedBy": p.AgentID},
		})
		a.notifyWebhook(r.Context(), p.TenantID, webhook.EventConversationClosed, map[string]any{
			"conversationId": id, "closedBy": p.AgentID, "closedAt": nowUTC(),
		})
		respond(w, 200, map[string]any{"status": "OK"})
		return
	}
	if _, err := a.db.Exec(r.Context(), `update conversation set status=$3, updated_at=now()
		where id=$1 and tenant_id=$2`, id, p.TenantID, status); err != nil {
		fail(w, 500, "更新状态失败")
		return
	}
	a.publish(r.Context(), a.conversationChannels(r.Context(), id), realtime.Event{
		Type: "conversation.status", TenantID: p.TenantID.String(), ConversationID: id.String(),
		Data: map[string]any{"status": status},
	})
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) consoleRead(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	var in markReadRequest
	if !decode(w, r, &in) {
		return
	}
	a.markRead(r.Context(), id, p.TenantID, "AGENT", p.AgentID, in.Sequence)
	respond(w, 200, map[string]any{"status": "OK"})
}

// consoleDelivered records that the console received a message. It is separate
// from reading it so the visitor's client can render a delivered tick while the
// agent still has the thread open in another tab.
func (a *API) consoleDelivered(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	var in markReadRequest
	if !decode(w, r, &in) {
		return
	}
	a.markDelivered(r.Context(), id, p.TenantID, "AGENT", p.AgentID, in.Sequence)
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) consoleTyping(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	a.publish(r.Context(), []string{realtime.ConversationChannel(id.String())}, realtime.Event{
		Type: "typing", TenantID: p.TenantID.String(), ConversationID: id.String(),
		Data: map[string]any{"actorType": "AGENT", "actorId": p.AgentID, "actorName": p.Name},
	})
	respond(w, 202, map[string]any{"status": "OK"})
}

func (a *API) consoleSetTags(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	var in struct {
		Tags []string `json:"tags"`
	}
	if !decode(w, r, &in) {
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "更新标签失败")
		return
	}
	defer tx.Rollback(r.Context()) //nolint:errcheck
	if _, err := tx.Exec(r.Context(), `delete from conversation_tag where conversation_id=$1`, id); err != nil {
		fail(w, 500, "更新标签失败")
		return
	}
	for _, name := range in.Tags {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		if _, err := tx.Exec(r.Context(), `insert into tag(id, tenant_id, name) values($1,$2,$3)
			on conflict (tenant_id, lower(name)) do nothing`, uuid.New(), p.TenantID, name); err != nil {
			fail(w, 500, "更新标签失败")
			return
		}
		if _, err := tx.Exec(r.Context(), `insert into conversation_tag(conversation_id, tag_id)
			select $1, id from tag where tenant_id=$2 and lower(name)=lower($3)
			on conflict do nothing`, id, p.TenantID, name); err != nil {
			fail(w, 500, "更新标签失败")
			return
		}
	}
	if err := tx.Commit(r.Context()); err != nil {
		fail(w, 500, "更新标签失败")
		return
	}
	tags, _ := a.conversationTags(r.Context(), id)
	respond(w, 200, map[string]any{"tags": tags})
}

func (a *API) consolePriority(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	var in struct {
		Priority int `json:"priority"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Priority < 0 || in.Priority > 3 {
		fail(w, 400, "优先级必须是 0 到 3")
		return
	}
	if _, err := a.db.Exec(r.Context(), `update conversation set priority=$3, updated_at=now() where id=$1 and tenant_id=$2`,
		id, p.TenantID, in.Priority); err != nil {
		fail(w, 500, "更新优先级失败")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

// consoleConversationScope enforces that the conversation belongs to the agent's
// tenant and to an inbox the agent is a member of.
func (a *API) consoleConversationScope(w http.ResponseWriter, r *http.Request, p auth.Principal) (uuid.UUID, bool) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "会话 ID 不合法")
		return uuid.Nil, false
	}
	var allowed bool
	err = a.db.QueryRow(r.Context(), `
		select exists(
			select 1 from conversation c
			 where c.id = $1 and c.tenant_id = $2
			   and (exists (select 1 from agent_inbox ai where ai.inbox_id = c.inbox_id and ai.agent_id = $3)
			        or c.assignee_id = $3))`, id, p.TenantID, p.AgentID).Scan(&allowed)
	if err != nil || !allowed {
		failCode(w, 404, "CONVERSATION_NOT_FOUND", "会话不存在或你没有该客服入口的权限")
		return uuid.Nil, false
	}
	return id, true
}

// ---------------------------------------------------------------- customer data

func (a *API) consoleVisitor(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "访客 ID 不合法")
		return
	}
	var displayName, externalID, email, phone string
	var attributes []byte
	var lastSeen *time.Time
	var createdAt time.Time
	err = a.db.QueryRow(r.Context(), `select coalesce(display_name,''), coalesce(external_id,''),
			coalesce(custom_attributes->>'email',''), coalesce(custom_attributes->>'phone',''),
			custom_attributes, last_seen_at, created_at
		  from visitor where id=$1 and tenant_id=$2`, id, p.TenantID).
		Scan(&displayName, &externalID, &email, &phone, &attributes, &lastSeen, &createdAt)
	if err != nil {
		fail(w, 404, "访客不存在")
		return
	}
	var conversationCount int
	var ratingAverage *float64
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from conversation where visitor_id=$1`, id).Scan(&conversationCount)
	_ = a.db.QueryRow(r.Context(), `select avg(r.score)::float8 from conversation_rating r
		join conversation c on c.id = r.conversation_id where c.visitor_id = $1`, id).Scan(&ratingAverage)
	respond(w, 200, map[string]any{
		"id": id, "displayName": displayName, "externalId": externalID, "email": email, "phone": phone,
		"attributes": rawJSON(attributes), "lastSeenAt": lastSeen, "createdAt": createdAt,
		"conversationCount": conversationCount, "ratingAverage": ratingAverage,
	})
}

func (a *API) consoleUpdateVisitor(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "访客 ID 不合法")
		return
	}
	var in struct {
		DisplayName string         `json:"displayName"`
		Attributes  map[string]any `json:"attributes"`
	}
	if !decode(w, r, &in) {
		return
	}
	attributes, _ := jsonBytes(orEmpty(in.Attributes))
	tag, err := a.db.Exec(r.Context(), `update visitor
		set display_name = coalesce(nullif($3,''), display_name),
		    custom_attributes = custom_attributes || $4::jsonb,
		    updated_at = now()
		where id=$1 and tenant_id=$2`, id, p.TenantID, in.DisplayName, attributes)
	if err != nil {
		fail(w, 500, "更新客户资料失败")
		return
	}
	if tag.RowsAffected() == 0 {
		fail(w, 404, "访客不存在")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) consoleVisitorConversations(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "访客 ID 不合法")
		return
	}
	rows, err := a.db.Query(r.Context(), `
		select c.id, c.tenant_id, c.inbox_id, c.visitor_id, coalesce(c.subject,''), c.status, c.assignee_id,
		       coalesce(ag.display_name,''), c.priority, c.source, c.last_sequence,
		       coalesce(c.last_message_preview,''), c.last_message_at, c.agent_unread, c.visitor_unread,
		       coalesce(v.display_name,''), c.created_at, c.updated_at
		  from conversation c
		  join visitor v on v.id = c.visitor_id
		  left join agent ag on ag.id = c.assignee_id
		 where c.visitor_id = $1 and c.tenant_id = $2
		 order by coalesce(c.last_message_at, c.created_at) desc
		 limit 50`, id, p.TenantID)
	if err != nil {
		fail(w, 500, "查询会话失败")
		return
	}
	defer rows.Close()
	items := make([]conversationView, 0, 8)
	for rows.Next() {
		var item conversationView
		if err := scanConversation(rows, &item); err != nil {
			fail(w, 500, "查询会话失败")
			return
		}
		items = append(items, item)
	}
	respond(w, 200, map[string]any{"items": items})
}

func (a *API) consoleAddNote(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "访客 ID 不合法")
		return
	}
	var in struct {
		Content string `json:"content"`
	}
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.Content) == "" {
		fail(w, 400, "备注内容不能为空")
		return
	}
	noteID := uuid.New()
	tag, err := a.db.Exec(r.Context(), `insert into visitor_note(id, tenant_id, visitor_id, author_agent_id, content)
		select $1,$2,$3,$4,$5 where exists (select 1 from visitor where id=$3 and tenant_id=$2)`,
		noteID, p.TenantID, id, p.AgentID, in.Content)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "访客不存在")
		return
	}
	respond(w, 201, map[string]any{"id": noteID, "content": in.Content, "authorName": p.Name, "createdAt": nowUTC()})
}

func (a *API) consoleNotes(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "访客 ID 不合法")
		return
	}
	rows, err := a.db.Query(r.Context(), `select n.id, n.content, coalesce(ag.display_name,'系统'), n.created_at
		  from visitor_note n left join agent ag on ag.id = n.author_agent_id
		 where n.visitor_id = $1 and n.tenant_id = $2
		 order by n.created_at desc limit 100`, id, p.TenantID)
	if err != nil {
		fail(w, 500, "查询备注失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 8)
	for rows.Next() {
		var noteID uuid.UUID
		var content, author string
		var createdAt time.Time
		if err := rows.Scan(&noteID, &content, &author, &createdAt); err != nil {
			fail(w, 500, "查询备注失败")
			return
		}
		items = append(items, map[string]any{"id": noteID, "content": content, "authorName": author, "createdAt": createdAt})
	}
	respond(w, 200, map[string]any{"items": items})
}
