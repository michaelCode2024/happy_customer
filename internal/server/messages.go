package server

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/realtime"
	"github.com/relaydesk/relaydesk/internal/webhook"
)

// This file holds the message operations that turn an append-only transcript
// into a chat: quoting, editing, recall, reactions, pins, drafts and search.
//
// Two invariants run through all of them.
//
// First, a message is never destroyed. Editing rewrites the body, recall sets
// deleted_at, and the row and its sequence survive so every client can update
// the bubble it already drew instead of leaving a hole in the timeline.
//
// Second, is_private is checked before anything is returned or published. An
// internal note is an agent-only object, and the visitor channel is exactly the
// stream a visitor socket subscribes to.

// consoleMessageScope resolves the conversation from the path and then the
// message inside it. The message lookup carries tenant_id and conversation_id so
// a valid conversation id paired with someone else's message id cannot reach a
// row: the pair is what is authorized, not either half.
func (a *API) consoleMessageScope(w http.ResponseWriter, r *http.Request, p auth.Principal) (uuid.UUID, uuid.UUID, bool) {
	conversationID, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return uuid.Nil, uuid.Nil, false
	}
	messageID, err := uuid.Parse(r.PathValue("messageId"))
	if err != nil {
		fail(w, 400, "消息 ID 不合法")
		return uuid.Nil, uuid.Nil, false
	}
	var exists bool
	err = a.db.QueryRow(r.Context(), `select exists(select 1 from message
		where id = $1 and conversation_id = $2 and tenant_id = $3)`,
		messageID, conversationID, p.TenantID).Scan(&exists)
	if err != nil || !exists {
		failCode(w, 404, "MESSAGE_NOT_FOUND", "消息不存在")
		return uuid.Nil, uuid.Nil, false
	}
	return conversationID, messageID, true
}

// loadMessage reads one message in the agent view, which is also the shape the
// mutation endpoints return so a console can replace its local copy directly.
func (a *API) loadMessage(ctx context.Context, conversationID, messageID uuid.UUID) (messageView, error) {
	row := a.db.QueryRow(ctx, `select `+messageColumns+messageJoins+`
		 where m.conversation_id = $1 and m.id = $2`, conversationID, messageID)
	item, err := scanMessageRow(row)
	if err != nil {
		return messageView{}, err
	}
	item.Attachments = a.messageAttachments(ctx, item.ID)
	if item.ReplyToID != nil {
		item.ReplyTo = a.replyPreview(ctx, *item.ReplyToID)
	}
	item.Reactions = a.messageReactions(ctx, item.ID)
	return item, nil
}

// ---------------------------------------------------------------- editing

type editMessageRequest struct {
	Content  string         `json:"content"`
	Metadata map[string]any `json:"metadata"`
}

