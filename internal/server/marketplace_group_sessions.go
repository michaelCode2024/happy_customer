package server

import (
	"github.com/google/uuid"
	"github.com/tongyu/tongyu/internal/auth"
	"net/http"
)

func (a *API) marketplaceBuyerGroupSession(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var tenant, inbox, visitor uuid.UUID
	if a.db.QueryRow(r.Context(), `select s.tenant_id,s.inbox_id,v.id from marketplace_shop s join chat_group g on g.inbox_id=s.inbox_id join visitor v on v.inbox_id=s.inbox_id and v.external_id=$2 join chat_group_member m on m.group_id=g.id and m.actor_id=v.id and m.actor_kind='widget' where s.marketplace_id=$1 and g.id::text=$3`, p.MarketplaceID, p.ExternalID, r.PathValue("id")).Scan(&tenant, &inbox, &visitor) != nil || !a.tenantActive(r.Context(), tenant) {
		fail(w, 404, "不是该店铺群成员或群不可用")
		return
	}
	token, err := a.tokens.IssueMarketplaceWidget(p, tenant, inbox, visitor)
	if err != nil {
		fail(w, 500, "签发群身份失败")
		return
	}
	respond(w, 200, map[string]any{"token": token, "groupId": r.PathValue("id"), "visitorId": visitor, "expiresIn": 3600})
}
func (a *API) marketplaceStaffGroupSession(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var mid, inbox, visitor uuid.UUID
	var external string
	if a.db.QueryRow(r.Context(), `select ms.marketplace_id,s.inbox_id,v.id,ms.external_id from marketplace_staff ms join marketplace_shop s on s.marketplace_id=ms.marketplace_id and s.external_id=ms.shop_id join chat_group g on g.inbox_id=s.inbox_id join visitor v on v.inbox_id=s.inbox_id and v.external_id=ms.external_id join chat_group_member m on m.group_id=g.id and m.actor_kind='widget' and m.actor_id=v.id where ms.agent_id=$1 and s.tenant_id=$2 and g.id::text=$3`, p.AgentID, p.TenantID, r.PathValue("id")).Scan(&mid, &inbox, &visitor, &external) != nil {
		fail(w, 404, "店员不是该店铺群成员")
		return
	}
	p.MarketplaceID = mid
	p.ExternalID = external
	token, err := a.tokens.IssueMarketplaceWidget(p, p.TenantID, inbox, visitor)
	if err != nil {
		fail(w, 500, "签发群身份失败")
		return
	}
	respond(w, 200, map[string]any{"token": token, "groupId": r.PathValue("id"), "visitorId": visitor, "expiresIn": 3600})
}
