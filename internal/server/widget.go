package server

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/realtime"
	"github.com/relaydesk/relaydesk/internal/webhook"
)

// messageView is the wire representation of a chat message. The same shape is
// returned by the visitor API, the agent API and the open API.
type messageView struct {
	ID              uuid.UUID       `json:"id"`
	ConversationID  uuid.UUID       `json:"conversationId"`
	SenderType      string          `json:"senderType"`
	SenderID        *uuid.UUID      `json:"senderId,omitempty"`
	SenderName      string          `json:"senderName,omitempty"`
	ClientMessageID *string         `json:"clientMessageId,omitempty"`
	Sequence        int64           `json:"sequence"`
	MessageType     string          `json:"messageType"`
	Content         string          `json:"content"`
	Metadata        json.RawMessage `json:"metadata,omitempty"`
	Attachments     []attachmentView `json:"attachments,omitempty"`
	CreatedAt       time.Time       `json:"createdAt"`
}

type attachmentView struct {
	ID          uuid.UUID `json:"id"`
	FileName    string    `json:"fileName"`
	ContentType string    `json:"contentType"`
	SizeBytes   int64     `json:"sizeBytes"`
	URL         string    `json:"url"`
}

type conversationView struct {
	ID                 uuid.UUID  `json:"id"`
	TenantID           uuid.UUID  `json:"tenantId"`
	InboxID            uuid.UUID  `json:"inboxId"`
	VisitorID          uuid.UUID  `json:"visitorId"`
	Subject            string     `json:"subject,omitempty"`
	Status             string     `json:"status"`
	AssigneeID         *uuid.UUID `json:"assigneeId,omitempty"`
	AssigneeName       string     `json:"assigneeName,omitempty"`
	Priority           int16      `json:"priority"`
	Source             string     `json:"source"`
	LastSequence       int64      `json:"lastSequence"`
	LastMessagePreview string     `json:"lastMessagePreview,omitempty"`
	LastMessageAt      *time.Time `json:"lastMessageAt,omitempty"`
	AgentUnread        int        `json:"agentUnread"`
	VisitorUnread      int        `json:"visitorUnread"`
	VisitorName        string     `json:"visitorName,omitempty"`
	Tags               []string   `json:"tags,omitempty"`
	CreatedAt          time.Time  `json:"createdAt"`
	UpdatedAt          time.Time  `json:"updatedAt"`
}

func (a *API) registerWidget(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/widget/bootstrap", a.limit(a.widgetRate, a.widgetBootstrap))
	mux.HandleFunc("POST /api/v1/widget/conversations", a.requireWidget(a.createConversation))
	mux.HandleFunc("GET /api/v1/widget/conversations", a.requireWidget(a.listConversations))
	mux.HandleFunc("GET /api/v1/widget/conversations/{id}", a.requireWidget(a.getConversation))
	mux.HandleFunc("GET /api/v1/widget/conversations/{id}/messages", a.requireWidget(a.listMessages))
	mux.HandleFunc("POST /api/v1/widget/conversations/{id}/messages", a.limit(a.widgetRate, a.requireWidget(a.postMessage)))
	mux.HandleFunc("POST /api/v1/widget/conversations/{id}/read", a.requireWidget(a.markVisitorRead))
	mux.HandleFunc("POST /api/v1/widget/conversations/{id}/typing", a.requireWidget(a.visitorTyping))
	mux.HandleFunc("POST /api/v1/widget/conversations/{id}/rating", a.requireWidget(a.rateConversation))

	// Realtime. The visitor token travels in the query string because browsers
	// cannot set headers on the WebSocket handshake.
	mux.HandleFunc("GET /ws/widget", a.widgetSocket)
}

type bootstrapRequest struct {
	InboxKey    string `json:"inboxKey"`
	ExternalID  string `json:"externalId"`
	DisplayName string `json:"displayName"`
	Email       string `json:"email"`
	Phone       string `json:"phone"`
	Locale      string `json:"locale"`
	Attributes  map[string]any `json:"attributes"`
	Referrer    string `json:"referrer"`
}

