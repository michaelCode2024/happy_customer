package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/realtime"
)

// errWSCapacity is returned when accept refuses a socket; callers only need a
// non-nil error so they stop the handshake path.
var errWSCapacity = errors.New("websocket capacity reached")

// inbound is every frame a client may send over the socket. Sockets are a
// convenience channel only: anything that must not be lost still travels over
// REST, so an unknown or malformed frame is simply ignored.
type inbound struct {
	Type           string `json:"type"`
	ConversationID string `json:"conversationId"`
}

func (a *API) widgetSocket(w http.ResponseWriter, r *http.Request) {
	token := r.URL.Query().Get("token")
	if token == "" {
		token = bearer(r)
	}
	principal, err := a.tokens.Verify(token)
	if err != nil || principal.Kind != auth.KindWidget {
		failCode(w, 401, "WIDGET_TOKEN_INVALID", "访客令牌无效或已过期")
		return
	}
	if !a.tenantActive(r.Context(), principal.TenantID) {
		failCode(w, 403, "TENANT_SUSPENDED", "该企业账号已停用")
		return
	}
	conn, err := a.accept(r, w)
	if err != nil {
		return
	}
	channels := []string{realtime.VisitorChannel(principal.VisitorID.String())}
	channels = append(channels, a.openConversationChannels(r.Context(), principal.VisitorID)...)
	subscriber := a.hub.Subscribe(conn, channels)
	defer a.hub.Unsubscribe(subscriber)
	a.touchVisitor(r.Context(), principal.VisitorID)

	a.socketHello(subscriber, map[string]any{
		"kind": "widget", "visitorId": principal.VisitorID, "serverTime": nowUTC(),
	})
	a.pump(r.Context(), conn, subscriber, func(frame inbound) {
		switch frame.Type {
		case "subscribe":
			if id, err := uuid.Parse(frame.ConversationID); err == nil && a.visitorOwnsConversation(r, principal, id) {
				a.hub.AddChannels(subscriber, realtime.ConversationChannel(id.String()))
			}
		case "unsubscribe":
			if id, err := uuid.Parse(frame.ConversationID); err == nil {
				a.hub.RemoveChannels(subscriber, realtime.ConversationChannel(id.String()))
			}
		case "typing":
			if id, err := uuid.Parse(frame.ConversationID); err == nil && a.visitorOwnsConversation(r, principal, id) {
				a.publish(r.Context(), []string{realtime.ConversationChannel(id.String())}, realtime.Event{
					Type: "typing", TenantID: principal.TenantID.String(), ConversationID: id.String(),
					Data: map[string]any{"actorType": "VISITOR", "actorId": principal.VisitorID},
				})
			}
		case "read":
			if id, err := uuid.Parse(frame.ConversationID); err == nil && a.visitorOwnsConversation(r, principal, id) {
				a.markRead(r.Context(), id, principal.TenantID, "VISITOR", principal.VisitorID, 0)
			}
		}
	})
}