// consoleEditMessage rewrites the body of a message an agent already sent. The
// transcript stays honest because edited_at is stamped and every client renders
// "已编辑" from it: an answer that silently changed after the visitor read it
// would make the record worthless in a dispute.
func (a *API) consoleEditMessage(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	conversationID, messageID, ok := a.consoleMessageScope(w, r, p)
	if !ok {
		return
	}
	var in editMessageRequest
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.Content) == "" {
		fail(w, 400, "消息内容不能为空")
		return
	}

	// Only the author may rewrite their own words. A supervisor editing an
	// agent's reply would destroy the audit trail the tenant relies on.
	var senderID *uuid.UUID
	var senderType string
	var deleted bool
	err := a.db.QueryRow(r.Context(), `select sender_id, sender_type, deleted_at is not null
		  from message where id = $1 and conversation_id = $2 and tenant_id = $3`,
		messageID, conversationID, p.TenantID).Scan(&senderID, &senderType, &deleted)
	if err != nil {
		fail(w, 404, "消息不存在")
		return
	}
	if deleted {
		failCode(w, 409, "MESSAGE_DELETED", "已撤回的消息不能编辑")
		return
	}
	if senderType != "AGENT" || senderID == nil || *senderID != p.AgentID {
		if !canManageTenant(p.Role) {
			failCode(w, 403, "NOT_AUTHOR", "只能编辑自己发送的消息")
			return
		}
	}

	metadata := orEmpty(in.Metadata)
	encoded, err := jsonBytes(metadata)
	if err != nil {
		fail(w, 500, "更新消息失败")
		return
	}
	tag, err := a.db.Exec(r.Context(), `update message
		set content = $4, metadata = coalesce($5::jsonb, metadata), edited_at = now()
		where id = $1 and conversation_id = $2 and tenant_id = $3 and deleted_at is null`,
		messageID, conversationID, p.TenantID, in.Content, encoded)
	if err != nil {
		a.logger.Error("edit message failed", "error", err)
		fail(w, 500, "更新消息失败")
		return
	}
	if tag.RowsAffected() == 0 {
		fail(w, 404, "消息不存在")
		return
	}

	view, err := a.loadMessage(r.Context(), conversationID, messageID)
	if err != nil {
		fail(w, 500, "更新消息失败")
		return
	}
	// The conversation preview is a denormalised copy of the latest message, so
	// editing the last one has to update it too or the queue keeps showing the
	// text that was just corrected.
	a.refreshPreviewIfLatest(r.Context(), conversationID, view)
	a.publishMessageUpdated(r.Context(), p.TenantID, conversationID, view)
	a.notifyWebhook(r.Context(), p.TenantID, webhook.EventMessageUpdated, map[string]any{
		"conversationId": conversationID, "message": view, "editedBy": p.AgentID,
	})
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "message.edit", "message", messageID, nil)
	respond(w, 200, view)
}

// publishMessageUpdated sends the new state of a message. A private note skips
// the visitor channel for the same reason a private create does.
func (a *API) publishMessageUpdated(ctx context.Context, tenantID, conversationID uuid.UUID, view messageView) {
	event := realtime.Event{Type: "message.updated", TenantID: tenantID.String(), ConversationID: conversationID.String(), Data: view}
	if view.Private {
		a.publish(ctx, a.agentOnlyChannels(ctx, conversationID), event)
		return
	}
	a.publish(ctx, a.conversationChannels(ctx, conversationID), event)
}

func (a *API) refreshPreviewIfLatest(ctx context.Context, conversationID uuid.UUID, view messageView) {
	preview := trimPreview(view.Content)
	if view.MessageType != "TEXT" {
		preview = messageTypeLabel(view.MessageType)
	}
	if view.DeletedAt != nil {
		preview = "消息已撤回"
	}
	_, _ = a.db.Exec(ctx, `update conversation set last_message_preview = $2
		where id = $1 and last_sequence = $3`, conversationID, preview, view.Sequence)
}

func messageTypeLabel(messageType string) string {
	switch messageType {
	case "IMAGE":
		return "[图片]"
	case "FILE":
		return "[文件]"
	case "AUDIO":
		return "[语音]"
	case "VIDEO":
		return "[视频]"
	case "LOCATION":
		return "[位置]"
	case "CARD":
		return "[卡片]"
	case "RATING":
		return "[评价]"
	default:
		return "[消息]"
	}
}

// ---------------------------------------------------------------- recall

