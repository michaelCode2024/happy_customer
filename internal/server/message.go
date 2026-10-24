package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/tongyu/tongyu/internal/ai"
	"github.com/tongyu/tongyu/internal/auth"
	"github.com/tongyu/tongyu/internal/realtime"
	"github.com/tongyu/tongyu/internal/webhook"
)

// messageInput is the common description of a message regardless of who sends it.
type messageInput struct {
	CommerceTrusted        bool // 只由鉴权后的商城后端接口设置。
	ReceptionExempt        bool // 仅由服务端的AI或第三方消息入口设置，客户端元数据不能绕过接单。
	AutomationOnly         bool
	AutomationRespectAgent bool
	SenderType             string
	SenderID               *uuid.UUID
	ClientMessageID        string
	MessageType            string
	Content                string
	AttachmentIDs          []string
	Metadata               map[string]any
	ReplyToID              *uuid.UUID
	ForwardedFromID        *uuid.UUID
	// Private marks an internal note. It is a first-class field rather than a
	// metadata key because the database has to be able to filter on it: a note
	// that only carries metadata.private is invisible to a where clause, and one
	// forgotten filter would leak it to the visitor.
	Private bool
}

// messageColumns is the single column list every message read uses. Keeping it
// in one place is what makes scanMessage safe: a new field is added here and in
// scanMessage together, or the row scan fails loudly at the first request rather
// than silently returning a zero value.
//
// The name falls back to metadata.senderName because a message injected through
// the open API has no agent row behind it — the tenant's own backend supplied a
// display name, and without the fallback that message renders with a blank
// author in the console.
const messageColumns = `m.id, m.conversation_id, m.sender_type, m.sender_id, m.client_message_id, m.sequence,
		m.message_type, m.content, m.metadata, m.created_at, m.is_private,
		m.reply_to_id, m.edited_at, m.deleted_at, m.pinned_at, m.forwarded_from_id,
		coalesce(ag.display_name, v.display_name, m.metadata ->> 'senderName', '')`

const messageJoins = `
	  from message m
	  left join agent ag on ag.id = m.sender_id and m.sender_type = 'AGENT'
	  left join visitor v on v.id = m.sender_id and m.sender_type = 'VISITOR'`

// visibility controls which messages a read returns. A visitor may never see an
// internal note; an agent may. Making the caller state its audience is what
// stops a new endpoint from defaulting into the wrong answer.
type visibility struct {
	includePrivate bool
	// includeDeleted keeps recalled messages in the result as tombstones so a
	// client that already rendered the bubble can replace it instead of leaving
	// a hole in the transcript.
	includeDeleted bool
}

var visitorVisibility = visibility{includePrivate: false, includeDeleted: true}
var agentVisibility = visibility{includePrivate: true, includeDeleted: true}