func (a *API) consoleSocket(w http.ResponseWriter, r *http.Request) {
	token := r.URL.Query().Get("token")
	if token == "" {
		token = bearer(r)
	}
	principal, err := a.tokens.Verify(token)
	if err != nil || principal.Kind != auth.KindAgent {
		failCode(w, 401, "AGENT_TOKEN_INVALID", "坐席登录已失效，请重新登录")
		return
	}
	if !a.authn.SessionValid(r.Context(), principal.SessionID, principal.AgentID) {
		failCode(w, 401, "AGENT_SESSION_REVOKED", "登录状态已被注销，请重新登录")
		return
	}
	conn, err := a.accept(r, w)
	if err != nil {
		return
	}
	channels := []string{
		realtime.AgentChannel(principal.AgentID.String()),
		realtime.TenantChannel(principal.TenantID.String()),
	}
	// Supervisors watch the whole queue, ordinary agents only their own inboxes.
	if auth.CanViewReports(principal.Role) {
		channels = append(channels, a.inboxChannels(r.Context(), principal.TenantID, uuid.Nil)...)
	} else {
		channels = append(channels, a.inboxChannels(r.Context(), principal.TenantID, principal.AgentID)...)
	}
	subscriber := a.hub.Subscribe(conn, channels)
	defer a.hub.Unsubscribe(subscriber)

	_, _ = a.db.Exec(r.Context(), `insert into agent_presence(agent_id, status, last_seen_at) values($1,'ONLINE', now())
		on conflict (agent_id) do update set status = case when agent_presence.status = 'OFFLINE' then 'ONLINE' else agent_presence.status end,
		                                    last_seen_at = now()`, principal.AgentID)
	a.publish(r.Context(), []string{realtime.TenantChannel(principal.TenantID.String())}, realtime.Event{
		Type: "agent.presence", TenantID: principal.TenantID.String(),
		Data: map[string]any{"agentId": principal.AgentID, "status": "ONLINE"},
	})

	a.socketHello(subscriber, map[string]any{
		"kind": "console", "agentId": principal.AgentID, "role": principal.Role, "serverTime": nowUTC(),
	})
	a.pump(r.Context(), conn, subscriber, func(frame inbound) {
		switch frame.Type {
		case "subscribe":
			if id, err := uuid.Parse(frame.ConversationID); err == nil && a.agentCanSee(r, principal, id) {
				a.hub.AddChannels(subscriber, realtime.ConversationChannel(id.String()))
			}
		case "unsubscribe":
			if id, err := uuid.Parse(frame.ConversationID); err == nil {
				a.hub.RemoveChannels(subscriber, realtime.ConversationChannel(id.String()))
			}
		case "typing":
			if id, err := uuid.Parse(frame.ConversationID); err == nil && a.agentCanSee(r, principal, id) {
				a.publish(r.Context(), []string{realtime.ConversationChannel(id.String())}, realtime.Event{
					Type: "typing", TenantID: principal.TenantID.String(), ConversationID: id.String(),
					Data: map[string]any{"actorType": "AGENT", "actorId": principal.AgentID, "actorName": principal.Name},
				})
			}
		case "read":
			if id, err := uuid.Parse(frame.ConversationID); err == nil && a.agentCanSee(r, principal, id) {
				a.markRead(r.Context(), id, principal.TenantID, "AGENT", principal.AgentID, 0)
			}
		case "presence":
			// Handled over REST so the status survives a socket drop.
		}
	})
	_, _ = a.db.Exec(context.WithoutCancel(r.Context()), `update agent_presence set status='OFFLINE', last_seen_at = now() where agent_id=$1`, principal.AgentID)
	a.publish(context.WithoutCancel(r.Context()), []string{realtime.TenantChannel(principal.TenantID.String())}, realtime.Event{
		Type: "agent.presence", TenantID: principal.TenantID.String(),
		Data: map[string]any{"agentId": principal.AgentID, "status": "OFFLINE"},
	})
}

func (a *API) platformSocket(w http.ResponseWriter, r *http.Request) {
	token := r.URL.Query().Get("token")
	if token == "" {
		token = bearer(r)
	}
	principal, err := a.tokens.Verify(token)
	if err != nil || principal.Kind != auth.KindPlatform {
		failCode(w, 401, "PLATFORM_TOKEN_INVALID", "平台管理令牌无效")
		return
	}
	conn, err := a.accept(r, w)
	if err != nil {
		return
	}
	subscriber := a.hub.Subscribe(conn, []string{realtime.PlatformChannel})
	defer a.hub.Unsubscribe(subscriber)
	a.socketHello(subscriber, map[string]any{
		"kind": "platform", "instance": a.bus.InstanceID(), "serverTime": nowUTC(),
	})
	a.pump(r.Context(), conn, subscriber, func(inbound) {
		// The operations console is read-only over the socket: every mutation
		// goes through REST so it stays audited and permission-checked.
	})
}