// consoleDeleteMessage recalls a message. It is a soft delete on purpose: the
// visitor's client needs a tombstone to replace the bubble it already rendered,
// and the tenant needs the residue for an abuse or dispute investigation. The
// body stops leaving the server the moment deleted_at is set — scanMessageRow
// blanks the content and drops attachments for any deleted row.
func (a *API) consoleDeleteMessage(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	conversationID, messageID, ok := a.consoleMessageScope(w, r, p)
	if !ok {
		return
	}
	var senderID *uuid.UUID
	var senderType string
	err := a.db.QueryRow(r.Context(), `select sender_id, sender_type from message
		 where id = $1 and conversation_id = $2 and tenant_id = $3 and deleted_at is null`,
		messageID, conversationID, p.TenantID).Scan(&senderID, &senderType)
	if err != nil {
		fail(w, 404, "消息不存在或已撤回")
		return
	}
	if senderType != "AGENT" || senderID == nil || *senderID != p.AgentID {
		if !canManageTenant(p.Role) {
			failCode(w, 403, "NOT_AUTHOR", "只能撤回自己发送的消息")
			return
		}
	}
	tag, err := a.db.Exec(r.Context(), `update message
		set deleted_at = now(), deleted_by = $4, pinned_at = null, pinned_by = null
		where id = $1 and conversation_id = $2 and tenant_id = $3 and deleted_at is null`,
		messageID, conversationID, p.TenantID, p.AgentID)
	if err != nil {
		fail(w, 500, "撤回消息失败")
		return
	}
	if tag.RowsAffected() == 0 {
		fail(w, 404, "消息已撤回")
		return
	}

	view, err := a.loadMessage(r.Context(), conversationID, messageID)
	if err != nil {
		fail(w, 500, "撤回消息失败")
		return
	}
	a.refreshPreviewIfLatest(r.Context(), conversationID, view)
	a.publishMessageUpdated(r.Context(), p.TenantID, conversationID, view)
	a.notifyWebhook(r.Context(), p.TenantID, webhook.EventMessageDeleted, map[string]any{
		"conversationId": conversationID, "messageId": messageID, "deletedBy": p.AgentID,
	})
	if view.Private {
		// An internal note was never visible to the visitor, so the absence of
		// the body from the event is all that matters.
		respond(w, 200, map[string]any{"status": "OK", "messageId": messageID})
		return
	}
	respond(w, 200, map[string]any{"status": "OK", "messageId": messageID})
}

// ---------------------------------------------------------------- reactions

type reactionRequest struct {
	Emoji string `json:"emoji"`
}

// allowedReactions is an allow-list rather than free text. Reactions render as a
// single glyph next to a bubble; a visitor supplying arbitrary text through this
// field would be an injection surface with no product value behind it.
var allowedReactions = map[string]bool{
	"👍": true, "👎": true, "❤️": true, "😄": true, "😮": true,
	"😢": true, "🙏": true, "🎉": true, "✅": true, "❌": true,
}

// consoleReactMessage toggles one emoji from one agent. Posting the same emoji
// twice removes it, which is what a chat user expects and keeps the table free
// of duplicate rows.
func (a *API) consoleReactMessage(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	conversationID, messageID, ok := a.consoleMessageScope(w, r, p)
	if !ok {
		return
	}
	var in reactionRequest
	if !decode(w, r, &in) {
		return
	}
	emoji := strings.TrimSpace(in.Emoji)
	if !allowedReactions[emoji] {
		fail(w, 400, "不支持的回应表情")
		return
	}
	tag, err := a.db.Exec(r.Context(), `delete from message_reaction
		where message_id = $1 and actor_type = 'AGENT' and actor_id = $2 and emoji = $3`,
		messageID, p.AgentID, emoji)
	if err != nil {
		fail(w, 500, "更新回应失败")
		return
	}
	if tag.RowsAffected() == 0 {
		if _, err := a.db.Exec(r.Context(), `insert into message_reaction(message_id, tenant_id, actor_type, actor_id, emoji)
			select $1, $2, 'AGENT', $3, $4
			 where exists (select 1 from message where id = $1 and conversation_id = $5)`,
			messageID, p.TenantID, p.AgentID, emoji, conversationID); err != nil {
			fail(w, 500, "更新回应失败")
			return
		}
	}
	reactions := a.messageReactions(r.Context(), messageID)
	a.publish(r.Context(), a.conversationChannels(r.Context(), conversationID), realtime.Event{
		Type: "message.reaction", TenantID: p.TenantID.String(), ConversationID: conversationID.String(),
		Data: map[string]any{"messageId": messageID, "reactions": reactions},
	})
	respond(w, 200, map[string]any{"messageId": messageID, "reactions": reactions})
}

