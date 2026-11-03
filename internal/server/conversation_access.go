package server

import (
	"context"
	"encoding/json"
	"github.com/google/uuid"
	"github.com/tongyu/tongyu/internal/auth"
	"github.com/tongyu/tongyu/internal/realtime"
	"net/http"
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
func (a *API) filterConsoleEvent(ctx context.Context, p auth.Principal, payload []byte) []byte {
	var event realtime.Event
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
	if a.agentConversationAccess(ctx, p, id) {
		return payload
	}
	return realtime.Encode(realtime.Event{Type: "conversation.scope.changed"})
}
