package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

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
	Sequence       int64  `json:"sequence"`
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
	if principal.MarketplaceID != uuid.Nil && !a.marketplaceBuyerValid(r.Context(), principal) {
		fail(w, 401, "商城登录已失效")
		return
	}
	conn, err := a.accept(r, w)
	if err != nil {
		return
	}
	channels := []string{realtime.VisitorChannel(principal.VisitorID.String())}
	// 订阅所在入口，才能收到坐席在线/离开，避免组件副标题卡在「离线」。
	if principal.InboxID != uuid.Nil {
		channels = append(channels, realtime.InboxChannel(principal.InboxID.String()))
	}
	channels = append(channels, a.openConversationChannels(r.Context(), principal.VisitorID)...)
	subscriber := a.hub.Subscribe(conn, channels)
	defer a.hub.Unsubscribe(subscriber)
	a.guardSocket(r.Context(), subscriber, principal)
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
				a.markRead(r.Context(), id, principal.TenantID, "VISITOR", principal.VisitorID, frame.Sequence)
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
	var active bool
	principal, active = a.currentAgent(r.Context(), principal)
	if !active {
		fail(w, 401, "登录已失效")
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
	a.guardSocket(r.Context(), subscriber, principal)

	// 在线状态以 REST /console/me/presence 为准：套接字只负责心跳。
	// 断线不得把「离开」抹成离线，重连也不得在仍为离开时广播 ONLINE，否则组件会闪「离线」。
	_, _ = a.db.Exec(r.Context(), `insert into agent_presence(agent_id, status, last_seen_at) values($1,'ONLINE', now())
		on conflict (agent_id) do update set status = case when agent_presence.status = 'OFFLINE' then 'ONLINE' else agent_presence.status end,
		                                    last_seen_at = now()`, principal.AgentID)
	var presence string
	_ = a.db.QueryRow(r.Context(), `select coalesce(status,'ONLINE') from agent_presence where agent_id=$1`, principal.AgentID).Scan(&presence)
	if presence == "" {
		presence = "ONLINE"
	}
	a.publishAgentPresence(r.Context(), principal.TenantID, principal.AgentID, presence)

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
				a.markRead(r.Context(), id, principal.TenantID, "AGENT", principal.AgentID, frame.Sequence)
			}
		case "presence":
			// Handled over REST so the status survives a socket drop.
		}
	})
	// 仅刷新心跳；显式离线/离开仍走 REST，避免刷新页或瞬时断线把离开打成离线。
	_, _ = a.db.Exec(context.WithoutCancel(r.Context()), `update agent_presence set last_seen_at = now() where agent_id=$1`, principal.AgentID)
}

func (a *API) platformSocket(w http.ResponseWriter, r *http.Request) {
	token := r.URL.Query().Get("token")
	if token == "" {
		token = bearer(r)
	}
	principal, err := a.tokens.Verify(token)
	if err != nil || !a.platformSessionValid(r.Context(), principal) {
		failCode(w, 401, "PLATFORM_SESSION_INVALID", "平台登录已失效")
		return
	}
	conn, err := a.accept(r, w)
	if err != nil {
		return
	}
	subscriber := a.hub.Subscribe(conn, []string{realtime.PlatformChannel})
	defer a.hub.Unsubscribe(subscriber)
	a.guardSocket(r.Context(), subscriber, principal)
	// 已打开的实时连接也必须跟随账号退出、密码变更与到期撤销。
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	go func() {
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if !a.platformSessionValid(ctx, principal) {
					conn.CloseNow()
					return
				}
			}
		}
	}()
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