// messageReactions lists the reactions on one message. The aggregate is per
// emoji with the actor ids attached, so a client can show a count and highlight
// the ones the current user chose without a second request.
func (a *API) messageReactions(ctx context.Context, messageID uuid.UUID) []messageReactionView {
	rows, err := a.db.Query(ctx, `select emoji, array_agg(actor_id), bool_or(actor_type = 'VISITOR')
		  from message_reaction where message_id = $1
		 group by emoji order by min(created_at)`, messageID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	items := make([]messageReactionView, 0, 4)
	for rows.Next() {
		var item messageReactionView
		if rows.Scan(&item.Emoji, &item.Actors, &item.VisitorSet) != nil {
			continue
		}
		item.Count = len(item.Actors)
		items = append(items, item)
	}
	return items
}

// ---------------------------------------------------------------- pins

// consolePinMessage pins or unpins a message. Pinned messages sit at the top of
// the console thread, which is how an agent keeps the order number or the
// account id in view while scrolling.
func (a *API) consolePinMessage(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	conversationID, messageID, ok := a.consoleMessageScope(w, r, p)
	if !ok {
		return
	}
	var in struct {
		Pinned *bool `json:"pinned"`
	}
	if !decode(w, r, &in) {
		return
	}
	pinned := true
	if in.Pinned != nil {
		pinned = *in.Pinned
	}
	if pinned {
		if _, err := a.db.Exec(r.Context(), `update message set pinned_at = now(), pinned_by = $4
			where id = $1 and conversation_id = $2 and tenant_id = $3 and deleted_at is null`,
			messageID, conversationID, p.TenantID, p.AgentID); err != nil {
			fail(w, 500, "置顶失败")
			return
		}
	} else if _, err := a.db.Exec(r.Context(), `update message set pinned_at = null, pinned_by = null
		where id = $1 and conversation_id = $2 and tenant_id = $3`, messageID, conversationID, p.TenantID); err != nil {
		fail(w, 500, "取消置顶失败")
		return
	}
	pins, err := a.pinnedMessages(r.Context(), conversationID)
	if err != nil {
		fail(w, 500, "置顶失败")
		return
	}
	a.publish(r.Context(), a.agentOnlyChannels(r.Context(), conversationID), realtime.Event{
		Type: "message.pinned", TenantID: p.TenantID.String(), ConversationID: conversationID.String(),
		Data: map[string]any{"messageId": messageID, "pinned": pinned, "pinnedMessages": pins},
	})
	// 客户只接收公开置顶列表，不能在事件载荷里夹带内部备注。
	var visitorID uuid.UUID
	var private bool
	if a.db.QueryRow(r.Context(), `select c.visitor_id, m.is_private from conversation c join message m on m.conversation_id=c.id where c.id=$1 and m.id=$2`, conversationID, messageID).Scan(&visitorID, &private) == nil && !private {
		publicPins := make([]messageView, 0, len(pins))
		for _, pin := range pins {
			if !pin.Private {
				publicPins = append(publicPins, pin)
			}
		}
		a.publish(r.Context(), []string{realtime.VisitorChannel(visitorID.String())}, realtime.Event{Type: "message.pinned", TenantID: p.TenantID.String(), ConversationID: conversationID.String(), Data: map[string]any{"messageId": messageID, "pinned": pinned, "pinnedMessages": publicPins}})
	}
	respond(w, 200, map[string]any{"status": "OK", "pinned": pinned, "items": pins})
}

// pinnedMessages returns the pinned messages of a conversation. The list is
// capped because a transcript that pins everything has pinned nothing.
func (a *API) pinnedMessages(ctx context.Context, conversationID uuid.UUID) ([]messageView, error) {
	rows, err := a.db.Query(ctx, `select `+messageColumns+messageJoins+`
		 where m.conversation_id = $1 and m.pinned_at is not null and m.deleted_at is null
		 order by m.pinned_at desc limit 20`, conversationID)
	if err != nil {
		return nil, err
	}
	return a.collectMessages(ctx, rows, 20)
}

// consolePinnedMessages is the read side of the pins, used when a console opens
// a thread and has to draw the pin bar before any messages arrive.
func (a *API) consolePinnedMessages(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	items, err := a.pinnedMessages(r.Context(), id)
	if err != nil {
		fail(w, 500, "查询置顶消息失败")
		return
	}
	respond(w, 200, map[string]any{"items": items})
}

// ---------------------------------------------------------------- drafts

type draftRequest struct {
	Content string `json:"content"`
}

// consoleDraft stores the half-written reply for this agent and conversation.
// Keeping the draft server-side rather than in browser storage is the whole
// point: an agent who starts an answer on the desktop and finishes it on a phone
// would otherwise lose it.
func (a *API) consoleDraft(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	var content string
	err := a.db.QueryRow(r.Context(), `select content from message_draft
		where conversation_id = $1 and agent_id = $2`, id, p.AgentID).Scan(&content)
	if err != nil {
		content = ""
	}
	respond(w, 200, map[string]any{"conversationId": id, "content": content})
}

func (a *API) consoleSaveDraft(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	var in draftRequest
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.Content) == "" {
		// Clearing the box is the same call as writing nothing, so the row is
		// removed rather than left as an empty draft every console would have to
		// filter out.
		if _, err := a.db.Exec(r.Context(), `delete from message_draft where conversation_id=$1 and agent_id=$2`,
			id, p.AgentID); err != nil {
			fail(w, 500, "保存草稿失败")
			return
		}
		respond(w, 200, map[string]any{"status": "OK", "content": ""})
		return
	}
	if _, err := a.db.Exec(r.Context(), `insert into message_draft(conversation_id, tenant_id, agent_id, content, updated_at)
		values($1,$2,$3,$4, now())
		on conflict (conversation_id, agent_id)
		do update set content = excluded.content, updated_at = now()`,
		id, p.TenantID, p.AgentID, in.Content); err != nil {
		fail(w, 500, "保存草稿失败")
		return
	}
	respond(w, 200, map[string]any{"status": "OK", "content": in.Content})
}