// accept upgrades the connection. When ALLOWED_ORIGINS is "*" the widget is
// embedded on arbitrary customer domains by design, so the token presented in
// the handshake is the authorization boundary rather than the Origin header.
func (a *API) accept(r *http.Request, w http.ResponseWriter) (*websocket.Conn, error) {
	// 硬顶连接数：慢客户端会被踢，但没有准入时瞬间涌入仍会先吃光 FD/内存。
	if a.cfg.MaxWSConnections > 0 && a.hub.Count() >= a.cfg.MaxWSConnections {
		wsRejectedTotal.Add(1)
		failCode(w, http.StatusServiceUnavailable, "WS_CAPACITY", "实时连接已满，请稍后重试")
		return nil, errWSCapacity
	}
	options := &websocket.AcceptOptions{CompressionMode: websocket.CompressionDisabled}
	allowAll := len(a.cfg.AllowedOrigins) == 0
	for _, origin := range a.cfg.AllowedOrigins {
		if origin == "*" {
			allowAll = true
		}
	}
	if allowAll {
		options.InsecureSkipVerify = true
	} else {
		options.OriginPatterns = a.cfg.AllowedOrigins
	}
	conn, err := websocket.Accept(w, r, options)
	if err != nil {
		a.logger.Debug("websocket upgrade rejected", "error", err, "path", r.URL.Path)
		return nil, err
	}
	return conn, nil
}

// pump reads client frames until the socket closes. The hub owns the write side.
func (a *API) pump(ctx context.Context, conn *websocket.Conn, subscriber *realtime.Subscriber, handle func(inbound)) {
	conn.SetReadLimit(64 << 10)
	defer conn.CloseNow() //nolint:errcheck
	for {
		readCtx, cancel := context.WithTimeout(ctx, 90*time.Second)
		_, payload, err := conn.Read(readCtx)
		cancel()
		if err != nil {
			return
		}
		var frame inbound
		if json.Unmarshal(payload, &frame) != nil {
			continue
		}
		if frame.Type == "ping" {
			subscriber.Enqueue(realtime.Encode(realtime.Event{Type: "pong", Data: map[string]any{"at": nowUTC()}}))
			continue
		}
		handle(frame)
	}
}

// socketHello greets a freshly connected socket. Clients treat it as the signal
// that the subscription is live and they may start trusting events.
func (a *API) socketHello(subscriber *realtime.Subscriber, data map[string]any) {
	subscriber.Enqueue(realtime.Encode(realtime.Event{Type: "ready", Data: data}))
}

// realtimeEvent keeps the platform handlers short when they only need a type and
// a few fields.
func realtimeEvent(eventType string, tenantID uuid.UUID, data map[string]any) realtime.Event {
	event := realtime.Event{Type: eventType, Data: data}
	if tenantID != uuid.Nil {
		event.TenantID = tenantID.String()
	}
	return event
}

