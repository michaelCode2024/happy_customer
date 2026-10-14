package server

import (
	"encoding/json"
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

// messageView is the wire representation of a chat message. The same shape is
// returned by the visitor API, the agent API and the open API.
type messageView struct {
	ID              uuid.UUID        `json:"id"`
	ConversationID  uuid.UUID        `json:"conversationId"`
	SenderType      string           `json:"senderType"`
	SenderID        *uuid.UUID       `json:"senderId,omitempty"`
	SenderName      string           `json:"senderName,omitempty"`
	ClientMessageID *string          `json:"clientMessageId,omitempty"`
	Sequence        int64            `json:"sequence"`
	MessageType     string           `json:"messageType"`
	Content         string           `json:"content"`
	Metadata        json.RawMessage  `json:"metadata,omitempty"`
	Attachments     []attachmentView `json:"attachments,omitempty"`
	CreatedAt       time.Time        `json:"createdAt"`

	// Private marks an internal note. The field is present on every message so
	// the console can render the note style without inspecting metadata, and it
	// is never true on a message a visitor principal received.
	Private         bool                  `json:"private,omitempty"`
	ReplyToID       *uuid.UUID            `json:"replyToId,omitempty"`
	ReplyTo         *replyPreview         `json:"replyTo,omitempty"`
	ForwardedFromID *uuid.UUID            `json:"forwardedFromId,omitempty"`
	Reactions       []messageReactionView `json:"reactions,omitempty"`
	// EditedAt and DeletedAt drive the "已编辑" marker and the recall tombstone.
	// A recalled message keeps its row and its sequence so a client that already
	// rendered it can replace the bubble instead of shifting the transcript.
	EditedAt  *time.Time `json:"editedAt,omitempty"`
	DeletedAt *time.Time `json:"deletedAt,omitempty"`
	PinnedAt  *time.Time `json:"pinnedAt,omitempty"`
}

type attachmentView struct {
	ID          uuid.UUID `json:"id"`
	FileName    string    `json:"fileName"`
	ContentType string    `json:"contentType"`
	SizeBytes   int64     `json:"sizeBytes"`
	URL         string    `json:"url"`
}

type conversationView struct {
	AcceptedAt          *time.Time `json:"acceptedAt,omitempty"`
	AssignmentExpiresAt *time.Time `json:"assignmentExpiresAt,omitempty"`
	ID                  uuid.UUID  `json:"id"`
	TenantID            uuid.UUID  `json:"tenantId"`
	InboxID             uuid.UUID  `json:"inboxId"`
	VisitorID           uuid.UUID  `json:"visitorId"`
	Subject             string     `json:"subject,omitempty"`
	Status              string     `json:"status"`
	AssigneeID          *uuid.UUID `json:"assigneeId,omitempty"`
	AssigneeName        string     `json:"assigneeName,omitempty"`
	Priority            int16      `json:"priority"`
	Source              string     `json:"source"`
	LastSequence        int64      `json:"lastSequence"`
	LastMessagePreview  string     `json:"lastMessagePreview,omitempty"`
	LastMessageAt       *time.Time `json:"lastMessageAt,omitempty"`
	AgentUnread         int        `json:"agentUnread"`
	VisitorUnread       int        `json:"visitorUnread"`
	VisitorName         string     `json:"visitorName,omitempty"`
	Tags                []string   `json:"tags,omitempty"`
	CreatedAt           time.Time  `json:"createdAt"`
	UpdatedAt           time.Time  `json:"updatedAt"`
}

func (a *API) registerWidget(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/widget/bootstrap", a.limit(a.widgetRate, a.widgetBootstrap))
	mux.HandleFunc("POST /api/v1/widget/conversations", a.requireWidget(a.createConversation))
	mux.HandleFunc("GET /api/v1/widget/conversations", a.requireWidget(a.listConversations))
	mux.HandleFunc("GET /api/v1/widget/conversations/{id}", a.requireWidget(a.getConversation))
	mux.HandleFunc("GET /api/v1/widget/conversations/{id}/messages", a.requireWidget(a.listMessages))
	mux.HandleFunc("POST /api/v1/widget/conversations/{id}/messages", a.limit(a.widgetRate, a.requireWidget(a.postMessage)))
	mux.HandleFunc("POST /api/v1/widget/conversations/{id}/read", a.requireWidget(a.markVisitorRead))
	mux.HandleFunc("POST /api/v1/widget/conversations/{id}/delivered", a.requireWidget(a.markVisitorDelivered))
	mux.HandleFunc("GET /api/v1/widget/conversations/{id}/search", a.requireWidget(a.searchVisitorMessages))
	mux.HandleFunc("POST /api/v1/widget/conversations/{id}/typing", a.requireWidget(a.visitorTyping))
	mux.HandleFunc("POST /api/v1/widget/conversations/{id}/rating", a.requireWidget(a.rateConversation))
	mux.HandleFunc("POST /api/v1/widget/conversations/{id}/handoff", a.requireWidget(a.widgetHandoff))

	// Realtime. The visitor token travels in the query string because browsers
	// cannot set headers on the WebSocket handshake.
	mux.HandleFunc("GET /ws/widget", a.widgetSocket)
}

type bootstrapRequest struct {
	InboxKey      string         `json:"inboxKey"`
	IdentityToken string         `json:"identityToken"`
	ExternalID    string         `json:"externalId"`
	DisplayName   string         `json:"displayName"`
	Email         string         `json:"email"`
	Phone         string         `json:"phone"`
	Locale        string         `json:"locale"`
	Attributes    map[string]any `json:"attributes"`
	Referrer      string         `json:"referrer"`
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
	var parentIdentity auth.Principal
	if in.IdentityToken != "" {
		identity, verifyErr := a.tokens.Verify(in.IdentityToken)
		if verifyErr != nil || identity.Kind != auth.KindIdentity || identity.TenantID != inbox.TenantID || identity.InboxID != inbox.ID || identity.ExternalID == "" {
			failCode(w, 401, "IDENTITY_TOKEN_INVALID", "访客身份票据无效、已过期或不属于当前客服入口")
			return
		}
		// 登录身份只信任客户后端签发的票据，不能被前端 externalId 覆盖。
		in.ExternalID = identity.ExternalID
		in.DisplayName = identity.Name
		if identity.MarketplaceID != uuid.Nil && !a.marketplaceBuyerValid(r.Context(), identity) {
			fail(w, 401, "商城身份已失效")
			return
		}
		parentIdentity = identity
	} else if strings.TrimSpace(in.ExternalID) != "" {
		failCode(w, 401, "IDENTITY_TOKEN_REQUIRED", "接入登录用户须由业务服务端签发 identityToken；匿名咨询请勿传 externalId")
		return
	}
	attributes, _ := json.Marshal(orEmpty(in.Attributes))
	var visitorID uuid.UUID
	var created bool
	displayName := nullable(in.DisplayName)
	if strings.TrimSpace(in.ExternalID) != "" {
		// xmax = 0 is true only for a row this statement actually inserted, which
		// is how the visitor.created webhook fires once per customer rather than
		// on every page view that carries an external id.
		err = a.db.QueryRow(r.Context(), `
			insert into visitor(id, tenant_id, inbox_id, external_id, display_name, custom_attributes, last_seen_at)
			values($1,$2,$3,$4,$5,$6, now())
			on conflict (inbox_id, external_id) where external_id is not null
			do update set display_name = coalesce(excluded.display_name, visitor.display_name),
			              custom_attributes = visitor.custom_attributes || excluded.custom_attributes,
			              updated_at = now(), last_seen_at = now()
			returning id, (xmax = 0) as inserted`, uuid.New(), inbox.TenantID, inbox.ID, in.ExternalID, displayName, attributes).Scan(&visitorID, &created)
	} else {
		err = a.db.QueryRow(r.Context(), `
			insert into visitor(id, tenant_id, inbox_id, display_name, custom_attributes, last_seen_at)
			values($1,$2,$3,$4,$5, now()) returning id`,
			uuid.New(), inbox.TenantID, inbox.ID, displayName, attributes).Scan(&visitorID)
		created = true
	}
	if err != nil {
		a.logger.Error("visitor bootstrap failed", "error", err)
		fail(w, 500, "初始化访客失败")
		return
	}
	// Contact details arrive as optional fields. They are written with their own
	// statements rather than folded into the upsert: binding one placeholder both
	// as a varchar column and inside a nullif with an untyped literal leaves
	// PostgreSQL with two candidate types for it and it rejects the statement.
	if value := strings.TrimSpace(in.Email); value != "" {
		_, _ = a.db.Exec(r.Context(), `update visitor set email = $2 where id = $1`, visitorID, value)
	}
	if value := strings.TrimSpace(in.Phone); value != "" {
		_, _ = a.db.Exec(r.Context(), `update visitor set phone = $2 where id = $1`, visitorID, value)
	}
	if value := strings.TrimSpace(in.Locale); value != "" {
		_, _ = a.db.Exec(r.Context(), `update visitor set locale = $2 where id = $1`, visitorID, value)
	}
	if created {
		// The event was declared in the webhook vocabulary and never emitted, so
		// an integration could subscribe to visitor.created and still be told
		// nothing when a new customer first appeared.
		a.notifyWebhook(r.Context(), inbox.TenantID, webhook.EventVisitorCreated, map[string]any{
			"visitorId": visitorID, "inboxId": inbox.ID,
			"displayName": strings.TrimSpace(in.DisplayName), "externalId": strings.TrimSpace(in.ExternalID),
			"email": strings.TrimSpace(in.Email), "phone": strings.TrimSpace(in.Phone),
			"createdAt": nowUTC(),
		})
		a.publish(r.Context(), []string{realtime.TenantChannel(inbox.TenantID.String())}, realtime.Event{
			Type: "visitor.created", TenantID: inbox.TenantID.String(),
			Data: map[string]any{"visitorId": visitorID, "inboxId": inbox.ID, "displayName": in.DisplayName},
		})
	}
	token, err := a.tokens.IssueWidgetFromIdentity(parentIdentity, inbox.TenantID, inbox.ID, visitorID)
	if err != nil {
		fail(w, 500, "签发令牌失败")
		return
	}
	var openConversations int
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from conversation
		where visitor_id=$1 and status <> 'RESOLVED'`, visitorID).Scan(&openConversations)

	respond(w, 200, map[string]any{
		"visitorId":   visitorID,
		"displayName": in.DisplayName,
		"token":       token,
		"expiresIn":   int(a.cfg.WidgetTokenTTL.Seconds()),
		"inbox": map[string]any{"id": inbox.ID, "name": inbox.Name, "welcomeMessage": inbox.WelcomeMessage, "offlineMessage": inbox.OfflineMessage, "automation": a.publicAutomation(r.Context(), inbox.ID),
			"logoUrl": inbox.LogoURL, "avatarUrl": inbox.AvatarURL, "fontFamily": inbox.FontFamily, "bubbleRadius": inbox.BubbleRadius, "customCss": inbox.CustomCSS},
		"aiEnabled":         inbox.AIEnabled && a.tenantHasFeature(r.Context(), inbox.TenantID, "ai") && a.ai.Available() && a.cfg.AI.AutoReplyEnabled,
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
		saved, err := a.appendVisitorReply(r.Context(), p, conversationID, *in.Content, "", "TEXT", nil, nil, nil)
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
		       coalesce(v.display_name,''), c.created_at, c.updated_at, c.accepted_at, c.assignment_expires_at
		  from conversation c
		  join visitor v on v.id = c.visitor_id
		  left join agent ag on ag.id = c.assignee_id
		 where c.tenant_id=$1 and c.inbox_id=$2 and c.visitor_id=$3
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
	var online int
	var aiEnabled bool
	var welcome, offline string
	var css, logo, avatar, font string
	var radius int
	if err := a.db.QueryRow(r.Context(), `select coalesce(i.welcome_message,''), coalesce(i.offline_message,''), coalesce(s.enabled,false),
	 (select count(*)::int from agent_presence ap join agent ag on ag.id=ap.agent_id join agent_inbox ai on ai.agent_id=ag.id where ai.inbox_id=i.id and ag.status='ACTIVE' and ap.status='ONLINE')
	 ,coalesce(i.custom_css,''),coalesce(i.logo_url,''),coalesce(i.avatar_url,''),coalesce(i.font_family,''),coalesce(i.bubble_radius,12)
	 from inbox i left join ai_setting s on s.inbox_id=i.id where i.id=$1 and i.tenant_id=$2 and i.status='ACTIVE'`, p.InboxID, p.TenantID).Scan(&welcome, &offline, &aiEnabled, &online, &css, &logo, &avatar, &font, &radius); err != nil {
		fail(w, 404, "客服入口已停用")
		return
	}
	// 恢复匿名历史及长连接重连时仍读取最新渠道皮肤，不能只在首次bootstrap应用。
	respond(w, 200, map[string]any{"items": items, "agentsOnline": online, "aiEnabled": aiEnabled && a.tenantHasFeature(r.Context(), p.TenantID, "ai") && a.ai.Available() && a.cfg.AI.AutoReplyEnabled, "welcomeMessage": welcome, "offlineMessage": offline, "automation": a.publicAutomation(r.Context(), p.InboxID),
		"inbox": map[string]any{"customCss": css, "logoUrl": logo, "avatarUrl": avatar, "fontFamily": font, "bubbleRadius": radius}})
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
	// before= switches the read to the upward page. A visitor scrolling back
	// through a long thread needs it; after= alone can only move forward.
	after := queryInt64(r, "after", 0)
	before := queryInt64(r, "before", 0)
	limit := queryInt(r, "limit", 50)
	page, err := a.pageMessages(r.Context(), id, after, before, limit, visitorVisibility)
	if err != nil {
		fail(w, 500, "查询消息失败")
		return
	}
	var lastSequence int64
	var visitorUnread int
	_ = a.db.QueryRow(r.Context(), `select last_sequence, visitor_unread from conversation where id=$1`, id).
		Scan(&lastSequence, &visitorUnread)
	if page.LastSequence == 0 {
		page.LastSequence = lastSequence
	}
	// 坐席侧游标：访客自己气泡上的「未读 / 已送达 / 已读」取所有坐席的最大值。
	var agentLastRead, agentLastDelivered int64
	_ = a.db.QueryRow(r.Context(), `
		select coalesce(max(last_read_sequence),0), coalesce(max(last_delivered_sequence),0)
		from conversation_read
		where conversation_id=$1 and reader_type='AGENT'`, id).
		Scan(&agentLastRead, &agentLastDelivered)
	respond(w, 200, map[string]any{
		"items": page.Items, "hasMore": page.HasMore, "hasOlder": page.HasOlder,
		"firstSequence": page.FirstSequence, "lastSequence": page.LastSequence,
		"visitorUnread":              visitorUnread,
		"agentLastReadSequence":      agentLastRead,
		"agentLastDeliveredSequence": agentLastDelivered,
	})
}

func (a *API) postMessage(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.visitorConversation(w, r, p)
	if !ok {
		return
	}
	var in struct {
		ClientMessageID string         `json:"clientMessageId"`
		Content         string         `json:"content"`
		MessageType     string         `json:"messageType"`
		AttachmentIDs   []string       `json:"attachmentIds"`
		ReplyToID       string         `json:"replyToId"`
		Metadata        map[string]any `json:"metadata"`
	}
	if !decode(w, r, &in) {
		return
	}
	in.MessageType = strings.ToUpper(strings.TrimSpace(in.MessageType))
	if in.MessageType == "" {
		in.MessageType = "TEXT"
	}
	switch in.MessageType {
	// A visitor may send text, media and a shared location. SYSTEM, EVENT and
	// RATING are the platform's own vocabulary and are never accepted from a
	// client, which is why this list is an allow-list rather than a deny-list.
	case "TEXT", "IMAGE", "FILE", "AUDIO", "VIDEO", "LOCATION":
	default:
		fail(w, 400, "不支持的消息类型")
		return
	}
	if in.MessageType == "TEXT" && strings.TrimSpace(in.Content) == "" {
		fail(w, 400, "消息内容不能为空")
		return
	}
	if in.MessageType != "TEXT" && in.MessageType != "LOCATION" && len(in.AttachmentIDs) == 0 {
		fail(w, 400, "图片或文件消息必须先上传附件")
		return
	}
	var replyTo *uuid.UUID
	if strings.TrimSpace(in.ReplyToID) != "" {
		parsed, err := uuid.Parse(in.ReplyToID)
		if err != nil {
			fail(w, 400, "引用的消息不存在")
			return
		}
		// The parent is verified to belong to this conversation so a visitor
		// cannot quote — and thereby read back — a message from another tenant
		// or another thread.
		var exists bool
		_ = a.db.QueryRow(r.Context(), `select exists(select 1 from message where id=$1 and conversation_id=$2 and not is_private)`,
			parsed, id).Scan(&exists)
		if !exists {
			fail(w, 400, "引用的消息不存在")
			return
		}
		replyTo = &parsed
	}
	view, err := a.appendVisitorReply(r.Context(), p, id, in.Content, in.ClientMessageID,
		in.MessageType, in.AttachmentIDs, in.Metadata, replyTo)
	if err != nil {
		if errors.Is(err, errVisitorBlocked) {
			failCode(w, 403, "VISITOR_BLOCKED", "当前会话已被限制发送消息")
			return
		}
		if isNotFound(err) {
			fail(w, 404, "会话不存在或已结束")
			return
		}
		a.logger.Error("visitor message failed", "error", err)
		if failServiceError(w, err) {
			return
		}
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
	if in.Sequence <= 0 {
		fail(w, 400, "sequence 必须大于零")
		return
	}
	if err := a.markRead(r.Context(), id, p.TenantID, "VISITOR", p.VisitorID, in.Sequence); err != nil {
		fail(w, 500, "更新回执失败")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) markVisitorDelivered(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.visitorConversation(w, r, p)
	if !ok {
		return
	}
	var in markReadRequest
	if !decode(w, r, &in) {
		return
	}
	if in.Sequence <= 0 {
		fail(w, 400, "sequence 必须大于零")
		return
	}
	if err := a.markDelivered(r.Context(), id, p.TenantID, "VISITOR", p.VisitorID, in.Sequence); err != nil {
		fail(w, 500, "更新回执失败")
		return
	}
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

// widgetHandoff lets a visitor ask a human to take over from the AI. It mirrors
// the low-confidence path in the AI answer flow: pause the bot, assign an agent,
// post the handoff notice and notify the console.
func (a *API) widgetHandoff(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.visitorConversation(w, r, p)
	if !ok {
		return
	}
	if _, _, err := a.completeHandoff(r.Context(), p.TenantID, id); err != nil {
		fail(w, 500, "转接人工失败")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
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