func (a *API) widgetBootstrap(w http.ResponseWriter, r *http.Request) {
	var in bootstrapRequest
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.InboxKey) == "" {
		fail(w, 400, "缺少 inboxKey")
		return
	}
	inbox, err := a.loadInbox(r.Context(), in.InboxKey)
	if err != nil {
		fail(w, 404, err.Error())
		return
	}
	attributes, _ := json.Marshal(orEmpty(in.Attributes))
	var visitorID uuid.UUID
	displayName := nullable(in.DisplayName)
	if strings.TrimSpace(in.ExternalID) != "" {
		err = a.db.QueryRow(r.Context(), `
			insert into visitor(id, tenant_id, inbox_id, external_id, display_name, custom_attributes, last_seen_at)
			values($1,$2,$3,$4,$5,$6, now())
			on conflict (inbox_id, external_id) where external_id is not null
			do update set display_name = coalesce(excluded.display_name, visitor.display_name),
			              custom_attributes = visitor.custom_attributes || excluded.custom_attributes,
			              updated_at = now(), last_seen_at = now()
			returning id`, uuid.New(), inbox.TenantID, inbox.ID, in.ExternalID, displayName, attributes).Scan(&visitorID)
	} else {
		err = a.db.QueryRow(r.Context(), `
			insert into visitor(id, tenant_id, inbox_id, display_name, custom_attributes, last_seen_at)
			values($1,$2,$3,$4,$5, now()) returning id`,
			uuid.New(), inbox.TenantID, inbox.ID, displayName, attributes).Scan(&visitorID)
	}
	if err != nil {
		a.logger.Error("visitor bootstrap failed", "error", err)
		fail(w, 500, "初始化访客失败")
		return
	}
	token, err := a.tokens.IssueWidget(inbox.TenantID, inbox.ID, visitorID)
	if err != nil {
		fail(w, 500, "签发令牌失败")
		return
	}
	var openConversations int
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from conversation
		where visitor_id=$1 and status <> 'RESOLVED'`, visitorID).Scan(&openConversations)

	respond(w, 200, map[string]any{
		"visitorId":         visitorID,
		"displayName":       in.DisplayName,
		"token":             token,
		"expiresIn":         int(a.cfg.WidgetTokenTTL.Seconds()),
		"inbox":             map[string]any{"id": inbox.ID, "name": inbox.Name, "welcomeMessage": inbox.WelcomeMessage, "offlineMessage": inbox.OfflineMessage},
		"aiEnabled":         inbox.AIEnabled && a.ai.Available() && a.cfg.AI.AutoReplyEnabled,
		"agentsOnline":      inbox.AgentsAvailable,
		"openConversations": openConversations,
		"serverTime":        nowUTC(),
	})
}

func (a *API) createConversation(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Subject string  `json:"subject"`
		Content *string `json:"content"`
		Source  string  `json:"source"`
	}
	if !decode(w, r, &in) {
		return
	}
	source := strings.ToUpper(strings.TrimSpace(in.Source))
	if source == "" {
		source = "WEB"
	}
	if source != "WEB" && source != "H5" && source != "APP" && source != "PC" && source != "API" {
		fail(w, 400, "source 只能是 WEB、H5、APP、PC 或 API")
		return
	}
	conversationID := uuid.New()
	now := nowUTC()
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "创建会话失败")
		return
	}
	defer tx.Rollback(r.Context()) //nolint:errcheck
	if _, err := tx.Exec(r.Context(), `
		insert into conversation(id, tenant_id, inbox_id, visitor_id, subject, status, source, last_sequence,
			last_message_at, created_at, updated_at)
		values($1,$2,$3,$4,$5,'OPEN',$6,0,$7,$7,$7)`,
		conversationID, p.TenantID, p.InboxID, p.VisitorID, nullable(in.Subject), source, now); err != nil {
		a.logger.Error("create conversation failed", "error", err)
		fail(w, 500, "创建会话失败")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		fail(w, 500, "创建会话失败")
		return
	}

	var view conversationView
	if err := a.queryConversation(r.Context(), conversationID, &view); err != nil {
		fail(w, 500, "创建会话失败")
		return
	}
	a.publish(r.Context(), a.conversationChannels(r.Context(), conversationID), realtime.Event{
		Type: "conversation.created", TenantID: p.TenantID.String(), ConversationID: conversationID.String(), Data: view,
	})
	a.notifyWebhook(r.Context(), p.TenantID, webhook.EventConversationCreated, map[string]any{
		"conversationId": conversationID, "visitorId": p.VisitorID, "inboxId": p.InboxID, "source": source, "createdAt": now,
	})
	a.bumpDailyStat(r.Context(), p.TenantID, "conversations_started")

	// A first message can be supplied with the conversation so the visitor sees
	// the bot or agent answer without a second round trip.
	if in.Content != nil && strings.TrimSpace(*in.Content) != "" {
		saved, err := a.appendVisitorMessage(r.Context(), p, conversationID, *in.Content, "", "TEXT", nil, nil)
		if err == nil {
			respond(w, 201, map[string]any{"conversation": view, "message": saved})
			return
		}
	}
	respond(w, 201, map[string]any{"conversation": view})
}

func (a *API) listConversations(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	rows, err := a.db.Query(r.Context(), `
		select c.id, c.tenant_id, c.inbox_id, c.visitor_id, coalesce(c.subject,''), c.status, c.assignee_id,
		       coalesce(ag.display_name,''), c.priority, c.source, c.last_sequence,
		       coalesce(c.last_message_preview,''), c.last_message_at, c.agent_unread, c.visitor_unread,
		       coalesce(v.display_name,''), c.created_at, c.updated_at
		  from conversation c
		  join visitor v on v.id = c.visitor_id
		  left join agent ag on ag.id = c.assignee_id
		 where c.tenant_id=$1 and c.inbox_id=$2 and c.visitor_id=$3 and c.status <> 'RESOLVED'
		 order by coalesce(c.last_message_at, c.created_at) desc
		 limit 50`, p.TenantID, p.InboxID, p.VisitorID)
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

func (a *API) getConversation(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.visitorConversation(w, r, p)
	if !ok {
		return
	}
	var view conversationView
	if err := a.queryConversation(r.Context(), id, &view); err != nil {
		fail(w, 404, "会话不存在")
		return
	}
	respond(w, 200, view)
}

func (a *API) listMessages(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.visitorConversation(w, r, p)
	if !ok {
		return
	}
	after := queryInt64(r, "after", 0)
	limit := queryInt(r, "limit", 50)
	if limit > 200 {
		limit = 200
	}
	items, err := a.fetchMessages(r.Context(), id, after, limit)
	if err != nil {
		fail(w, 500, "查询消息失败")
		return
	}
	var lastSequence int64
	_ = a.db.QueryRow(r.Context(), `select last_sequence from conversation where id=$1`, id).Scan(&lastSequence)
	var visitorUnread int
	_ = a.db.QueryRow(r.Context(), `select visitor_unread from conversation where id=$1`, id).Scan(&visitorUnread)
	respond(w, 200, map[string]any{"items": items, "lastSequence": lastSequence, "hasMore": len(items) == limit})
}

func (a *API) postMessage(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.visitorConversation(w, r, p)
	if !ok {
		return
	}
	var in struct {
		ClientMessageID string  `json:"clientMessageId"`
		Content         string  `json:"content"`
		MessageType     string  `json:"messageType"`
		AttachmentIDs   []string `json:"attachmentIds"`
	}
	if !decode(w, r, &in) {
		return
	}
	in.MessageType = strings.ToUpper(strings.TrimSpace(in.MessageType))
	if in.MessageType == "" {
		in.MessageType = "TEXT"
	}
	if in.MessageType == "TEXT" && strings.TrimSpace(in.Content) == "" {
		fail(w, 400, "消息内容不能为空")
		return
	}
	if in.MessageType != "TEXT" && len(in.AttachmentIDs) == 0 {
		fail(w, 400, "图片或文件消息必须先上传附件")
		return
	}
	view, err := a.appendVisitorMessage(r.Context(), p, id, in.Content, in.ClientMessageID, in.MessageType, in.AttachmentIDs, nil)
	if err != nil {
		if isNotFound(err) {
			fail(w, 404, "会话不存在或已结束")
			return
		}
		a.logger.Error("visitor message failed", "error", err)
		fail(w, 500, "发送消息失败")
		return
	}
	respond(w, 201, view)
}

func (a *API) markVisitorRead(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.visitorConversation(w, r, p)
	if !ok {
		return
	}
	var in markReadRequest
	if !decode(w, r, &in) {
		return
	}
	a.markRead(r.Context(), id, p.TenantID, "VISITOR", p.VisitorID, in.Sequence)
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) visitorTyping(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.visitorConversation(w, r, p)
	if !ok {
		return
	}
	a.publish(r.Context(), a.conversationChannels(r.Context(), id), realtime.Event{
		Type: "typing", TenantID: p.TenantID.String(), ConversationID: id.String(),
		Data: map[string]any{"actorType": "VISITOR", "actorId": p.VisitorID},
	})
	respond(w, 202, map[string]any{"status": "OK"})
}

func (a *API) rateConversation(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.visitorConversation(w, r, p)
	if !ok {
		return
	}
	var in struct {
		Score   int    `json:"score"`
		Comment string `json:"comment"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Score < 1 || in.Score > 5 {
		fail(w, 400, "评分必须是 1 到 5")
		return
	}
	if _, err := a.db.Exec(r.Context(), `
		insert into conversation_rating(conversation_id, tenant_id, score, comment)
		values($1,$2,$3,$4)
		on conflict (conversation_id) do update set score = excluded.score, comment = excluded.comment, created_at = now()`,
		id, p.TenantID, in.Score, nullable(in.Comment)); err != nil {
		fail(w, 500, "提交评价失败")
		return
	}
	a.bumpDailyStat(r.Context(), p.TenantID, "rating", in.Score)
	a.publish(r.Context(), a.conversationChannels(r.Context(), id), realtime.Event{
		Type: "conversation.rated", TenantID: p.TenantID.String(), ConversationID: id.String(),
		Data: map[string]any{"score": in.Score},
	})
	respond(w, 201, map[string]any{"status": "OK"})
}

// visitorConversation validates that the path conversation belongs to the
// visitor holding the token, which is the tenant-isolation boundary.
func (a *API) visitorConversation(w http.ResponseWriter, r *http.Request, p auth.Principal) (uuid.UUID, bool) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "会话 ID 不合法")
		return uuid.Nil, false
	}
	var exists bool
	err = a.db.QueryRow(r.Context(), `select exists(select 1 from conversation
		where id=$1 and tenant_id=$2 and inbox_id=$3 and visitor_id=$4)`,
		id, p.TenantID, p.InboxID, p.VisitorID).Scan(&exists)
	if err != nil || !exists {
		failCode(w, 404, "CONVERSATION_NOT_FOUND", "会话不存在")
		return uuid.Nil, false
	}
	return id, true
}

var errNotFound = pgx.ErrNoRows

func isNotFound(err error) bool { return err == pgx.ErrNoRows }

func orEmpty(value map[string]any) map[string]any {
	if value == nil {
		return map[string]any{}
	}
	return value
}
