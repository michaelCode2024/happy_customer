package server

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/google/uuid"
	"github.com/tongyu/tongyu/internal/auth"
	"github.com/tongyu/tongyu/internal/realtime"
)

// Ownership is an authorization boundary, independent of UI queue filters.
// Unassigned conversations remain available to members of their reception inbox.
// Former assignees stay on conversation_participant so they can read after a transfer.
func conversationVisibility(alias, agent string, supervisor bool) string {
	if supervisor {
		return agent + "::uuid is not null"
	}
	return "(" + conversationDuty(alias, agent, false) + " or exists (select 1 from conversation_participant scope_cp where scope_cp.conversation_id = " + alias + ".id and scope_cp.agent_id = " + agent + "))"
}

// conversationDuty is the work queue: current assignee, or an unassigned thread in the agent's inbox.
// Read access is wider; unread badges and replies stay on this narrower set.
func conversationDuty(alias, agent string, supervisor bool) string {
	if supervisor {
		return agent + "::uuid is not null"
	}
	return "(" + alias + ".assignee_id = " + agent + " or (" + alias + ".assignee_id is null and exists (select 1 from agent_inbox scope_ai where scope_ai.inbox_id = " + alias + ".inbox_id and scope_ai.agent_id = " + agent + ")))"
}

func (a *API) agentConversationAccess(ctx context.Context, p auth.Principal, id uuid.UUID) bool {
	var allowed bool
	err := a.db.QueryRow(ctx, `select exists(select 1 from conversation c where c.id=$1 and c.tenant_id=$2 and `+conversationVisibility("c", "$3", auth.CanViewReports(p.Role))+`)`, id, p.TenantID, p.AgentID).Scan(&allowed)
	return err == nil && allowed
}

// agentCanHandle is reply, transfer, and resolve. A former assignee can open the thread and cannot act on it.
func (a *API) agentCanHandle(ctx context.Context, p auth.Principal, id uuid.UUID) bool {
	if !a.agentConversationAccess(ctx, p, id) {
		return false
	}
	if auth.CanViewReports(p.Role) {
		return true
	}
	var allowed bool
	err := a.db.QueryRow(ctx, `select exists(select 1 from conversation c where c.id=$1 and c.tenant_id=$2 and `+conversationDuty("c", "$3", false)+`)`, id, p.TenantID, p.AgentID).Scan(&allowed)
	return err == nil && allowed
}

func (a *API) agentCanHandleVisitor(ctx context.Context, p auth.Principal, visitorID uuid.UUID) bool {
	if auth.CanViewReports(p.Role) {
		return true
	}
	var allowed bool
	err := a.db.QueryRow(ctx, `select exists(select 1 from conversation c where c.visitor_id=$1 and c.tenant_id=$2 and `+conversationDuty("c", "$3", false)+`)`, visitorID, p.TenantID, p.AgentID).Scan(&allowed)
	return err == nil && allowed
}

func (a *API) agentVisitorAccess(w http.ResponseWriter, r *http.Request, p auth.Principal, id uuid.UUID) bool {
	var allowed bool
	err := a.db.QueryRow(r.Context(), `select exists(select 1 from conversation c where c.visitor_id=$1 and c.tenant_id=$2 and `+conversationVisibility("c", "$3", auth.CanViewReports(p.Role))+`)`, id, p.TenantID, p.AgentID).Scan(&allowed)
	if err != nil || !allowed {
		failCode(w, 404, "CONVERSATION_NOT_FOUND", "客户不存在或你没有权限")
		return false
	}
	return true
}

// Recheck ownership at delivery time, not just when a socket subscribes.
// 读权限比接待范围宽：转接后的原客服仍能收到消息，用来刷新已经打开的记录。
// alert 只在当前接待人或待接待时为真，坐席端据此决定要不要出声。
func (a *API) filterConsoleEvent(ctx context.Context, p auth.Principal, payload []byte) []byte {
	// Data 保持原始字节。重新按结构体编一遍会把序号等字段转成另一种 JSON 写法。
	var event struct {
		Type           string          `json:"type"`
		TenantID       string          `json:"tenantId,omitempty"`
		ConversationID string          `json:"conversationId,omitempty"`
		Data           json.RawMessage `json:"data,omitempty"`
		Truncated      bool            `json:"truncated,omitempty"`
		Meta           map[string]any  `json:"meta,omitempty"`
	}
	if json.Unmarshal(payload, &event) != nil {
		return nil
	}
	if event.ConversationID == "" {
		return payload
	}
	id, err := uuid.Parse(event.ConversationID)
	if err != nil {
		return nil
	}
	supervisor := auth.CanViewReports(p.Role)
	var assignee *string
	var inboxName string
	var duty bool
	err = a.db.QueryRow(ctx, `select c.assignee_id::text, coalesce(i.name,''), `+conversationDuty("c", "$3", supervisor)+`
		from conversation c
		left join inbox i on i.id = c.inbox_id
		where c.id=$1 and c.tenant_id=$2 and `+conversationVisibility("c", "$3", supervisor),
		id, p.TenantID, p.AgentID).Scan(&assignee, &inboxName, &duty)
	if err != nil {
		return realtime.Encode(realtime.Event{Type: "conversation.scope.changed"})
	}
	if event.Type != "message.created" {
		return payload
	}
	if event.Meta == nil {
		event.Meta = map[string]any{}
	}
	var owner any
	sameOwner := false
	if assignee != nil && *assignee != "" {
		owner = *assignee
		if parsed, parseErr := uuid.Parse(*assignee); parseErr == nil {
			sameOwner = parsed == p.AgentID
		}
	}
	event.Meta["assigneeId"] = owner
	event.Meta["inboxName"] = strings.TrimSpace(inboxName)
	event.Meta["alert"] = duty && (assignee == nil || sameOwner)
	out, err := json.Marshal(event)
	if err != nil {
		return nil
	}
	return out
}