// openConversationChannels returns the conversation streams a visitor is part of.
func (a *API) openConversationChannels(ctx context.Context, visitorID uuid.UUID) []string {
	rows, err := a.db.Query(ctx, `select id from conversation
		where visitor_id = $1 and status <> 'RESOLVED'
		order by coalesce(last_message_at, created_at) desc limit 20`, visitorID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	channels := make([]string, 0, 8)
	for rows.Next() {
		var id uuid.UUID
		if rows.Scan(&id) == nil {
			channels = append(channels, realtime.ConversationChannel(id.String()))
		}
	}
	return channels
}

// inboxChannels gives agents a queue-level stream. A nil agentID means every
// inbox in the tenant, which supervisors are allowed to watch.
func (a *API) inboxChannels(ctx context.Context, tenantID, agentID uuid.UUID) []string {
	query := `select i.id from inbox i where i.tenant_id = $1 and i.status = 'ACTIVE'`
	args := []any{tenantID}
	if agentID != uuid.Nil {
		query = `select i.id from inbox i join agent_inbox ai on ai.inbox_id = i.id
			where i.tenant_id = $1 and i.status = 'ACTIVE' and ai.agent_id = $2`
		args = append(args, agentID)
	}
	rows, err := a.db.Query(ctx, query, args...)
	if err != nil {
		return nil
	}
	defer rows.Close()
	channels := make([]string, 0, 4)
	for rows.Next() {
		var id uuid.UUID
		if rows.Scan(&id) == nil {
			channels = append(channels, realtime.InboxChannel(id.String()))
		}
	}
	return channels
}

func (a *API) visitorOwnsConversation(r *http.Request, p auth.Principal, conversationID uuid.UUID) bool {
	var exists bool
	err := a.db.QueryRow(r.Context(), `select exists(select 1 from conversation
		where id = $1 and tenant_id = $2 and inbox_id = $3 and visitor_id = $4)`,
		conversationID, p.TenantID, p.InboxID, p.VisitorID).Scan(&exists)
	return err == nil && exists
}

func (a *API) agentCanSee(r *http.Request, p auth.Principal, conversationID uuid.UUID) bool {
	var allowed bool
	err := a.db.QueryRow(r.Context(), `select exists(select 1 from conversation c
		where c.id = $1 and c.tenant_id = $2
		  and (exists (select 1 from agent_inbox ai where ai.inbox_id = c.inbox_id and ai.agent_id = $3)
		       or c.assignee_id = $3))`, conversationID, p.TenantID, p.AgentID).Scan(&allowed)
	return err == nil && allowed
}

// markRead is the shared read-cursor update used by the REST and socket paths.
// tenantID is passed explicitly so the emitted event can carry it without a
// second lookup: every caller already has it on its principal.
func (a *API) markRead(ctx context.Context, conversationID uuid.UUID, tenantID uuid.UUID, readerType string, readerID uuid.UUID, sequence int64) {
	if sequence == 0 {
		_ = a.db.QueryRow(ctx, `select last_sequence from conversation where id = $1`, conversationID).Scan(&sequence)
	}
	_, _ = a.db.Exec(ctx, `
		insert into conversation_read(conversation_id, reader_type, reader_id, last_read_sequence, updated_at)
		values($1,$2,$3,$4, now())
		on conflict (conversation_id, reader_type, reader_id)
		do update set last_read_sequence = greatest(conversation_read.last_read_sequence, excluded.last_read_sequence),
		              updated_at = now()`, conversationID, readerType, readerID, sequence)
	if readerType == "VISITOR" {
		_, _ = a.db.Exec(ctx, `update conversation set visitor_unread = 0 where id = $1`, conversationID)
	} else {
		_, _ = a.db.Exec(ctx, `update conversation set agent_unread = 0 where id = $1`, conversationID)
	}
	a.publish(ctx, a.conversationChannels(ctx, conversationID), realtime.Event{
		Type: "conversation.read", TenantID: tenantID.String(), ConversationID: conversationID.String(),
		Data: map[string]any{"readerType": readerType, "readerId": readerID, "sequence": sequence},
	})
}

// markDelivered advances the delivery cursor. It is deliberately separate from
// markRead: "the device received it" and "the person read it" are different
// facts, and a chat product that merges them cannot render the single tick that
// tells an agent the visitor's page is actually open. Delivery is recorded for
// agents only — a visitor has nobody to reassure.
func (a *API) markDelivered(ctx context.Context, conversationID uuid.UUID, tenantID uuid.UUID, readerType string, readerID uuid.UUID, sequence int64) {
	if sequence == 0 {
		return
	}
	_, _ = a.db.Exec(ctx, `
		insert into conversation_read(conversation_id, reader_type, reader_id, last_delivered_sequence, updated_at)
		values($1,$2,$3,$4, now())
		on conflict (conversation_id, reader_type, reader_id)
		do update set last_delivered_sequence = greatest(conversation_read.last_delivered_sequence, excluded.last_delivered_sequence),
		              updated_at = now()`, conversationID, readerType, readerID, sequence)
	a.publish(ctx, []string{realtime.ConversationChannel(conversationID.String())}, realtime.Event{
		Type: "conversation.delivered", TenantID: tenantID.String(), ConversationID: conversationID.String(),
		Data: map[string]any{"readerType": readerType, "readerId": readerID, "sequence": sequence},
	})
}

// markReadRequest is the shared REST read-cursor endpoint body. Both the visitor
// and agent consoles post the sequence they have rendered.
type markReadRequest struct {
	Sequence int64 `json:"sequence"`
}