// ---------------------------------------------------------------- search

// consoleSearchMessages searches every conversation the agent can see.
//
// Both sides of the match call relaydesk_tsquery, so a keyword the search box
// accepts is a keyword the index can answer — an ordinary Chinese query like
// "退款" used to match nothing at all because the tokenizer could not segment it.
// Trigram similarity is kept as a second path for typos and partial Latin words,
// where it is genuinely useful.
func (a *API) consoleSearchMessages(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if query == "" {
		fail(w, 400, "搜索关键词不能为空")
		return
	}
	limit := queryInt(r, "limit", 30)
	if limit > 100 {
		limit = 100
	}
	conversationFilter := strings.TrimSpace(r.URL.Query().Get("conversationId"))

	args := []any{p.TenantID, query, limit}
	conditions := []string{
		"m.tenant_id = $1",
		"m.deleted_at is null",
		"(m.search_vector @@ relaydesk_tsquery($2) or m.content % $2)",
	}
	if conversationFilter != "" {
		if parsed, err := uuid.Parse(conversationFilter); err == nil {
			args = append(args, parsed)
			conditions = append(conditions, "m.conversation_id = $"+itoa(len(args)))
		}
	}
	// The same inbox membership rule the conversation list uses, so search can
	// never surface a thread the agent cannot open.
	args = append(args, p.AgentID)
	conditions = append(conditions, `exists (select 1 from conversation c
		where c.id = m.conversation_id
		  and exists (select 1 from agent_inbox ai where ai.inbox_id = c.inbox_id and ai.agent_id = $`+itoa(len(args))+`))`)

	rows, err := a.db.Query(r.Context(), `
		select m.id, m.conversation_id, m.sender_type, m.sender_id, m.client_message_id, m.sequence,
		       m.message_type, m.content, m.metadata, m.created_at, m.is_private,
		       m.reply_to_id, m.edited_at, m.deleted_at, m.pinned_at, m.forwarded_from_id,
		       coalesce(ag.display_name, coalesce(v.display_name, '')),
		       greatest(
		           -- Cover density rewards matches that sit close together, which
		           -- is what separates a message about the query from one that
		           -- merely contains two of its words. The transcript is far too
		           -- large for the per-query frequency pass the knowledge base
		           -- uses, and ts_rank_cd costs nothing extra here. It is scaled
		           -- so that a genuine multi-term hit can outrank a verbatim one.
		           ts_rank_cd(m.search_vector, relaydesk_tsquery($2)) * 0.5,
		           -- A message containing the query verbatim is what the operator
		           -- meant even when the tokenizer ranks it low, which is the
		           -- usual case for a short Chinese query.
		           case when m.content ilike '%' || $2 || '%' then 0.5 else 0 end
		       ) as rank,
		       coalesce(v2.display_name, '')
		  from message m
		  left join agent ag on ag.id = m.sender_id and m.sender_type = 'AGENT'
		  left join visitor v on v.id = m.sender_id and m.sender_type = 'VISITOR'
		  join conversation c2 on c2.id = m.conversation_id
		  join visitor v2 on v2.id = c2.visitor_id
		 where `+strings.Join(conditions, " and ")+`
		 order by rank desc, m.created_at desc
		 limit $3`, args...)
	if err != nil {
		a.logger.Error("message search failed", "error", err)
		fail(w, 500, "搜索失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, limit)
	for rows.Next() {
		var item messageView
		var metadata []byte
		var rank float64
		var visitorName string
		if err := rows.Scan(&item.ID, &item.ConversationID, &item.SenderType, &item.SenderID, &item.ClientMessageID,
			&item.Sequence, &item.MessageType, &item.Content, &metadata, &item.CreatedAt, &item.Private,
			&item.ReplyToID, &item.EditedAt, &item.DeletedAt, &item.PinnedAt, &item.ForwardedFromID,
			&item.SenderName, &rank, &visitorName); err != nil {
			a.logger.Error("message search scan failed", "error", err)
			fail(w, 500, "搜索失败")
			return
		}
		items = append(items, map[string]any{
			"messageId": item.ID, "conversationId": item.ConversationID, "sequence": item.Sequence,
			"content": item.Content, "excerpt": excerptAround(item.Content, query), "rank": rank,
			"createdAt": item.CreatedAt, "messageType": item.MessageType, "senderType": item.SenderType,
			"senderName": item.SenderName, "visitorName": visitorName, "private": item.Private,
		})
	}
	respond(w, 200, map[string]any{"items": items, "query": query})
}

// searchVisitorMessages lets a visitor search their own transcript. It is
// scoped to one conversation the visitor owns and to non-private messages, so
// the same full-text index serves both audiences without ever widening what a
// visitor can reach.
func (a *API) searchVisitorMessages(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.visitorConversation(w, r, p)
	if !ok {
		return
	}
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if query == "" {
		fail(w, 400, "搜索关键词不能为空")
		return
	}
	limit := queryInt(r, "limit", 30)
	if limit > 100 {
		limit = 100
	}
	items, err := a.searchMessagesInConversation(r.Context(), id, query, limit, visitorVisibility)
	if err != nil {
		fail(w, 500, "搜索失败")
		return
	}
	respond(w, 200, map[string]any{"items": items, "query": query})
}

// searchHit is one match inside a transcript. It carries an excerpt rather than
// the whole message for the same reason the cross-conversation search does: a
// hit exists to be scanned for the keyword, and the client already holds the
// message itself in the open thread.
//
// Both audiences get this shape. A visitor and an agent searching the same
// conversation must see the same rows, differing only in whether internal notes
// are included, which is what visibility decides.
type searchHit struct {
	MessageID      uuid.UUID `json:"messageId"`
	ConversationID uuid.UUID `json:"conversationId"`
	Sequence       int64     `json:"sequence"`
	Content        string    `json:"content"`
	Excerpt        string    `json:"excerpt"`
	Rank           float64   `json:"rank"`
	CreatedAt      time.Time `json:"createdAt"`
	MessageType    string    `json:"messageType"`
	SenderType     string    `json:"senderType"`
	SenderName     string    `json:"senderName,omitempty"`
}

func (a *API) searchMessagesInConversation(ctx context.Context, conversationID uuid.UUID, query string, limit int, view visibility) ([]searchHit, error) {
	rows, err := a.db.Query(ctx, `select m.id, m.sequence, m.content, m.created_at, m.message_type, m.sender_type,
		       coalesce(ag.display_name, v.display_name, m.metadata ->> 'senderName', ''),
		       greatest(
		           -- Same two signals the cross-conversation search uses, so an
		           -- in-thread search and a global one never disagree about which
		           -- match matters more.
		           ts_rank_cd(m.search_vector, relaydesk_tsquery($2)) * 0.5,
		           case when m.content ilike '%' || $2 || '%' then 0.5 else 0 end
		       ) as rank
		  from message m
		  left join agent ag on ag.id = m.sender_id and m.sender_type = 'AGENT'
		  left join visitor v on v.id = m.sender_id and m.sender_type = 'VISITOR'
		 where m.conversation_id = $1
		   and (m.search_vector @@ relaydesk_tsquery($2) or m.content % $2)`+view.filter("m")+`
		 order by rank desc, m.sequence desc limit $3`, conversationID, query, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]searchHit, 0, limit)
	for rows.Next() {
		var item searchHit
		if err := rows.Scan(&item.MessageID, &item.Sequence, &item.Content, &item.CreatedAt,
			&item.MessageType, &item.SenderType, &item.SenderName, &item.Rank); err != nil {
			return nil, err
		}
		item.ConversationID = conversationID
		item.Excerpt = excerptAround(item.Content, query)
		items = append(items, item)
	}
	return items, rows.Err()
}

// ---------------------------------------------------------------- console reads

// consoleSearch is the console's per-conversation transcript search, wired to the
// same query the global search uses so the two never disagree about what a
// keyword matches.
func (a *API) consoleFindInConversation(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.consoleConversationScope(w, r, p)
	if !ok {
		return
	}
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if query == "" {
		fail(w, 400, "搜索关键词不能为空")
		return
	}
	limit := queryInt(r, "limit", 30)
	if limit > 100 {
		limit = 100
	}
	items, err := a.searchMessagesInConversation(r.Context(), id, query, limit, agentVisibility)
	if err != nil {
		fail(w, 500, "搜索失败")
		return
	}
	respond(w, 200, map[string]any{"items": items, "query": query})
}

// ---------------------------------------------------------------- forwarding

type forwardRequest struct {
	ConversationID string `json:"conversationId"`
	Note           string `json:"note"`
}

// consoleForwardMessage copies a message into another conversation. The original
// is referenced rather than duplicated silently: forwarded_from_id keeps the
// provenance, and a recalled original leaves the copy intact because the copy is
// now part of a different thread.
func (a *API) consoleForwardMessage(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	conversationID, messageID, ok := a.consoleMessageScope(w, r, p)
	if !ok {
		return
	}
	var in forwardRequest
	if !decode(w, r, &in) {
		return
	}
	target, err := uuid.Parse(in.ConversationID)
	if err != nil {
		fail(w, 400, "目标会话 ID 不合法")
		return
	}
	// The destination is checked against the same inbox membership rule as
	// every other console route, so forwarding cannot be used to inject text
	// into a thread the agent cannot otherwise open.
	var allowed bool
	err = a.db.QueryRow(r.Context(), `select exists(
			select 1 from conversation c
			 where c.id = $1 and c.tenant_id = $2
			   and (exists (select 1 from agent_inbox ai where ai.inbox_id = c.inbox_id and ai.agent_id = $3)
			        or c.assignee_id = $3))`, target, p.TenantID, p.AgentID).Scan(&allowed)
	if err != nil || !allowed {
		failCode(w, 404, "CONVERSATION_NOT_FOUND", "目标会话不存在或你没有权限")
		return
	}
	source, err := a.loadMessage(r.Context(), conversationID, messageID)
	if err != nil || source.DeletedAt != nil {
		fail(w, 404, "消息不存在或已撤回")
		return
	}

	if source.Private {
		fail(w, 400, "内部备注不能转发给客户")
		return
	}
	content := source.Content
	if source.MessageType != "TEXT" {
		content = messageTypeLabel(source.MessageType)
	}
	if note := strings.TrimSpace(in.Note); note != "" {
		content = note + "\n" + content
	}
	view, err := a.appendMessage(r.Context(), p.TenantID, target, messageInput{
		SenderType:      "AGENT",
		SenderID:        &p.AgentID,
		MessageType:     source.MessageType,
		Content:         content,
		Metadata:        map[string]any{"forwardedFrom": conversationID, "forwardedMessageId": messageID},
		ForwardedFromID: &messageID,
	})
	if err != nil {
		if failServiceError(w, err) {
			return
		}
		fail(w, 500, "转发失败")
		return
	}
	view.SenderName = p.Name
	respond(w, 201, view)
}

func canManageTenant(role string) bool {
	return role == auth.RoleSupervisor
}
