package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/realtime"
)

type handlerContext = context.Context

type inboxContext struct {
	ID              uuid.UUID
	TenantID        uuid.UUID
	Name            string
	WelcomeMessage  *string
	OfflineMessage  *string
	PublicKey       string
	AIEnabled       bool
	AIHandoff       string
	WorkingHours    map[string]any
	AgentsAvailable int
	// White-label branding delivered to the visitor widget on bootstrap.
	LogoURL     *string
	AvatarURL   *string
	FontFamily  *string
	BubbleRadius *int
	CustomCSS   *string
}

func (a *API) loadInbox(ctx handlerContext, publicKey string) (inboxContext, error) {
	var inbox inboxContext
	err := a.db.QueryRow(ctx, `
		select i.id, i.tenant_id, i.name, i.welcome_message, i.offline_message, i.public_key,
		       coalesce(s.enabled, false), coalesce(s.handoff_message, '正在为你转接人工客服，请稍候。'),
		       coalesce(r.working_hours, '{}'::jsonb),
		       (select count(*)::int from agent_presence ap
		          join agent ag on ag.id = ap.agent_id
		          join agent_inbox ai on ai.agent_id = ag.id
		         where ai.inbox_id = i.id and ap.status = 'ONLINE' and ag.status = 'ACTIVE'),
		       i.logo_url, i.avatar_url, i.font_family, i.bubble_radius, i.custom_css
		  from inbox i
		  left join ai_setting s on s.inbox_id = i.id
		  left join lateral (
		      select working_hours from routing_rule rr where rr.inbox_id = i.id and rr.enabled limit 1
		  ) r on true
		 where i.public_key = $1 and i.status = 'ACTIVE'`, publicKey).
		Scan(&inbox.ID, &inbox.TenantID, &inbox.Name, &inbox.WelcomeMessage, &inbox.OfflineMessage,
			&inbox.PublicKey, &inbox.AIEnabled, &inbox.AIHandoff, &inbox.WorkingHours, &inbox.AgentsAvailable,
			&inbox.LogoURL, &inbox.AvatarURL, &inbox.FontFamily, &inbox.BubbleRadius, &inbox.CustomCSS)
	if errors.Is(err, pgx.ErrNoRows) {
		return inbox, errors.New("客服入口不存在或已停用")
	}
	if err != nil {
		return inbox, err
	}
	if !a.tenantActive(ctx, inbox.TenantID) {
		return inbox, errors.New("该企业账号已停用")
	}
	return inbox, nil
}

func (a *API) touchVisitor(ctx handlerContext, visitorID uuid.UUID) {
	_, _ = a.db.Exec(ctx, `update visitor set last_seen_at = now() where id = $1`, visitorID)
}

func (a *API) publish(ctx handlerContext, channels []string, event realtime.Event) {
	a.bus.Publish(ctx, channels, event)
}

func (a *API) notifyWebhook(ctx handlerContext, tenantID uuid.UUID, eventType string, payload any) {
	if a.webhooks == nil || !a.tenantHasFeature(ctx, tenantID, "integrations") {
		return
	}
	if err := a.webhooks.Enqueue(ctx, tenantID, eventType, payload); err != nil {
		a.logger.Warn("webhook enqueue failed", "error", err, "event", eventType)
	}
}

func (a *API) recordAudit(ctx handlerContext, tenantID uuid.UUID, actorType string, actorID uuid.UUID, action, targetType string, targetID uuid.UUID, detail map[string]any) {
	if detail == nil {
		detail = map[string]any{}
	}
	payload, err := json.Marshal(detail)
	if err != nil {
		payload = []byte("{}")
	}
	_, _ = a.db.Exec(ctx, `insert into audit_log(id, tenant_id, actor_type, actor_id, action, target_type, target_id, detail)
		values($1,$2,$3,$4,$5,$6,$7,$8)`, uuid.New(), tenantID, actorType, nullableUUID(actorID), action, targetType, nullableUUID(targetID), payload)
}

// conversationChannels lists every realtime channel that must receive events for
// a conversation. Queue updates go to inbox: (agents already subscribe per inbox)
// rather than tenant-wide fan-out, so one busy inbox does not wake every seat.
func (a *API) conversationChannels(ctx handlerContext, conversationID uuid.UUID) []string {
	channels := []string{realtime.ConversationChannel(conversationID.String())}
	var visitorID, inboxID uuid.UUID
	var assignee *uuid.UUID
	if a.db.QueryRow(ctx, `select visitor_id, inbox_id, assignee_id from conversation where id=$1`, conversationID).
		Scan(&visitorID, &inboxID, &assignee) == nil {
		channels = append(channels,
			realtime.VisitorChannel(visitorID.String()),
			realtime.InboxChannel(inboxID.String()),
		)
		if assignee != nil {
			channels = append(channels, realtime.AgentChannel(assignee.String()))
		}
	}
	return channels
}

// agentOnlyChannels 只使用坐席与入口频道。会话频道也被访客订阅，不能承载内部备注。
func (a *API) agentOnlyChannels(ctx handlerContext, conversationID uuid.UUID) []string {
	channels := []string{}
	var inboxID uuid.UUID
	var assignee *uuid.UUID
	if a.db.QueryRow(ctx, `select inbox_id, assignee_id from conversation where id=$1`, conversationID).
		Scan(&inboxID, &assignee) == nil {
		channels = append(channels, realtime.InboxChannel(inboxID.String()))
		if assignee != nil {
			channels = append(channels, realtime.AgentChannel(assignee.String()))
		}
	}
	// Every agent who has ever written in this conversation keeps receiving
	// notes, because a colleague discussing a case with the visitor is a
	// participant even before they own the thread.
	rows, err := a.db.Query(ctx, `select distinct sender_id from message
		where conversation_id = $1 and sender_type = 'AGENT' and sender_id is not null`, conversationID)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var agentID uuid.UUID
			if rows.Scan(&agentID) == nil {
				channels = append(channels, realtime.AgentChannel(agentID.String()))
			}
		}
	}
	return channels
}

func (a *API) tenantActive(ctx handlerContext, tenantID uuid.UUID) bool {
	var status string
	if a.db.QueryRow(ctx, `select status from tenant where id=$1`, tenantID).Scan(&status) != nil {
		return false
	}
	return status == "ACTIVE"
}

func trimPreview(content string) string {
	content = strings.TrimSpace(strings.ReplaceAll(content, "\n", " "))
	runes := []rune(content)
	if len(runes) > 80 {
		return string(runes[:80]) + "…"
	}
	return content
}

func nullableUUID(id uuid.UUID) any {
	if id == uuid.Nil {
		return nil
	}
	return id
}

func nowUTC() time.Time { return time.Now().UTC() }

func jsonBytes(value any) ([]byte, error) { return json.Marshal(value) }

func decodeJSONBytes(payload []byte, target any) error { return json.Unmarshal(payload, target) }

func (a *API) assetsChanged(r *http.Request, p auth.Principal) {
	if a.bus != nil {
		a.publish(r.Context(), []string{realtime.TenantChannel(p.TenantID.String())}, realtime.Event{Type: "support.assets.updated"})
	}
}
