package server

import (
	"bytes"
	"encoding/json"
	"github.com/google/uuid"
	"io"
	"net/http"
)

// 商城密钥只经绑定店铺转换为租户权限，不接受客户端传tenantId或inboxKey覆盖。
func (a *API) marketplaceGroupProxy(w http.ResponseWriter, r *http.Request, mid uuid.UUID, action string, next func(http.ResponseWriter, *http.Request, apiKeyPrincipal)) {
	var tenant uuid.UUID
	var inbox, key string
	if a.db.QueryRow(r.Context(), `select s.tenant_id,s.inbox_id::text,i.public_key from marketplace_shop s join inbox i on i.id=s.inbox_id where s.marketplace_id=$1 and s.external_id=$2`, mid, r.PathValue("shopId")).Scan(&tenant, &inbox, &key) != nil || !a.tenantActive(r.Context(), tenant) {
		fail(w, 404, "店铺不存在或不可用")
		return
	}
	if !a.tenantHasFeature(r.Context(), tenant, "groups") {
		fail(w, 403, "店铺套餐未包含群聊")
		return
	}
	var in map[string]any
	if r.Method == "GET" || r.Method == "DELETE" {
		in = map[string]any{}
	} else if !decode(w, r, &in) {
		return
	}
	if action == "create" {
		owner, ok := in["owner"].(map[string]any)
		if !ok {
			fail(w, 400, "需要群主")
			return
		}
		var staff bool
		if a.db.QueryRow(r.Context(), `select exists(select 1 from marketplace_staff s join agent ag on ag.id=s.agent_id where s.marketplace_id=$1 and s.shop_id=$2 and s.external_id=$3 and ag.status='ACTIVE')`, mid, r.PathValue("shopId"), owner["externalId"]).Scan(&staff) != nil || !staff {
			fail(w, 403, "仅本店有效店主或店员可建群")
			return
		}
		in["inboxKey"] = key
	} else if action != "list" {
		var belongs bool
		if a.db.QueryRow(r.Context(), `select exists(select 1 from chat_group where id::text=$1 and tenant_id=$2 and inbox_id::text=$3)`, r.PathValue("id"), tenant, inbox).Scan(&belongs) != nil || !belongs {
			fail(w, 404, "群不属于此店铺")
			return
		}
	}
	actor := in["actorExternalId"]
	if r.Method == "DELETE" {
		actor = r.URL.Query().Get("actorExternalId")
	}
	if actor != nil && actor != "" {
		var disabled bool
		if a.db.QueryRow(r.Context(), `select exists(select 1 from marketplace_staff ms join agent ag on ag.id=ms.agent_id where ms.marketplace_id=$1 and ms.shop_id=$2 and ms.external_id=$3 and ag.status<>'ACTIVE')`, mid, r.PathValue("shopId"), actor).Scan(&disabled) != nil || disabled {
			fail(w, 403, "店员已停用")
			return
		}
	}
	if action == "transfer" {
		var staff bool
		if a.db.QueryRow(r.Context(), `select exists(select 1 from marketplace_staff ms join agent ag on ag.id=ms.agent_id where ms.marketplace_id=$1 and ms.shop_id=$2 and ms.external_id=$3 and ag.status='ACTIVE')`, mid, r.PathValue("shopId"), in["ownerExternalId"]).Scan(&staff) != nil || !staff {
			fail(w, 403, "福利群只能转让给本店有效店员")
			return
		}
	}
	if action == "manager" && in["isManager"] == true {
		var staff bool
		if a.db.QueryRow(r.Context(), `select exists(select 1 from marketplace_staff s join agent ag on ag.id=s.agent_id where s.marketplace_id=$1 and s.shop_id=$2 and s.external_id=$3 and ag.status='ACTIVE')`, mid, r.PathValue("shopId"), in["externalId"]).Scan(&staff) != nil || !staff {
			fail(w, 403, "只能授权本店有效店员为福利群管理员")
			return
		}
	}
	if action == "token" {
		var disabled bool
		if a.db.QueryRow(r.Context(), `select exists(select 1 from marketplace_staff ms join agent ag on ag.id=ms.agent_id where ms.marketplace_id=$1 and ms.shop_id=$2 and ms.external_id=$3 and ag.status<>'ACTIVE')`, mid, r.PathValue("shopId"), in["externalId"]).Scan(&disabled) != nil || disabled {
			fail(w, 403, "店员已停用")
			return
		}
	}
	raw, _ := json.Marshal(in)
	request := r.Clone(r.Context())
	request.Body = io.NopCloser(bytes.NewReader(raw))
	next(w, request, apiKeyPrincipal{TenantID: tenant, Scopes: []string{"read", "write"}})
}
func (a *API) marketplaceGroupCreate(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	a.marketplaceGroupProxy(w, r, mid, "create", a.openGroupCreate)
}
func (a *API) marketplaceGroupMembers(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	a.marketplaceGroupProxy(w, r, mid, "members", a.openGroupAddMembers)
}
func (a *API) marketplaceGroupToken(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	a.marketplaceGroupProxy(w, r, mid, "token", a.openGroupMemberToken)
}
func (a *API) marketplaceGroupInvite(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	a.marketplaceGroupProxy(w, r, mid, "invite", a.openGroupInvite)
}
func (a *API) marketplaceGroupManager(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	a.marketplaceGroupProxy(w, r, mid, "manager", a.openGroupManager)
}
func (a *API) marketplaceGroupPolicy(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	a.marketplaceGroupProxy(w, r, mid, "policy", a.openGroupPolicy)
}
func (a *API) marketplaceGroupList(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	a.marketplaceGroupProxy(w, r, mid, "list", a.openGroupList)
}
func (a *API) marketplaceGroupDetail(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	a.marketplaceGroupProxy(w, r, mid, "detail", a.openGroupDetail)
}
func (a *API) marketplaceGroupEdit(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	a.marketplaceGroupProxy(w, r, mid, "edit", a.openGroupEdit)
}
func (a *API) marketplaceGroupTransfer(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	a.marketplaceGroupProxy(w, r, mid, "transfer", a.openGroupTransfer)
}
func (a *API) marketplaceGroupRemove(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	a.marketplaceGroupProxy(w, r, mid, "remove", a.openGroupRemove)
}
func (a *API) marketplaceGroupDissolve(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	a.marketplaceGroupProxy(w, r, mid, "dissolve", a.openGroupDissolve)
}