func (v visibility) filter(alias string) string {
	clause := ""
	if !v.includePrivate {
		clause += " and not " + alias + ".is_private"
	}
	if !v.includeDeleted {
		clause += " and " + alias + ".deleted_at is null"
	}
	return clause
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
	case "TEXT", "IMAGE", "FILE", "EVENT", "SYSTEM", "RICH", "RATING", "AUDIO", "VIDEO", "LOCATION", "CARD":
	default:
		return messageView{}, errors.New("不支持的消息类型")
	}
	if messageType == "TEXT" && strings.TrimSpace(in.Content) == "" {
		return messageView{}, errors.New("消息内容不能为空")
	}

	if in.ClientMessageID != "" {
		existing, err := a.findByClientMessageID(ctx, conversationID, in.ClientMessageID)
		if err == nil {
			if !sameMessageRetry(existing, in) {
				return messageView{}, serviceError{"MESSAGE_ID_CONFLICT", "消息标识已被其他发送者或消息用途使用"}
			}
			return existing, nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return messageView{}, err
		}
	}

	metadata := orEmpty(in.Metadata)
	if messageType == "CARD" {
		if err := validateCommerceMetadata(metadata, in.CommerceTrusted); err != nil {
			return messageView{}, err
		}
	}
	if in.Private {
		metadata["private"] = true
	}
	encoded, err := json.Marshal(metadata)
	if err != nil {
		return messageView{}, err
	}

	tx, err := a.db.Begin(ctx)
	if err != nil {
		return messageView{}, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if !in.Private && messageType != "EVENT" && messageType != "SYSTEM" && messageType != "RATING" {
		if _, err = tx.Exec(ctx, `select pg_advisory_xact_lock(hashtextextended($1,0))`, tenantID.String()); err != nil {
			return messageView{}, err
		}
		if in.ClientMessageID != "" {
			if existing, e := a.findByClientMessageID(ctx, conversationID, in.ClientMessageID); e == nil {
				if !sameMessageRetry(existing, in) {
					return messageView{}, serviceError{"MESSAGE_ID_CONFLICT", "消息标识已被其他发送者或消息用途使用"}
				}
				return existing, nil
			}
		}
		if err = a.checkMessageQuota(ctx, tx, tenantID); err != nil {
			return messageView{}, err
		}
	}

	if in.SenderType == "AGENT" && !in.Private && !in.ReceptionExempt && in.SenderID != nil {
		// 区分未领取 / 他人接待 / 未确认接单，前端才能给出对得上的操作指引。
		var owner *uuid.UUID
		var accepted *time.Time
		if err = tx.QueryRow(ctx, `select assignee_id, accepted_at from conversation where id=$1 and tenant_id=$2 for update`, conversationID, tenantID).Scan(&owner, &accepted); err != nil {
			return messageView{}, err
		}
		if owner == nil {
			return messageView{}, serviceError{"RECEPTION_REQUIRED", "请先点击「开始接待」，再回复客户"}
		}
		if *owner != *in.SenderID {
			return messageView{}, serviceError{"NOT_ASSIGNEE", "该会话由其他客服接待中，请先转派给自己后再回复"}
		}
		if accepted == nil {
			return messageView{}, serviceError{"RECEPTION_REQUIRED", "请先点击「确认接单」，再回复客户"}
		}
	}

	if in.AutomationOnly {
		// 回复真正落库前锁定会话并复核人工接管，避免异步匹配与客服领取之间抢答。
		var allowed bool
		err = tx.QueryRow(ctx, `select not bot_paused and status<>'RESOLVED' and (not $3::boolean or assignee_id is null) from conversation where id=$1 and tenant_id=$2 for update`, conversationID, tenantID, in.AutomationRespectAgent).Scan(&allowed)
		if err != nil {
			return messageView{}, err
		}
		if !allowed {
			return messageView{}, errors.New("人工已接管或会话已经结束")
		}
	}

	// Row lock on the conversation serialises sequence allocation, so two
	// concurrent sends can never receive the same sequence.
	var sequence int64
	var assignee *uuid.UUID
	// A private note is not a visitor-visible event, so it must not move the
	// conversation preview or the agent unread counter — otherwise the queue
	// shows "1 new message" for a note the visitor never sent.
	err = tx.QueryRow(ctx, `
		update conversation
		   set last_sequence = last_sequence + 1,
		       last_message_at = case when $5 then last_message_at else now() end,
		       last_message_preview = case when $5 then last_message_preview else $3 end,
		       updated_at = now(),
		       agent_unread = case when $4 = 'VISITOR' then agent_unread + 1 else agent_unread end,
		       visitor_unread = case when $4 <> 'VISITOR' and not $5 then visitor_unread + 1 else visitor_unread end,
		       status = case when status = 'RESOLVED' and not $5 then 'OPEN' else status end
		 where id = $1 and tenant_id = $2
		 returning last_sequence, assignee_id`,
		conversationID, tenantID, messagePreview(messageType, in.Content, metadata), in.SenderType, in.Private).Scan(&sequence, &assignee)
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
		Metadata:        encoded,
		Private:         in.Private,
		ForwardedFromID: in.ForwardedFromID,
		CreatedAt:       nowUTC(),
	}
	if in.ReplyToID != nil {
		view.ReplyToID = in.ReplyToID
	}
	if _, err := tx.Exec(ctx, `
		insert into message(id, tenant_id, conversation_id, sender_type, sender_id, client_message_id,
			sequence, message_type, content, metadata, is_private, reply_to_id, forwarded_from_id, created_at)
		values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,
		view.ID, tenantID, conversationID, view.SenderType, view.SenderID, view.ClientMessageID,
		view.Sequence, view.MessageType, view.Content, encoded, view.Private, in.ReplyToID,
		in.ForwardedFromID, view.CreatedAt); err != nil {
		// A concurrent retry with the same clientMessageId hits the unique index.
		if in.ClientMessageID != "" && isUniqueViolation(err) {
			if existing, lookupErr := a.findByClientMessageID(ctx, conversationID, in.ClientMessageID); lookupErr == nil {
				if !sameMessageRetry(existing, in) {
					return messageView{}, serviceError{"MESSAGE_ID_CONFLICT", "消息标识已被其他发送者或消息用途使用"}
				}
				return existing, nil
			}
		}
		return messageView{}, err
	}

	// 与消息提交在同一事务内，只有真实发送成功才计入采纳发送；租户、会话和作者必须同时匹配。
	if raw, ok := in.Metadata["assistInteractionId"].(string); ok && in.SenderType == "AGENT" && !in.Private && messageType == "TEXT" {
		interactionID, parseErr := uuid.Parse(raw)
		if parseErr != nil {
			return messageView{}, serviceError{"INVALID_ASSIST_DRAFT", "AI 草稿标识不合法"}
		}
		tag, updateErr := tx.Exec(ctx, `update ai_interaction set sent_message_id=$1, edited_before_send=(btrim(draft_text)<>btrim($2))
		 where id=$3 and tenant_id=$4 and conversation_id=$5 and agent_id=$6 and adopted_at is not null
		 and task in ('SUGGEST','POLISH') and sent_message_id is null`, view.ID, in.Content, interactionID, tenantID, conversationID, in.SenderID)
		if updateErr != nil {
			return messageView{}, updateErr
		}
		if tag.RowsAffected() != 1 {
			return messageView{}, serviceError{"INVALID_ASSIST_DRAFT", "AI 草稿已发送或不属于当前会话，请重新生成"}
		}
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

	if in.SenderType == "VISITOR" && !in.Private && messageType != "EVENT" && messageType != "SYSTEM" && messageType != "RATING" {
		if err := enqueueMessageNotifications(ctx, tx, tenantID, conversationID, view.ID); err != nil {
			return messageView{}, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return messageView{}, err
	}
	// Attachments are linked inside the transaction but read back after it, so
	// the response and the realtime event both carry the download URLs. Without
	// this the sender of an image would receive a message with no picture.
	view.Attachments = a.messageAttachments(ctx, view.ID)
	if in.SenderType == "AGENT" && in.SenderID != nil {
		// 推送和历史使用同一个最新坐席名称，避免改名后仍显示旧会话身份。
		_ = a.db.QueryRow(ctx, `select display_name from agent where id=$1 and tenant_id=$2`, *in.SenderID, tenantID).Scan(&view.SenderName)
	}
	if in.ReplyToID != nil {
		view.ReplyTo = a.replyPreview(ctx, *in.ReplyToID)
	}
	a.afterMessageCommitted(ctx, tenantID, conversationID, view, newAssignee, in.SenderType)
	return view, nil
}

// 幂等标识不能把其他发送者的消息（尤其是内部备注）当成访客重试返回。
func sameMessageRetry(existing messageView, in messageInput) bool {
	if existing.SenderType != in.SenderType || existing.Private != in.Private {
		return false
	}
	if existing.SenderID == nil || in.SenderID == nil {
		return existing.SenderID == nil && in.SenderID == nil
	}
	return *existing.SenderID == *in.SenderID
}

// afterMessageCommitted runs everything that must not happen inside the
// transaction: realtime fan-out, webhook enqueue, statistics and the AI reply.
func (a *API) afterMessageCommitted(ctx context.Context, tenantID, conversationID uuid.UUID, view messageView, assignee *uuid.UUID, senderType string) {
	a.publishMessage(ctx, tenantID, conversationID, view)
	if !view.Private {
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
	}

	if assignee != nil {
		a.publish(ctx, []string{realtime.AgentChannel(assignee.String())}, realtime.Event{
			Type: "conversation.assigned", TenantID: tenantID.String(), ConversationID: conversationID.String(),
			Data: map[string]any{"assigneeId": assignee},
		})
	}

	if senderType == "VISITOR" {
		// AI 不能堵在访客发送热路径上：模型网关可能拖到几十秒，会直接抬高 POST /messages 延迟。
		// 用 WithoutCancel 保留租户/会话上下文，超时单独封顶，避免请求取消把回复掐掉。
		aiAsyncStartedTotal.Add(1)
		go func() {
			timeout := time.Duration(a.cfg.AI.TimeoutSeconds+5) * time.Second
			if timeout < 30*time.Second {
				timeout = 30 * time.Second
			}
			aiCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), timeout)
			defer cancel()
			if !a.maybeAutomationReply(aiCtx, tenantID, conversationID, view) {
				a.maybeAIReply(aiCtx, tenantID, conversationID, view)
			}
		}()
	}
}

// publishMessage fans one message out. A private note skips the conversation and
// visitor channels entirely: those are exactly the streams a visitor socket
// subscribes to, and a note has no business travelling down them.
func (a *API) publishMessage(ctx context.Context, tenantID, conversationID uuid.UUID, view messageView) {
	event := realtime.Event{
		Type: "message.created", TenantID: tenantID.String(), ConversationID: conversationID.String(), Data: view,
	}
	if view.Private {
		a.publish(ctx, a.agentOnlyChannels(ctx, conversationID), event)
		return
	}
	a.publish(ctx, a.conversationChannels(ctx, conversationID), event)
	a.publishMarketplaceConversation(ctx, conversationID)
}

// appendVisitorReply stores one visitor message. The reply target is nil for the
// ordinary case and set when the visitor quotes something earlier in the thread.
func (a *API) appendVisitorReply(ctx context.Context, p auth.Principal, conversationID uuid.UUID,
	content, clientMessageID, messageType string, attachmentIDs []string, metadata map[string]any,
	replyTo *uuid.UUID) (messageView, error) {
	// A blocked visitor is refused at the write path. Hiding messages after the
	// fact would still let an abuser fill the database and every agent's queue.
	var blocked bool
	if a.db.QueryRow(ctx, `select exists(select 1 from visitor_block where visitor_id = $1)`, p.VisitorID).Scan(&blocked) == nil && blocked {
		return messageView{}, errVisitorBlocked
	}
	view, err := a.appendMessage(ctx, p.TenantID, conversationID, messageInput{
		SenderType:      "VISITOR",
		SenderID:        &p.VisitorID,
		ClientMessageID: clientMessageID,
		MessageType:     messageType,
		Content:         content,
		AttachmentIDs:   attachmentIDs,
		Metadata:        metadata,
		ReplyToID:       replyTo,
	})
	if err != nil {
		return messageView{}, err
	}
	a.touchVisitor(ctx, p.VisitorID)
	return view, nil
}

var errVisitorBlocked = errors.New("该访客已被拉黑")

// autoAssign picks an agent when inbox auto-assignment is enabled and the
// conversation has no owner yet. It runs inside the message transaction so the
// assignment is atomic with the message that triggered it.
func (a *API) autoAssign(ctx context.Context, tx pgx.Tx, tenantID, conversationID uuid.UUID, current *uuid.UUID, senderType string) (*uuid.UUID, error) {
	if current != nil || senderType != "VISITOR" {
		return current, nil
	}
	// 启用自动回复或 AI 接待的入口先由机器人回答；转人工 / 客服主动接管后再按原有规则分配。
	// 只看 automation 会漏掉「只开了 AI」的入口：坐席登录会标 ONLINE，访客一来就被分配，AI 立刻 AGENT_ALREADY_ASSIGNED。
	var botFirst, botPaused bool
	if tx.QueryRow(ctx, `
		select coalesce((ia.config->>'enabled')::boolean,false) or coalesce(s.enabled,false),
		       c.bot_paused
		  from conversation c
		  left join inbox_automation ia on ia.inbox_id = c.inbox_id
		  left join ai_setting s on s.inbox_id = c.inbox_id
		 where c.id = $1`, conversationID).Scan(&botFirst, &botPaused) == nil && botFirst && !botPaused {
		return nil, nil
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
	}

	if strategy == "ROUND_ROBIN" {
		// Round robin walks a stable, rotating order. The rotation is derived
		// from how many conversations the inbox has already handed out, which
		// keeps it stateless: no cursor table to keep in sync across instances,
		// and an agent added mid-shift joins the rotation on the next message.
		candidate, err := a.roundRobinCandidate(ctx, tx, tenantID, inboxID, conversationID, maxConcurrent)
		if err != nil {
			return nil, nil //nolint:nilerr // nobody eligible: leave it queued
		}
		if err := a.setAssignee(ctx, tx, tenantID, conversationID, candidate); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, nil
			}
			return nil, err
		}
		return &candidate, nil
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
           and not exists(select 1 from reception_timeout rt where rt.agent_id=ag.id and rt.conversation_id=$3)
		   and (ag.max_concurrent = 0 or load.load < ag.max_concurrent)
		 order by load.load asc nulls first, load.last_assigned asc nulls first, ag.created_at asc
		 limit 1`, tenantID, inboxID, conversationID).Scan(&candidate)
	if err != nil {
		return nil, nil //nolint:nilerr // nobody online: leave it in the queue
	}
	if err := a.setAssignee(ctx, tx, tenantID, conversationID, candidate); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &candidate, nil
}

