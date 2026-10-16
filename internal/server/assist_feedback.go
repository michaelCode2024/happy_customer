package server

import (
	"net/http"
	"strings"

	"github.com/google/uuid"
	"github.com/tongyu/tongyu/internal/auth"
)

// 只允许生成该草稿的坐席反馈；采纳时间保留第一次，重复点击不会重复计数。
func (a *API) consoleAssistFeedback(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "草稿 ID 不合法")
		return
	}
	var in struct {
		Action string `json:"action"`
	}
	if !decode(w, r, &in) {
		return
	}
	action := strings.ToUpper(strings.TrimSpace(in.Action))
	if action != "ADOPT" && action != "HELPFUL" && action != "NEEDS_WORK" {
		fail(w, 400, "不支持的反馈类型")
		return
	}
	var conversationID uuid.UUID
	err = a.db.QueryRow(r.Context(), `select conversation_id from ai_interaction where id=$1 and tenant_id=$2 and agent_id=$3 and task in ('SUGGEST','POLISH')`, id, p.TenantID, p.AgentID).Scan(&conversationID)
	if err != nil || !a.agentCanSee(r, p, conversationID) {
		fail(w, 404, "草稿不存在或你没有权限")
		return
	}
	_, err = a.db.Exec(r.Context(), `update ai_interaction set
 adopted_at=case when $4='ADOPT' then coalesce(adopted_at,now()) else adopted_at end,
 feedback=case when $4='ADOPT' then feedback else $4 end,
 feedback_at=case when $4='ADOPT' then feedback_at else now() end
 where id=$1 and tenant_id=$2 and agent_id=$3`, id, p.TenantID, p.AgentID, action)
	if err != nil {
		fail(w, 500, "保存反馈失败，请重试")
		return
	}
	respond(w, 200, map[string]any{"status": "OK", "action": action})
}

func (a *API) consoleAssistFeedbackSummary(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	if !auth.CanViewReports(p.Role) {
		fail(w, 403, "无权查看团队反馈")
		return
	}
	var generated, adopted, sent, edited, helpful, needsWork int
	err := a.db.QueryRow(r.Context(), `select count(*),count(adopted_at),count(sent_message_id),
 count(*) filter(where edited_before_send=true),count(*) filter(where feedback='HELPFUL'),count(*) filter(where feedback='NEEDS_WORK')
 from ai_interaction where tenant_id=$1 and task='SUGGEST' and created_at>=now()-interval '30 days'`, p.TenantID).Scan(&generated, &adopted, &sent, &edited, &helpful, &needsWork)
	if err != nil {
		fail(w, 500, "读取反馈统计失败")
		return
	}
	respond(w, 200, map[string]any{"days": 30, "generated": generated, "adopted": adopted, "sent": sent, "edited": edited, "helpful": helpful, "needsWork": needsWork})
}