// publishAgentPresence 同步给企业频道与坐席所属入口，组件才能即时刷新 agentsOnline。
func (a *API) publishAgentPresence(ctx context.Context, tenantID, agentID uuid.UUID, status string) {
	channels := []string{realtime.TenantChannel(tenantID.String())}
	channels = append(channels, a.inboxChannels(ctx, tenantID, agentID)...)
	a.publish(ctx, channels, realtime.Event{
		Type: "agent.presence", TenantID: tenantID.String(),
		Data: map[string]any{"agentId": agentID, "status": status},
	})
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
func (a *API) markRead(ctx context.Context, conversationID, tenantID uuid.UUID, readerType string, readerID uuid.UUID, sequence int64) error {
	return a.advanceReceipt(ctx, conversationID, tenantID, readerType, readerID, sequence, true)
}
func (a *API) markDelivered(ctx context.Context, conversationID, tenantID uuid.UUID, readerType string, readerID uuid.UUID, sequence int64) error {
	return a.advanceReceipt(ctx, conversationID, tenantID, readerType, readerID, sequence, false)
}
func (a *API) advanceReceipt(ctx context.Context, conversationID, tenantID uuid.UUID, readerType string, readerID uuid.UUID, sequence int64, read bool) error {
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var last int64
	if err = tx.QueryRow(ctx, `select last_sequence from conversation where id=$1 and tenant_id=$2 for update`, conversationID, tenantID).Scan(&last); err != nil {
		return err
	}
	if sequence <= 0 {
		return errors.New("sequence must be positive")
	}
	if sequence > last {
		sequence = last
	}
	var oldRead, oldDelivered int64
	err = tx.QueryRow(ctx, `select last_read_sequence,last_delivered_sequence from conversation_read where conversation_id=$1 and reader_type=$2 and reader_id=$3`, conversationID, readerType, readerID).Scan(&oldRead, &oldDelivered)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	boundary := oldDelivered
	if read {
		boundary = oldRead
	}
	if sequence <= boundary {
		return tx.Commit(ctx)
	}
	column := "last_delivered_sequence"
	eventType := "conversation.delivered"
	if read {
		column = "last_read_sequence"
		eventType = "conversation.read"
	}
	_, err = tx.Exec(ctx, `insert into conversation_read(conversation_id,reader_type,reader_id,`+column+`) values($1,$2,$3,$4) on conflict(conversation_id,reader_type,reader_id) do update set `+column+`=greatest(conversation_read.`+column+`,excluded.`+column+`),updated_at=now()`, conversationID, readerType, readerID, sequence)
	if err != nil {
		return err
	}
	if read {
		unreadColumn := "agent_unread"
		predicate := "sender_type='VISITOR'"
		if readerType == "VISITOR" {
			unreadColumn = "visitor_unread"
			predicate = "sender_type<>'VISITOR' and not is_private"
		}
		_, err = tx.Exec(ctx, `update conversation set `+unreadColumn+`=(select count(*) from message where conversation_id=$1 and sequence>(select coalesce(max(last_read_sequence),0) from conversation_read where conversation_id=$1 and reader_type=$2) and `+predicate+`),updated_at=now() where id=$1 and tenant_id=$3`, conversationID, readerType, tenantID)
		if err != nil {
			return err
		}
	}
	data := map[string]any{"conversationId": conversationID, "readerType": readerType, "readerId": readerID, "sequence": sequence}
	if a.webhooks != nil {
		payload, _ := json.Marshal(data)
		_, err = tx.Exec(ctx, `insert into webhook_delivery(id,endpoint_id,tenant_id,event_type,payload,status,next_attempt_at)
   select gen_random_uuid(),e.id,$1,$2::varchar(60),$3,'PENDING',now() from webhook_endpoint e
   where e.tenant_id=$1 and e.status='ACTIVE' and $4::text=any(e.events)
   and exists(select 1 from tenant_subscription where tenant_id=$1 and status='ACTIVE' and plan in ('STARTER','GROWTH','ENTERPRISE'))`, tenantID, eventType, payload, eventType)
		if err != nil {
			return err
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return err
	}
	data = map[string]any{"conversationId": conversationID, "readerType": readerType, "readerId": readerID, "sequence": sequence}
	a.publish(ctx, a.conversationChannels(ctx, conversationID), realtime.Event{Type: eventType, TenantID: tenantID.String(), ConversationID: conversationID.String(), Data: data})
	if read {
		a.publishMarketplaceConversation(ctx, conversationID)
	}
	return nil
}

// markReadRequest is the shared REST read-cursor endpoint body. Both the visitor
// and agent consoles post the sequence they have rendered.
type markReadRequest struct {
	Sequence int64 `json:"sequence"`
}