// completeHandoff 暂停机器人并按路由规则分配客服。
// 可重复调用：已暂停时仍会尝试补分配；分配与接单使用独立状态通知。
func (a *API) completeHandoff(ctx context.Context, tenantID, conversationID uuid.UUID) (*uuid.UUID, string, error) {
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return nil, "", err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var current *uuid.UUID
	var paused bool
	var accepted *time.Time
	if err := tx.QueryRow(ctx, `
		select assignee_id, bot_paused, accepted_at
		  from conversation
		 where id = $1 and tenant_id = $2
		 for update`, conversationID, tenantID).Scan(&current, &paused, &accepted); err != nil {
		return nil, "", err
	}
	if _, err = tx.Exec(ctx, `update conversation set handoff_requested_at=coalesce(handoff_requested_at,now()) where id=$1`, conversationID); err != nil {
		return nil, "", err
	}
	if paused && current != nil {
		name := "人工客服"
		if err = tx.QueryRow(ctx, `select display_name from agent where id=$1`, *current).Scan(&name); err != nil {
			return nil, "", err
		}
		state, content := "ASSIGNED", fmt.Sprintf("已分配给客服「%s」，等待客服接待。", name)
		if accepted != nil {
			state = "ACCEPTED"
			content = fmt.Sprintf("客服「%s」已在接待中，请直接描述您的问题。", name)
		}
		if err = receptionNotice(ctx, tx, tenantID, conversationID, content, state); err != nil {
			return nil, "", err
		}
	}
	if !paused {
		if err := receptionNotice(ctx, tx, tenantID, conversationID, "正在为您转接人工客服。", "TRANSFERRING"); err != nil {
			return nil, "", err
		}
		if _, err := tx.Exec(ctx, `update conversation set bot_paused = true, handoff_requested_at=coalesce(handoff_requested_at,now()), updated_at = now() where id = $1`, conversationID); err != nil {
			return nil, "", err
		}
	}
	assignee, err := a.autoAssign(ctx, tx, tenantID, conversationID, current, "VISITOR")
	if err != nil {
		return nil, "", err
	}
	if assignee == nil {
		if err := receptionNotice(ctx, tx, tenantID, conversationID, "暂无客服可以接单，已为您排队。", "QUEUED"); err != nil {
			return nil, "", err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, "", err
	}
	a.flushReceptionNotices(ctx)
	if assignee == nil {
		// 无人可接时保留待接队列，但必须告诉访客，避免停在「请稍候」无下文。
		return nil, "暂无客服立即接待，已为您排队，上线后会尽快回复。", nil
	}
	name := "人工客服"
	_ = a.db.QueryRow(ctx, `select display_name from agent where id = $1`, *assignee).Scan(&name)
	if strings.TrimSpace(name) == "" {
		name = "人工客服"
	}
	// 分配后可能已按入口 auto_accept 直接接单，需重新读取，不能沿用进事务时的 accepted。
	var nowAccepted *time.Time
	_ = a.db.QueryRow(ctx, `select accepted_at from conversation where id=$1`, conversationID).Scan(&nowAccepted)
	if accepted != nil || nowAccepted != nil {
		return assignee, fmt.Sprintf("客服「%s」已在接待中，请直接描述您的问题。", name), nil
	}
	return assignee, fmt.Sprintf("已分配给客服「%s」，等待客服接待。", name), nil
}

// roundRobinCandidate returns the agent whose turn it is. `nth` is the total
// number of conversations the inbox has ever started, so the order advances by
// exactly one per assigned conversation even when several instances are running.
func (a *API) roundRobinCandidate(ctx context.Context, tx pgx.Tx, tenantID, inboxID, conversationID uuid.UUID, maxConcurrent int) (uuid.UUID, error) {
	var eligible []uuid.UUID
	rows, err := tx.Query(ctx, `
		select ag.id
		  from agent ag
		  join agent_inbox ai on ai.agent_id = ag.id and ai.inbox_id = $2
		  left join agent_presence ap on ap.agent_id = ag.id
		  left join lateral (
		      select count(*)::int as load from conversation c
		       where c.assignee_id = ag.id and c.status <> 'RESOLVED'
		  ) load on true
		 where ag.tenant_id = $1 and ag.status = 'ACTIVE'
		   and coalesce(ap.status, 'OFFLINE') = 'ONLINE'
           and not exists(select 1 from reception_timeout rt where rt.agent_id=ag.id and rt.conversation_id=$3)
		   and (ag.max_concurrent = 0 or load.load < ag.max_concurrent)
		 order by ag.created_at asc, ag.id asc`, tenantID, inboxID, conversationID)
	if err != nil {
		return uuid.Nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id uuid.UUID
		if rows.Scan(&id) == nil {
			eligible = append(eligible, id)
		}
	}
	if err := rows.Err(); err != nil {
		return uuid.Nil, err
	}
	if len(eligible) == 0 {
		return uuid.Nil, pgx.ErrNoRows
	}
	var handedOut int64
	if tx.QueryRow(ctx, `select count(*) from conversation where inbox_id = $1`, inboxID).Scan(&handedOut) != nil {
		handedOut = 0
	}
	_ = maxConcurrent
	return eligible[int(handedOut%int64(len(eligible)))], nil
}

func (a *API) setAssignee(ctx context.Context, tx pgx.Tx, tenantID, conversationID, agentID uuid.UUID) error {
	var capacity int
	if err := tx.QueryRow(ctx, `select max_concurrent from agent where id=$1 and tenant_id=$2 for update`, agentID, tenantID).Scan(&capacity); err != nil {
		return err
	}
	var load int
	if err := tx.QueryRow(ctx, `select count(*) from conversation where assignee_id=$1 and status<>'RESOLVED'`, agentID).Scan(&load); err != nil {
		return err
	}
	if capacity > 0 && load >= capacity {
		return pgx.ErrNoRows
	}
	var name string
	if err := tx.QueryRow(ctx, `select display_name from agent ag where id=$1 and tenant_id=$2 and status='ACTIVE' and exists(select 1 from agent_inbox ai join conversation c on c.inbox_id=ai.inbox_id where ai.agent_id=ag.id and c.id=$3) and exists(select 1 from agent_presence ap where ap.agent_id=ag.id and ap.status='ONLINE') and not exists(select 1 from reception_timeout rt where rt.agent_id=ag.id and rt.conversation_id=$3)`, agentID, tenantID, conversationID).Scan(&name); err != nil {
		return err
	}
	// 入口开关 auto_accept：默认 false，分配后仍要手动点接待；开启则直接写入 accepted_at。
	var autoAccept bool
	_ = tx.QueryRow(ctx, `
		select coalesce(i.auto_accept, false)
		  from conversation c
		  join inbox i on i.id = c.inbox_id
		 where c.id = $1`, conversationID).Scan(&autoAccept)

	assignSQL := `update conversation c set assignee_id=$3,assigned_at=now(),accepted_at=null,bot_paused=true,handoff_requested_at=coalesce(handoff_requested_at,now()),assignment_expires_at=now()+make_interval(secs=>coalesce((select acceptance_timeout_seconds from routing_rule rr where rr.tenant_id=$2 and rr.enabled and (rr.inbox_id=c.inbox_id or rr.inbox_id is null) order by rr.inbox_id nulls last limit 1),60)),updated_at=now() where id=$1 and tenant_id=$2 and assignee_id is null`
	if autoAccept {
		assignSQL = `update conversation c set assignee_id=$3,assigned_at=now(),accepted_at=now(),bot_paused=true,handoff_requested_at=coalesce(handoff_requested_at,now()),assignment_expires_at=null,updated_at=now() where id=$1 and tenant_id=$2 and assignee_id is null`
	}
	tag, err := tx.Exec(ctx, assignSQL, conversationID, tenantID, agentID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return pgx.ErrNoRows
	}
	if autoAccept {
		if err = receptionNotice(ctx, tx, tenantID, conversationID, fmt.Sprintf("客服「%s」已接入，请继续描述您的问题。", name), "ACCEPTED"); err != nil {
			return err
		}
		// 自动接单也要通知坐席，避免只看到访客消息却不知道会话已落到自己名下。
		if _, err = tx.Exec(ctx, `with inserted as (
			insert into agent_notification(tenant_id,agent_id,conversation_id,kind,title)
			values($1,$2,$3,'ASSIGNED','新会话已自动接入，可直接回复')
			returning id,agent_id
			) insert into push_delivery(notification_id,subscription_id)
			select n.id,s.id from inserted n join push_subscription s on s.agent_id=n.agent_id`,
			tenantID, agentID, conversationID); err != nil {
			return err
		}
	} else if err = receptionNotice(ctx, tx, tenantID, conversationID, fmt.Sprintf("已分配给客服「%s」，等待客服接待。", name), "ASSIGNED"); err != nil {
		return err
	}

	// The detail document is built in Go rather than in SQL. Passing the same
	// placeholder as both the uuid actor_id column and, behind a cast, as a
	// jsonb field leaves PostgreSQL with two candidate types for one parameter
	// and it refuses the statement outright.
	_, err = tx.Exec(ctx, `insert into conversation_event(id, tenant_id, conversation_id, event_type, actor_type, actor_id, detail)
		values($1,$2,$3,'assigned','SYSTEM',$4,$5)`,
		uuid.New(), tenantID, conversationID, agentID, map[string]any{"assigneeId": agentID, "autoAccept": autoAccept})
	return err
}

func (a *API) findByClientMessageID(ctx context.Context, conversationID uuid.UUID, clientMessageID string) (messageView, error) {
	view, err := scanMessageRow(a.db.QueryRow(ctx, "select "+messageColumns+messageJoins+" where m.conversation_id=$1 and m.client_message_id=$2", conversationID, clientMessageID))
	if err != nil {
		return messageView{}, err
	}
	if view.DeletedAt == nil {
		view.Attachments = a.messageAttachments(ctx, view.ID)
	}
	return view, nil
}

func (a *API) fetchMessages(ctx context.Context, conversationID uuid.UUID, after int64, limit int) ([]messageView, error) {
	page, err := a.pageMessages(ctx, conversationID, after, 0, limit, agentVisibility)
	return page.Items, err
}

// messagePage is the shape every transcript read returns. Two booleans rather
// than one: `after` paging and `before` paging answer different questions, and a
// visitor opening a long thread needs to know separately whether there are newer
// messages to pull and older messages to scroll into.
type messagePage struct {
	Items         []messageView `json:"items"`
	HasMore       bool          `json:"hasMore"`
	HasOlder      bool          `json:"hasOlder"`
	FirstSequence int64         `json:"firstSequence,omitempty"`
	LastSequence  int64         `json:"lastSequence,omitempty"`
}

// pageMessages reads one page of a transcript. Supplying `before` switches it to
// the upward page, which is what the transcript needs when a visitor scrolls
// back: the forward cursor can only answer "what came after", and reaching older
// messages through it means fetching and discarding everything in between.
func (a *API) pageMessages(ctx context.Context, conversationID uuid.UUID, after, before int64, limit int, view visibility) (messagePage, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	if before > 0 {
		// One extra row is how "is there another page" is answered without a
		// second count query. The extra row is dropped before returning.
		items, err := a.fetchMessagesBefore(ctx, conversationID, before, limit+1, view)
		if err != nil {
			return messagePage{}, err
		}
		page := messagePage{Items: append([]messageView(nil), items...), HasMore: true}
		if len(items) > limit {
			page.HasOlder = true
			page.Items = append([]messageView(nil), items[len(items)-limit:]...)
		}
		return a.finishPage(ctx, conversationID, page, view)
	}
	items, err := a.fetchMessagesVisible(ctx, conversationID, after, limit+1, view)
	if err != nil {
		return messagePage{}, err
	}
	page := messagePage{Items: append([]messageView(nil), items...)}
	if len(items) > limit {
		page.HasMore = true
		page.Items = append([]messageView(nil), items[:limit]...)
	}
	return a.finishPage(ctx, conversationID, page, view)
}

// finishPage fills in the sequence bounds and decides whether older messages
// exist below the page. The lowest visible sequence is compared against the
// lowest sequence the caller is allowed to see, because a page that starts at
// sequence 40 of a thread whose first visitor message is sequence 12 still has
// thirty older messages to scroll into.
func (a *API) finishPage(ctx context.Context, conversationID uuid.UUID, page messagePage, view visibility) (messagePage, error) {
	if len(page.Items) > 0 {
		page.FirstSequence = page.Items[0].Sequence
		page.LastSequence = page.Items[len(page.Items)-1].Sequence
	}
	var lowest int64
	var highest int64
	err := a.db.QueryRow(ctx, `select coalesce(min(m.sequence),0), coalesce(max(m.sequence),0)
		  from message m where m.conversation_id = $1`+view.filter("m"), conversationID).Scan(&lowest, &highest)
	if err != nil {
		return page, nil
	}
	if page.FirstSequence == 0 {
		page.FirstSequence = highest
	}
	page.HasOlder = page.HasOlder || page.FirstSequence > lowest
	return page, nil
}

// fetchMessagesVisible pages a transcript forward from a sequence. `after` is
// the incremental-pull cursor, which is why the same call serves both a client
// catching up after a reconnect and a client opening a thread for the first time.
func (a *API) fetchMessagesVisible(ctx context.Context, conversationID uuid.UUID, after int64, limit int, view visibility) ([]messageView, error) {
	rows, err := a.db.Query(ctx, `select `+messageColumns+messageJoins+`
		 where m.conversation_id = $1 and m.sequence > $2`+view.filter("m")+`
		 order by m.sequence asc
		 limit $3`, conversationID, after, limit)
	if err != nil {
		return nil, err
	}
	return a.collectMessages(ctx, rows, limit)
}

// fetchMessagesBefore is the upward page: it returns the `limit` messages that
// sit immediately before a sequence, in ascending order. Paging backwards is
// what a transcript needs when the visitor scrolls up, and it cannot be expressed
// with the forward cursor without fetching and discarding everything above it.
func (a *API) fetchMessagesBefore(ctx context.Context, conversationID uuid.UUID, before int64, limit int, view visibility) ([]messageView, error) {
	if before <= 0 {
		before = int64(^uint64(0) >> 1)
	}
	rows, err := a.db.Query(ctx, `select * from (
			select `+messageColumns+messageJoins+`
			 where m.conversation_id = $1 and m.sequence < $2`+view.filter("m")+`
			 order by m.sequence desc
			 limit $3
		) page
		order by sequence asc`, conversationID, before, limit)
	if err != nil {
		return nil, err
	}
	return a.collectMessages(ctx, rows, limit)
}

func (a *API) collectMessages(ctx context.Context, rows pgx.Rows, limit int) ([]messageView, error) {
	defer rows.Close()
	items := make([]messageView, 0, limit)
	ids := make([]uuid.UUID, 0, limit)
	replyIDs := make([]uuid.UUID, 0, 4)
	for rows.Next() {
		item, err := scanMessageRow(rows)
		if err != nil {
			return nil, err
		}
		if item.ReplyToID != nil {
			replyIDs = append(replyIDs, *item.ReplyToID)
		}
		items = append(items, item)
		ids = append(ids, item.ID)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return items, nil
	}
	attachments, err := a.attachmentsForMessages(ctx, ids)
	if err != nil {
		return nil, err
	}
	reactions, err := a.reactionsForMessages(ctx, ids)
	if err != nil {
		return nil, err
	}
	replies, err := a.replyPreviews(ctx, replyIDs)
	if err != nil {
		return nil, err
	}
	for index := range items {
		items[index].Attachments = attachments[items[index].ID]
		items[index].Reactions = reactions[items[index].ID]
		if items[index].ReplyToID != nil {
			if preview, ok := replies[*items[index].ReplyToID]; ok {
				items[index].ReplyTo = &preview
			}
		}
	}
	return items, nil
}

func scanMessageRow(rows rowScanner) (messageView, error) {
	var item messageView
	var metadata []byte
	err := rows.Scan(&item.ID, &item.ConversationID, &item.SenderType, &item.SenderID, &item.ClientMessageID,
		&item.Sequence, &item.MessageType, &item.Content, &metadata, &item.CreatedAt, &item.Private,
		&item.ReplyToID, &item.EditedAt, &item.DeletedAt, &item.PinnedAt, &item.ForwardedFromID, &item.SenderName)
	if err != nil {
		return messageView{}, err
	}
	item.Metadata = metadata
	if item.DeletedAt != nil {
		// A recalled message keeps its row so every client can replace the
		// bubble in place, but the body never leaves the server again.
		item.Content = ""
		item.Attachments = nil
		item.Metadata = nil
	}
	return item, nil
}

// replyPreview is the quoted fragment shown above a reply. It is deliberately
// short: the client renders one line, and sending the whole parent would make
// every reply as expensive as the message it quotes.
type replyPreview struct {
	ID          uuid.UUID `json:"id"`
	Sequence    int64     `json:"sequence"`
	SenderType  string    `json:"senderType"`
	SenderName  string    `json:"senderName,omitempty"`
	MessageType string    `json:"messageType"`
	Content     string    `json:"content"`
	Deleted     bool      `json:"deleted,omitempty"`
}

func (a *API) replyPreviews(ctx context.Context, ids []uuid.UUID) (map[uuid.UUID]replyPreview, error) {
	result := make(map[uuid.UUID]replyPreview, len(ids))
	if len(ids) == 0 {
		return result, nil
	}
	rows, err := a.db.Query(ctx, `
		select m.id, m.sequence, m.sender_type, m.message_type, m.content, m.deleted_at,
		       coalesce(ag.display_name, coalesce(v.display_name, ''))
		  from message m
		  left join agent ag on ag.id = m.sender_id and m.sender_type = 'AGENT'
		  left join visitor v on v.id = m.sender_id and m.sender_type = 'VISITOR'
		 where m.id = any($1)`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var preview replyPreview
		var deletedAt *time.Time
		if err := rows.Scan(&preview.ID, &preview.Sequence, &preview.SenderType, &preview.MessageType,
			&preview.Content, &deletedAt, &preview.SenderName); err != nil {
			return nil, err
		}
		if deletedAt != nil {
			preview.Deleted = true
			preview.Content = ""
		}
		preview.Content = truncateRunes(preview.Content, 160)
		result[preview.ID] = preview
	}
	return result, rows.Err()
}

func (a *API) replyPreview(ctx context.Context, id uuid.UUID) *replyPreview {
	previews, err := a.replyPreviews(ctx, []uuid.UUID{id})
	if err != nil {
		return nil
	}
	preview, ok := previews[id]
	if !ok {
		return nil
	}
	return &preview
}

// messageReactionView aggregates one emoji with the actors who chose it, so the
// client can render a count and highlight the ones the current user picked
// without a second request.
type messageReactionView struct {
	Emoji      string      `json:"emoji"`
	Count      int         `json:"count"`
	Actors     []uuid.UUID `json:"actors"`
	VisitorSet bool        `json:"visitorReacted,omitempty"`
}

func (a *API) reactionsForMessages(ctx context.Context, ids []uuid.UUID) (map[uuid.UUID][]messageReactionView, error) {
	result := make(map[uuid.UUID][]messageReactionView)
	if len(ids) == 0 {
		return result, nil
	}
	rows, err := a.db.Query(ctx, `
		select message_id, emoji, array_agg(actor_id) as actors,
		       bool_or(actor_type = 'VISITOR') as visitor_reacted
		  from message_reaction
		 where message_id = any($1)
		 group by message_id, emoji
		 order by min(created_at)`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var messageID uuid.UUID
		var item messageReactionView
		if err := rows.Scan(&messageID, &item.Emoji, &item.Actors, &item.VisitorSet); err != nil {
			return nil, err
		}
		item.Count = len(item.Actors)
		result[messageID] = append(result[messageID], item)
	}
	return result, rows.Err()
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
		select a.id, a.message_id, a.file_name, a.content_type, a.size_bytes
		  from attachment a
		  join message m on m.id = a.message_id
		 where a.message_id = any($1) and m.deleted_at is null`, messageIDs)
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
		       coalesce(v.display_name,''), c.created_at, c.updated_at, c.accepted_at, c.assignment_expires_at
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

func scanConversation(rows pgx.Rows, view *conversationView) error {
	return scanConversationRow(rows, view)
}

func scanConversationRow(row rowScanner, view *conversationView) error {
	return row.Scan(&view.ID, &view.TenantID, &view.InboxID, &view.VisitorID, &view.Subject, &view.Status,
		&view.AssigneeID, &view.AssigneeName, &view.Priority, &view.Source, &view.LastSequence,
		&view.LastMessagePreview, &view.LastMessageAt, &view.AgentUnread, &view.VisitorUnread,
		&view.VisitorName, &view.CreatedAt, &view.UpdatedAt, &view.AcceptedAt, &view.AssignmentExpiresAt)
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
	if !a.tenantHasFeature(ctx, tenantID, "ai") {
		return
	}
	if !a.cfg.AI.AutoReplyEnabled || !a.ai.Available() {
		return
	}
	var aiEnabled bool
	var botPaused bool
	var botAgentID *uuid.UUID
	var handoffMessage string
	var assigned *uuid.UUID
	var status string
	var inboxThreshold *float64
	// The per-inbox threshold is what the tenant actually configured; the
	// environment value is only the default for inboxes that never set one.
	// Ignoring the column made the setting screen decorative.
	err := a.db.QueryRow(ctx, `
		select coalesce(s.enabled,false), coalesce(s.handoff_message,'正在为你转接人工客服，请稍候。'),
		       c.assignee_id, c.status, s.confidence_threshold::float8, c.bot_paused
		  from conversation c
		  left join ai_setting s on s.inbox_id = c.inbox_id
		 where c.id = $1`, conversationID).Scan(&aiEnabled, &handoffMessage, &assigned, &status, &inboxThreshold, &botPaused)
	if err != nil || !aiEnabled || botPaused || status == "RESOLVED" {
		return
	}
	if assigned != nil {
		// A human already owns the conversation: stay quiet instead of talking
		// over the agent.
		_, _ = a.db.Exec(ctx, `insert into ai_interaction(id, tenant_id, conversation_id, question_message_id, provider, answered, reason)
			values($1,$2,$3,$4,$5,false,$6)`, uuid.New(), tenantID, conversationID, question.ID, a.ai.ProviderName(), string(ai.ReasonAgentPresent))
		return
	}
	// A visitor talking to the bot while a human is online still gets the bot
	// first: the inbox is configured that way, and the handoff below hands over
	// cleanly when the bot cannot answer.

	finish, quotaErr := a.reserveAIQuota(ctx, tenantID)
	if quotaErr != nil {
		_, _, _ = a.completeHandoff(ctx, tenantID, conversationID)
		return
	}
	success := false
	defer func() { finish(success) }()
	started := time.Now()
	botAgentID = a.botAgentID(ctx, tenantID)
	interactionID := uuid.New()
	aiReq := ai.Request{
		TenantID:     tenantID,
		Question:     question.Content,
		History:      a.recentTranscript(ctx, conversationID, question.Sequence, 8),
		Threshold:    inboxThreshold,
		Conversation: conversationID,
	}

	// 流式优先：逐字推送访客，贴合「正在输入→逐字」的即时手感；不支持流式或失败则回退一次性生成。
	if tokens, gate, streamErr := a.ai.StreamAnswer(ctx, aiReq); streamErr == nil && tokens != nil {
		var builder strings.Builder
		channels := a.conversationChannels(ctx, conversationID)
		for tok := range tokens {
			builder.WriteString(tok)
			a.publish(ctx, channels, realtime.Event{
				Type: "conversation.aiToken", TenantID: tenantID.String(), ConversationID: conversationID.String(),
				Data: map[string]any{"token": tok},
			})
		}
		latency := time.Since(started).Milliseconds()
		full := strings.TrimSpace(builder.String())
		if full == "" || a.ai.LooksInjected(full) {
			gate.Reason = ai.ReasonProviderFail
			gate.Handoff = true
			a.storeAIHandoff(ctx, tenantID, conversationID, question, interactionID, gate, handoffMessage, latency)
			return
		}
		success = true
		a.storeAIMessage(ctx, tenantID, conversationID, question.ID, botAgentID, full, gate, interactionID, latency)
		return
	}

	reply, err := a.ai.AnswerWith(ctx, aiReq)
	latency := time.Since(started).Milliseconds()
	if err != nil {
		a.logger.Warn("ai answer failed", "error", err, "conversation", conversationID)
	}
	if reply.Handoff || strings.TrimSpace(reply.Content) == "" {
		a.storeAIHandoff(ctx, tenantID, conversationID, question, interactionID, reply, handoffMessage, latency)
		return
	}
	success = true
	a.storeAIMessage(ctx, tenantID, conversationID, question.ID, botAgentID, reply.Content, reply, interactionID, latency)
}

// storeAIHandoff records a low-confidence / empty / injected AI outcome and asks a
// human to take over. It is the single handoff write path shared by the streaming
// and one-shot answer flows.
func (a *API) storeAIHandoff(ctx context.Context, tenantID, conversationID uuid.UUID, question messageView, interactionID uuid.UUID, reply ai.Reply, handoffMessage string, latency int64) {
	// 没有命中知识时来源为空数组，不能把 nil 写成 SQL NULL 导致缺口记录丢失。
	_, recordErr := a.db.Exec(ctx, `insert into ai_interaction(id, tenant_id, conversation_id, question_message_id, provider, score, answered, reason, latency_ms, sources)
		values($1,$2,$3,$4,$5,$6,false,$7,$8,coalesce($9,'{}'::text[]))`,
		interactionID, tenantID, conversationID, question.ID, reply.Provider, reply.Score,
		string(reply.Reason), latency, reply.Sources)
	if recordErr != nil {
		a.logger.Error("record AI handoff failed", "error", recordErr)
	}
	a.bumpDailyStat(ctx, tenantID, "ai_handoff")
	// AI 低置信度转人工以前只落一句提示、不暂停机器人也不分配，访客会一直停在「请稍候」。
	if _, _, err := a.completeHandoff(ctx, tenantID, conversationID); err != nil {
		a.logger.Warn("ai handoff failed", "error", err)
	}
}

// storeAIMessage persists a generated AI answer as an agent message and records the
// interaction. It is the single answer write path shared by the streaming and
// one-shot flows.
func (a *API) storeAIMessage(ctx context.Context, tenantID, conversationID, questionID uuid.UUID, botAgentID *uuid.UUID, content string, reply ai.Reply, interactionID uuid.UUID, latency int64) {
	view, err := a.appendMessage(ctx, tenantID, conversationID, messageInput{
		ReceptionExempt: true,
		SenderType:      "AGENT",
		SenderID:        botAgentID,
		MessageType:     "TEXT",
		Content:         content,
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
		interactionID, tenantID, conversationID, questionID, view.ID, reply.Provider, reply.Score, latency, reply.Sources)
	a.bumpDailyStat(ctx, tenantID, "ai_answered")
}

// recentTranscript gives the model the last few turns. Answering a follow-up
// like "那要多久？" without the previous question is impossible, which is why the
// stateless single-turn prompt produced nonsense on multi-message conversations.
func (a *API) recentTranscript(ctx context.Context, conversationID uuid.UUID, before int64, limit int) []ai.Turn {
	// 助手传 0 表示读取最新记录；不能按 sequence < 0 过滤掉整段对话。
	if before <= 0 {
		before = 1<<63 - 1
	}
	rows, err := a.db.Query(ctx, `select * from (
			select m.sender_type, m.content, m.sequence
			  from message m
			 where m.conversation_id = $1 and m.sequence < $2
			   and not m.is_private and m.deleted_at is null and m.message_type = 'TEXT'
			 order by m.sequence desc
			 limit $3
		) page order by sequence asc`, conversationID, before, limit)
	if err != nil {
		return nil
	}
	defer rows.Close()
	turns := make([]ai.Turn, 0, limit)
	for rows.Next() {
		var senderType, content string
		var sequence int64
		if rows.Scan(&senderType, &content, &sequence) != nil {
			continue
		}
		role := "assistant"
		if senderType == "VISITOR" {
			role = "user"
		}
		turns = append(turns, ai.Turn{Role: role, Content: content})
	}
	return turns
}

// integrationAgentID returns the agent row that speaks for a tenant's own
// backend. Without it, a message injected through the open API would carry a
// NULL sender: the transcript would show a blank author, and agent statistics —
// which group by sender_id — would silently drop every message the tenant sent
// through its integration.
func (a *API) integrationAgentID(ctx context.Context, tenantID uuid.UUID) *uuid.UUID {
	var id uuid.UUID
	if a.db.QueryRow(ctx, `select id from agent where tenant_id=$1 and email='integration@tongyu.local' limit 1`, tenantID).Scan(&id) == nil {
		return &id
	}
	inserted := uuid.New()
	// DISABLED keeps the row out of every roster, assignment query and login
	// path: it exists to own messages, not to receive work. The statement returns
	// the surviving row so a concurrent first request still gets a real id
	// instead of the losing insert's id.
	err := a.db.QueryRow(ctx, `
		insert into agent(id, tenant_id, email, display_name, password_hash, role, status, max_concurrent)
		values($1,$2,'integration@tongyu.local','系统集成','!disabled','AGENT','DISABLED',0)
		on conflict do nothing
		returning id`, inserted).Scan(&id)
	if err != nil {
		if a.db.QueryRow(ctx, `select id from agent where tenant_id=$1 and email='integration@tongyu.local'`, tenantID).Scan(&id) != nil {
			return nil
		}
	}
	return &id
}

// botAgentID returns the system agent that speaks for the bot inside a tenant.
func (a *API) botAgentID(ctx context.Context, tenantID uuid.UUID) *uuid.UUID {
	var id uuid.UUID
	err := a.db.QueryRow(ctx, `select id from agent where tenant_id=$1 and email='bot@tongyu.local' limit 1`, tenantID).Scan(&id)
	if err == nil {
		return &id
	}
	inserted := uuid.New()
	_, err = a.db.Exec(ctx, `insert into agent(id, tenant_id, email, display_name, password_hash, role, status, max_concurrent)
		values($1,$2,'bot@tongyu.local','AI 助手','!disabled', 'AGENT','DISABLED',0)
		on conflict do nothing`, inserted)
	if err != nil {
		return nil
	}
	return &inserted
}

func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
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

func truncateRunes(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit]) + "…"
}

// 非文本消息也应给收件箱提供可辨认的摘要，避免附件被显示为“暂无消息”。
func messagePreview(kind, content string, metadata map[string]any) string {
	if value := trimPreview(content); value != "" {
		return value
	}
	labels := map[string]string{"IMAGE": "[图片]", "FILE": "[文件]", "AUDIO": "[语音]", "VIDEO": "[视频]", "LOCATION": "[位置]", "CARD": "[卡片]"}
	label := labels[kind]
	if kind == "FILE" {
		if name, ok := metadata["name"].(string); ok && name != "" {
			return trimPreview(label + " " + name)
		}
	}
	return label
}
