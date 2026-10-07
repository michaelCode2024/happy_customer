package server

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/relaydesk/relaydesk/internal/ai"
	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/realtime"
	"github.com/relaydesk/relaydesk/internal/webhook"
)

// messageInput is the common description of a message regardless of who sends it.
type messageInput struct {
	SenderType      string
	SenderID        *uuid.UUID
	ClientMessageID string
	MessageType     string
	Content         string
	AttachmentIDs   []string
	Metadata        map[string]any
}

// appendMessage is the single write path for chat messages. Everything that
// must stay correct — sequence allocation, idempotency, unread counters and the
// after-commit realtime publish — lives here so the visitor API, the agent
// console and the open API cannot diverge.
func (a *API) appendMessage(ctx context.Context, tenantID, conversationID uuid.UUID, in messageInput) (messageView, error) {
	messageType := strings.ToUpper(strings.TrimSpace(in.MessageType))
	if messageType == "" {
		messageType = "TEXT"
	}
	switch messageType {
	case "TEXT", "IMAGE", "FILE", "EVENT", "SYSTEM", "RICH", "RATING":
	default:
		return messageView{}, errors.New("不支持的消息类型")
	}
	if messageType == "TEXT" && strings.TrimSpace(in.Content) == "" {
		return messageView{}, errors.New("消息内容不能为空")
	}

	if in.ClientMessageID != "" {
		existing, err := a.findByClientMessageID(ctx, conversationID, in.ClientMessageID)
		if err == nil {
			return existing, nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return messageView{}, err
		}
	}

	metadata, err := json.Marshal(orEmpty(in.Metadata))
	if err != nil {
		return messageView{}, err
	}

	tx, err := a.db.Begin(ctx)
	if err != nil {
		return messageView{}, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	// Row lock on the conversation serialises sequence allocation, so two
	// concurrent sends can never receive the same sequence.
	var sequence int64
	var assignee *uuid.UUID
	err = tx.QueryRow(ctx, `
		update conversation
		   set last_sequence = last_sequence + 1,
		       last_message_at = now(),
		       last_message_preview = $3,
		       updated_at = now(),
		       agent_unread = case when $4 = 'VISITOR' then agent_unread + 1 else agent_unread end,
		       visitor_unread = case when $4 <> 'VISITOR' then visitor_unread + 1 else visitor_unread end,
		       status = case when status = 'RESOLVED' then 'OPEN' else status end
		 where id = $1 and tenant_id = $2
		 returning last_sequence, assignee_id`,
		conversationID, tenantID, trimPreview(in.Content), in.SenderType).Scan(&sequence, &assignee)
	if errors.Is(err, pgx.ErrNoRows) {
		return messageView{}, pgx.ErrNoRows
	}
	if err != nil {
		return messageView{}, err
	}

	var clientID *string
	if in.ClientMessageID != "" {
		clientID = &in.ClientMessageID
	}
	view := messageView{
		ID:              uuid.New(),
		ConversationID:  conversationID,
		SenderType:      in.SenderType,
		SenderID:        in.SenderID,
		ClientMessageID: clientID,
		Sequence:        sequence,
		MessageType:     messageType,
		Content:         in.Content,
		Metadata:        metadata,
		CreatedAt:       nowUTC(),
	}
	if _, err := tx.Exec(ctx, `
		insert into message(id, tenant_id, conversation_id, sender_type, sender_id, client_message_id,
			sequence, message_type, content, metadata, created_at)
		values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
		view.ID, tenantID, conversationID, view.SenderType, view.SenderID, view.ClientMessageID,
		view.Sequence, view.MessageType, view.Content, metadata, view.CreatedAt); err != nil {
		// A concurrent retry with the same clientMessageId hits the unique index.
		if in.ClientMessageID != "" && isUniqueViolation(err) {
			if existing, lookupErr := a.findByClientMessageID(ctx, conversationID, in.ClientMessageID); lookupErr == nil {
				return existing, nil
			}
		}
		return messageView{}, err
	}

	if len(in.AttachmentIDs) > 0 {
		for _, raw := range in.AttachmentIDs {
			attachmentID, parseErr := uuid.Parse(raw)
			if parseErr != nil {
				continue
			}
			if _, err := tx.Exec(ctx, `update attachment set message_id = $1
				where id = $2 and conversation_id = $3 and message_id is null`, view.ID, attachmentID, conversationID); err != nil {
				return messageView{}, err
			}
		}
	}

	newAssignee, err := a.autoAssign(ctx, tx, tenantID, conversationID, assignee, in.SenderType)
	if err != nil {
		return messageView{}, err
	}

	if err := tx.Commit(ctx); err != nil {
		return messageView{}, err
	}
	a.afterMessageCommitted(ctx, tenantID, conversationID, view, newAssignee, in.SenderType)
	return view, nil
}

// afterMessageCommitted runs everything that must not happen inside the
// transaction: realtime fan-out, webhook enqueue, statistics and the AI reply.
func (a *API) afterMessageCommitted(ctx context.Context, tenantID, conversationID uuid.UUID, view messageView, assignee *uuid.UUID, senderType string) {
	channels := a.conversationChannels(ctx, conversationID)
	a.publish(ctx, channels, realtime.Event{
		Type: "message.created", TenantID: tenantID.String(), ConversationID: conversationID.String(), Data: view,
	})
	eventType := webhook.EventMessageCreated
	if senderType == "AGENT" {
		eventType = webhook.EventMessageFromAgent
	}
	a.notifyWebhook(ctx, tenantID, eventType, map[string]any{
		"conversationId": conversationID, "message": view, "senderType": senderType,
	})
	if senderType == "VISITOR" {
		a.bumpDailyStat(ctx, tenantID, "messages_in")
	} else if senderType == "AGENT" {
		a.bumpDailyStat(ctx, tenantID, "messages_out")
		a.recordFirstResponse(ctx, conversationID)
	}

	if assignee != nil {
		a.publish(ctx, []string{realtime.AgentChannel(assignee.String())}, realtime.Event{
			Type: "conversation.assigned", TenantID: tenantID.String(), ConversationID: conversationID.String(),
			Data: map[string]any{"assigneeId": assignee},
		})
	}

	if senderType == "VISITOR" {
		a.maybeAIReply(ctx, tenantID, conversationID, view)
	}
}

func (a *API) appendVisitorMessage(ctx context.Context, p auth.Principal, conversationID uuid.UUID,
	content, clientMessageID, messageType string, attachmentIDs []string, metadata map[string]any) (messageView, error) {
	view, err := a.appendMessage(ctx, p.TenantID, conversationID, messageInput{
		SenderType:      "VISITOR",
		SenderID:        &p.VisitorID,
		ClientMessageID: clientMessageID,
		MessageType:     messageType,
		Content:         content,
		AttachmentIDs:   attachmentIDs,
		Metadata:        metadata,
	})
	if err != nil {
		return messageView{}, err
	}
	a.touchVisitor(ctx, p.VisitorID)
	return view, nil
}

// autoAssign picks an agent when inbox auto-assignment is enabled and the
// conversation has no owner yet. It runs inside the message transaction so the
// assignment is atomic with the message that triggered it.
func (a *API) autoAssign(ctx context.Context, tx pgx.Tx, tenantID, conversationID uuid.UUID, current *uuid.UUID, senderType string) (*uuid.UUID, error) {
	if current != nil || senderType != "VISITOR" {
		return current, nil
	}
	var inboxID uuid.UUID
	var autoAssignEnabled bool
	var strategy string
	var maxConcurrent int
	err := tx.QueryRow(ctx, `
		select c.inbox_id, i.auto_assign,
		       coalesce(r.strategy, 'LOAD_BALANCED'), coalesce(r.max_concurrent, 5)
		  from conversation c
		  join inbox i on i.id = c.inbox_id
		  left join lateral (
		      select strategy, max_concurrent from routing_rule rr
		       where rr.tenant_id = c.tenant_id and rr.enabled
		         and (rr.inbox_id = c.inbox_id or rr.inbox_id is null)
		       order by rr.inbox_id nulls last limit 1
		  ) r on true
		 where c.id = $1`, conversationID).Scan(&inboxID, &autoAssignEnabled, &strategy, &maxConcurrent)
	if err != nil {
		return nil, nil //nolint:nilerr // assignment is best effort
	}
	if !autoAssignEnabled {
		return nil, nil
	}
	if strategy == "FIXED" {
		var fixed *uuid.UUID
		if tx.QueryRow(ctx, `select fixed_agent_id from routing_rule
			where tenant_id=$1 and enabled and strategy='FIXED' and (inbox_id=$2 or inbox_id is null)
			order by inbox_id nulls last limit 1`, tenantID, inboxID).Scan(&fixed) == nil && fixed != nil {
			if err := a.setAssignee(ctx, tx, tenantID, conversationID, *fixed); err == nil {
				return fixed, nil
			}
		}
		return nil, nil
	}

	// Load balanced: fewest open conversations, then least recently assigned.
	var candidate uuid.UUID
	err = tx.QueryRow(ctx, `
		select ag.id
		  from agent ag
		  join agent_inbox ai on ai.agent_id = ag.id and ai.inbox_id = $2
		  left join agent_presence ap on ap.agent_id = ag.id
		  left join lateral (
		      select count(*)::int as load, max(c.assigned_at) as last_assigned
		        from conversation c
		       where c.assignee_id = ag.id and c.status <> 'RESOLVED'
		  ) load on true
		 where ag.tenant_id = $1 and ag.status = 'ACTIVE'
		   and coalesce(ap.status, 'OFFLINE') = 'ONLINE'
		   and (ag.max_concurrent = 0 or load.load < ag.max_concurrent)
		 order by load.load asc nulls first, load.last_assigned asc nulls first, ag.created_at asc
		 limit 1`, tenantID, inboxID).Scan(&candidate)
	if err != nil {
		return nil, nil //nolint:nilerr // nobody online: leave it in the queue
	}
	if err := a.setAssignee(ctx, tx, tenantID, conversationID, candidate); err != nil {
		return nil, err
	}
	return &candidate, nil
}

func (a *API) setAssignee(ctx context.Context, tx pgx.Tx, tenantID, conversationID, agentID uuid.UUID) error {
	_, err := tx.Exec(ctx, `update conversation set assignee_id = $3, assigned_at = now(), updated_at = now()
		where id = $1 and tenant_id = $2 and assignee_id is null`, conversationID, tenantID, agentID)
	if err != nil {
		return err
	}
	// The detail document is built in Go rather than in SQL. Passing the same
	// placeholder as both the uuid actor_id column and, behind a cast, as a
	// jsonb field leaves PostgreSQL with two candidate types for one parameter
	// and it refuses the statement outright.
	_, err = tx.Exec(ctx, `insert into conversation_event(id, tenant_id, conversation_id, event_type, actor_type, actor_id, detail)
		values($1,$2,$3,'assigned','SYSTEM',$4,$5)`,
		uuid.New(), tenantID, conversationID, agentID, map[string]any{"assigneeId": agentID})
	return err
}

func (a *API) findByClientMessageID(ctx context.Context, conversationID uuid.UUID, clientMessageID string) (messageView, error) {
	var view messageView
	err := a.db.QueryRow(ctx, `
		select id, conversation_id, sender_type, sender_id, client_message_id, sequence, message_type, content, metadata, created_at
		  from message where conversation_id = $1 and client_message_id = $2`, conversationID, clientMessageID).
		Scan(&view.ID, &view.ConversationID, &view.SenderType, &view.SenderID, &view.ClientMessageID,
			&view.Sequence, &view.MessageType, &view.Content, &view.Metadata, &view.CreatedAt)
	if err != nil {
		return messageView{}, err
	}
	view.SenderName = a.senderName(ctx, view.SenderType, view.SenderID)
	view.Attachments = a.messageAttachments(ctx, view.ID)
	return view, nil
}

func (a *API) fetchMessages(ctx context.Context, conversationID uuid.UUID, after int64, limit int) ([]messageView, error) {
	rows, err := a.db.Query(ctx, `
		select m.id, m.conversation_id, m.sender_type, m.sender_id, m.client_message_id, m.sequence,
		       m.message_type, m.content, m.metadata, m.created_at,
		       coalesce(ag.display_name, coalesce(v.display_name, ''))
		  from message m
		  left join agent ag on ag.id = m.sender_id and m.sender_type = 'AGENT'
		  left join visitor v on v.id = m.sender_id and m.sender_type = 'VISITOR'
		 where m.conversation_id = $1 and m.sequence > $2
		 order by m.sequence asc
		 limit $3`, conversationID, after, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]messageView, 0, limit)
	ids := make([]uuid.UUID, 0, limit)
	for rows.Next() {
		var item messageView
		if err := rows.Scan(&item.ID, &item.ConversationID, &item.SenderType, &item.SenderID, &item.ClientMessageID,
			&item.Sequence, &item.MessageType, &item.Content, &item.Metadata, &item.CreatedAt, &item.SenderName); err != nil {
			return nil, err
		}
		items = append(items, item)
		ids = append(ids, item.ID)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(ids) == 0 {
		return items, nil
	}
	attachments, err := a.attachmentsForMessages(ctx, ids)
	if err != nil {
		return nil, err
	}
	for index := range items {
		items[index].Attachments = attachments[items[index].ID]
	}
	return items, nil
}

func (a *API) senderName(ctx context.Context, senderType string, senderID *uuid.UUID) string {
	if senderID == nil {
		return ""
	}
	var name string
	switch senderType {
	case "AGENT":
		_ = a.db.QueryRow(ctx, `select display_name from agent where id=$1`, *senderID).Scan(&name)
	case "VISITOR":
		_ = a.db.QueryRow(ctx, `select coalesce(display_name,'') from visitor where id=$1`, *senderID).Scan(&name)
	}
	return name
}

func (a *API) messageAttachments(ctx context.Context, messageID uuid.UUID) []attachmentView {
	grouped, err := a.attachmentsForMessages(ctx, []uuid.UUID{messageID})
	if err != nil {
		return nil
	}
	return grouped[messageID]
}

func (a *API) attachmentsForMessages(ctx context.Context, messageIDs []uuid.UUID) (map[uuid.UUID][]attachmentView, error) {
	rows, err := a.db.Query(ctx, `
		select id, message_id, file_name, content_type, size_bytes
		  from attachment where message_id = any($1)`, messageIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make(map[uuid.UUID][]attachmentView)
	for rows.Next() {
		var item attachmentView
		var messageID *uuid.UUID
		if err := rows.Scan(&item.ID, &messageID, &item.FileName, &item.ContentType, &item.SizeBytes); err != nil {
			return nil, err
		}
		item.URL = a.cfg.PublicBaseURL + a.cfg.Upload.PublicBasePath + "/" + item.ID.String()
		if messageID != nil {
			result[*messageID] = append(result[*messageID], item)
		}
	}
	return result, rows.Err()
}

func (a *API) queryConversation(ctx context.Context, conversationID uuid.UUID, view *conversationView) error {
	row := a.db.QueryRow(ctx, `
		select c.id, c.tenant_id, c.inbox_id, c.visitor_id, coalesce(c.subject,''), c.status, c.assignee_id,
		       coalesce(ag.display_name,''), c.priority, c.source, c.last_sequence,
		       coalesce(c.last_message_preview,''), c.last_message_at, c.agent_unread, c.visitor_unread,
		       coalesce(v.display_name,''), c.created_at, c.updated_at
		  from conversation c
		  join visitor v on v.id = c.visitor_id
		  left join agent ag on ag.id = c.assignee_id
		 where c.id = $1`, conversationID)
	if err := scanConversationRow(row, view); err != nil {
		return err
	}
	tags, err := a.conversationTags(ctx, conversationID)
	if err == nil {
		view.Tags = tags
	}
	return nil
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanConversation(rows pgx.Rows, view *conversationView) error { return scanConversationRow(rows, view) }

func scanConversationRow(row rowScanner, view *conversationView) error {
	return row.Scan(&view.ID, &view.TenantID, &view.InboxID, &view.VisitorID, &view.Subject, &view.Status,
		&view.AssigneeID, &view.AssigneeName, &view.Priority, &view.Source, &view.LastSequence,
		&view.LastMessagePreview, &view.LastMessageAt, &view.AgentUnread, &view.VisitorUnread,
		&view.VisitorName, &view.CreatedAt, &view.UpdatedAt)
}

func (a *API) conversationTags(ctx context.Context, conversationID uuid.UUID) ([]string, error) {
	rows, err := a.db.Query(ctx, `select t.name from conversation_tag ct join tag t on t.id = ct.tag_id
		where ct.conversation_id = $1 order by t.name`, conversationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	names := make([]string, 0, 4)
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		names = append(names, name)
	}
	return names, rows.Err()
}

// maybeAIReply asks the bot to answer a visitor message. The reply is stored as
// a normal agent message so the transcript stays complete and the visitor can
// continue with a human afterwards.
func (a *API) maybeAIReply(ctx context.Context, tenantID, conversationID uuid.UUID, question messageView) {
	if !a.cfg.AI.AutoReplyEnabled || !a.ai.Available() {
		return
	}
	var aiEnabled bool
	var botAgentID *uuid.UUID
	var handoffMessage string
	var assigned *uuid.UUID
	var status string
	err := a.db.QueryRow(ctx, `
		select coalesce(s.enabled,false), coalesce(s.handoff_message,'正在为你转接人工客服，请稍候。'),
		       c.assignee_id, c.status
		  from conversation c
		  left join ai_setting s on s.inbox_id = c.inbox_id
		 where c.id = $1`, conversationID).Scan(&aiEnabled, &handoffMessage, &assigned, &status)
	if err != nil || !aiEnabled || status == "RESOLVED" {
		return
	}
	if assigned != nil {
		// A human already owns the conversation: stay quiet instead of talking
		// over the agent.
		_, _ = a.db.Exec(ctx, `insert into ai_interaction(id, tenant_id, conversation_id, question_message_id, provider, answered, reason)
			values($1,$2,$3,$4,$5,false,$6)`, uuid.New(), tenantID, conversationID, question.ID, a.ai.ProviderName(), string(ai.ReasonAgentPresent))
		return
	}

	started := time.Now()
	reply, err := a.ai.Answer(ctx, tenantID, question.Content)
	latency := time.Since(started).Milliseconds()
	botAgentID = a.botAgentID(ctx, tenantID)
	interactionID := uuid.New()
	if err != nil {
		a.logger.Warn("ai answer failed", "error", err, "conversation", conversationID)
	}
	if reply.Handoff || strings.TrimSpace(reply.Content) == "" {
		_, _ = a.db.Exec(ctx, `insert into ai_interaction(id, tenant_id, conversation_id, question_message_id, provider, score, answered, reason, latency_ms, sources)
			values($1,$2,$3,$4,$5,$6,false,$7,$8,$9)`,
			interactionID, tenantID, conversationID, question.ID, a.ai.ProviderName(), reply.Score,
			string(reply.Reason), latency, reply.Sources)
		a.bumpDailyStat(ctx, tenantID, "ai_handoff")
		a.publish(ctx, a.conversationChannels(ctx, conversationID), realtime.Event{
			Type: "conversation.handoff", TenantID: tenantID.String(), ConversationID: conversationID.String(),
			Data: map[string]any{"message": handoffMessage, "reason": string(reply.Reason)},
		})
		return
	}

	content := reply.Content
	view, err := a.appendMessage(ctx, tenantID, conversationID, messageInput{
		SenderType:  "AGENT",
		SenderID:    botAgentID,
		MessageType: "TEXT",
		Content:     content,
		Metadata: map[string]any{
			"ai":       true,
			"provider": reply.Provider,
			"score":    reply.Score,
			"sources":  reply.Sources,
		},
	})
	if err != nil {
		a.logger.Warn("store ai answer failed", "error", err)
		return
	}
	_, _ = a.db.Exec(ctx, `insert into ai_interaction(id, tenant_id, conversation_id, question_message_id, answer_message_id, provider, score, answered, latency_ms, sources)
		values($1,$2,$3,$4,$5,$6,$7,true,$8,$9)`,
		interactionID, tenantID, conversationID, question.ID, view.ID, reply.Provider, reply.Score, latency, reply.Sources)
	a.bumpDailyStat(ctx, tenantID, "ai_answered")
}

// botAgentID returns the system agent that speaks for the bot inside a tenant.
func (a *API) botAgentID(ctx context.Context, tenantID uuid.UUID) *uuid.UUID {
	var id uuid.UUID
	err := a.db.QueryRow(ctx, `select id from agent where tenant_id=$1 and email='bot@relaydesk.local' limit 1`, tenantID).Scan(&id)
	if err == nil {
		return &id
	}
	inserted := uuid.New()
	_, err = a.db.Exec(ctx, `insert into agent(id, tenant_id, email, display_name, password_hash, role, status, max_concurrent)
		values($1,$2,'bot@relaydesk.local','AI 助手','!disabled', 'AGENT','DISABLED',0)`, inserted, tenantID)
	if err != nil {
		return nil
	}
	return &inserted
}

func isUniqueViolation(err error) bool {
	var pgErr interface{ SQLState() string }
	if errors.As(err, &pgErr) {
		return pgErr.SQLState() == "23505"
	}
	return strings.Contains(err.Error(), "23505") || strings.Contains(err.Error(), "duplicate key")
}

// recordFirstResponse updates the tenant daily statistic used by the operations
// dashboard to report first-response time.
func (a *API) recordFirstResponse(ctx context.Context, conversationID uuid.UUID) {
	var tenantID uuid.UUID
	var seconds int64
	err := a.db.QueryRow(ctx, `
		with first_visitor as (
		    select created_at from message where conversation_id = $1 and sender_type = 'VISITOR'
		     order by sequence limit 1
		)
		select c.tenant_id, greatest(extract(epoch from (now() - f.created_at))::bigint, 0)
		  from conversation c, first_visitor f
		 where c.id = $1 and c.first_response_at is null`, conversationID).Scan(&tenantID, &seconds)
	if err != nil {
		return
	}
	_, _ = a.db.Exec(ctx, `update conversation set first_response_at = now() where id = $1 and first_response_at is null`, conversationID)
	a.bumpDailyStat(ctx, tenantID, "first_response", int(seconds))
}

// bumpDailyStat keeps the operations dashboard fast without scanning messages.
func (a *API) bumpDailyStat(ctx context.Context, tenantID uuid.UUID, metric string, value ...int) {
	var statement string
	switch metric {
	case "conversations_started":
		statement = `insert into tenant_daily_stat(tenant_id, stat_date, conversations_started) values($1, current_date, 1)
			on conflict (tenant_id, stat_date) do update set conversations_started = tenant_daily_stat.conversations_started + 1`
	case "conversations_closed":
		statement = `insert into tenant_daily_stat(tenant_id, stat_date, conversations_closed) values($1, current_date, 1)
			on conflict (tenant_id, stat_date) do update set conversations_closed = tenant_daily_stat.conversations_closed + 1`
	case "messages_in":
		statement = `insert into tenant_daily_stat(tenant_id, stat_date, messages_in) values($1, current_date, 1)
			on conflict (tenant_id, stat_date) do update set messages_in = tenant_daily_stat.messages_in + 1`
	case "messages_out":
		statement = `insert into tenant_daily_stat(tenant_id, stat_date, messages_out) values($1, current_date, 1)
			on conflict (tenant_id, stat_date) do update set messages_out = tenant_daily_stat.messages_out + 1`
	case "ai_answered":
		statement = `insert into tenant_daily_stat(tenant_id, stat_date, ai_answered) values($1, current_date, 1)
			on conflict (tenant_id, stat_date) do update set ai_answered = tenant_daily_stat.ai_answered + 1`
	case "ai_handoff":
		statement = `insert into tenant_daily_stat(tenant_id, stat_date, ai_handoff) values($1, current_date, 1)
			on conflict (tenant_id, stat_date) do update set ai_handoff = tenant_daily_stat.ai_handoff + 1`
	case "first_response":
		seconds := 0
		if len(value) > 0 {
			seconds = value[0]
		}
		statement = `insert into tenant_daily_stat(tenant_id, stat_date, first_response_seconds, first_response_samples)
			values($1, current_date, $2, 1)
			on conflict (tenant_id, stat_date) do update set
				first_response_seconds = tenant_daily_stat.first_response_seconds + $2,
				first_response_samples = tenant_daily_stat.first_response_samples + 1`
		if _, err := a.db.Exec(ctx, statement, tenantID, seconds); err != nil {
			a.logger.Debug("stat update skipped", "error", err, "metric", metric)
		}
		return
	case "rating":
		score := 0
		if len(value) > 0 {
			score = value[0]
		}
		statement = `insert into tenant_daily_stat(tenant_id, stat_date, rating_sum, rating_count) values($1, current_date, $2, 1)
			on conflict (tenant_id, stat_date) do update set
				rating_sum = tenant_daily_stat.rating_sum + $2,
				rating_count = tenant_daily_stat.rating_count + 1`
		if _, err := a.db.Exec(ctx, statement, tenantID, score); err != nil {
			a.logger.Debug("stat update skipped", "error", err, "metric", metric)
		}
		return
	default:
		return
	}
	if _, err := a.db.Exec(ctx, statement, tenantID); err != nil {
		a.logger.Debug("stat update skipped", "error", err, "metric", metric)
	}
}
