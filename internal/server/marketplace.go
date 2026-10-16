package server

import (
	"context"
	"encoding/hex"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/tongyu/tongyu/internal/auth"
	"github.com/tongyu/tongyu/internal/realtime"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

func validExternalID(id string) bool {
	return strings.TrimSpace(id) != "" && len(id) <= 200 && id == strings.TrimSpace(id)
}
func validDisplayName(name string) bool {
	return strings.TrimSpace(name) != "" && utf8.RuneCountInString(name) <= 120
}

func (a *API) registerMarketplace(m *http.ServeMux) {
	m.HandleFunc("GET /api/v1/marketplace/shops/{shopId}/groups", a.requireMarketplace(a.marketplaceGroupList))
	m.HandleFunc("GET /api/v1/marketplace/shops/{shopId}/groups/{id}", a.requireMarketplace(a.marketplaceGroupDetail))
	m.HandleFunc("PATCH /api/v1/marketplace/shops/{shopId}/groups/{id}", a.requireMarketplace(a.marketplaceGroupEdit))
	m.HandleFunc("PUT /api/v1/marketplace/shops/{shopId}/groups/{id}/owner", a.requireMarketplace(a.marketplaceGroupTransfer))
	m.HandleFunc("DELETE /api/v1/marketplace/shops/{shopId}/groups/{id}/members/{externalId}", a.requireMarketplace(a.marketplaceGroupRemove))
	m.HandleFunc("POST /api/v1/marketplace/shops/{shopId}/groups/{id}/dissolve", a.requireMarketplace(a.marketplaceGroupDissolve))
	m.HandleFunc("POST /api/v1/marketplace/buyer/groups/{id}/session", a.requireMarketplaceBuyer(a.marketplaceBuyerGroupSession))
	m.HandleFunc("POST /api/v1/marketplace/staff/groups/{id}/session", a.requireAgent(a.marketplaceStaffGroupSession))
	m.HandleFunc("GET /api/v1/marketplace/buyer/threads", a.requireMarketplaceBuyer(a.marketplaceBuyerThreads))
	m.HandleFunc("POST /api/v1/marketplace/shops/{shopId}/groups", a.requireMarketplace(a.marketplaceGroupCreate))
	m.HandleFunc("POST /api/v1/marketplace/shops/{shopId}/groups/{id}/members", a.requireMarketplace(a.marketplaceGroupMembers))
	m.HandleFunc("POST /api/v1/marketplace/shops/{shopId}/groups/{id}/member-token", a.requireMarketplace(a.marketplaceGroupToken))
	m.HandleFunc("POST /api/v1/marketplace/shops/{shopId}/groups/{id}/invite", a.requireMarketplace(a.marketplaceGroupInvite))
	m.HandleFunc("PUT /api/v1/marketplace/shops/{shopId}/groups/{id}/manager", a.requireMarketplace(a.marketplaceGroupManager))
	m.HandleFunc("PATCH /api/v1/marketplace/shops/{shopId}/groups/{id}/policy", a.requireMarketplace(a.marketplaceGroupPolicy))
	m.HandleFunc("POST /api/v1/marketplace/shops/{shopId}/groups/{id}/cards", a.requireMarketplace(a.marketplaceGroupCard))
	m.HandleFunc("POST /api/v1/marketplace/shops/{shopId}/conversations/{id}/cards", a.requireMarketplace(a.marketplaceCard))
	m.HandleFunc("POST /api/v1/platform/marketplaces", a.requireSuperAdmin(a.platformMarketplace))
	m.HandleFunc("PATCH /api/v1/platform/marketplaces/{id}", a.requireSuperAdmin(a.platformMarketplaceStatus))
	m.HandleFunc("PUT /api/v1/marketplace/shops/{shopId}", a.requireMarketplace(a.marketplaceShop))
	m.HandleFunc("GET /api/v1/marketplace/shops/{shopId}", a.requireMarketplace(a.marketplaceShopDetail))
	m.HandleFunc("PUT /api/v1/marketplace/shops/{shopId}/staff/{staffId}", a.requireMarketplace(a.marketplaceStaff))
	m.HandleFunc("POST /api/v1/marketplace/shops/{shopId}/staff-session", a.requireMarketplace(a.marketplaceStaffSession))
	m.HandleFunc("POST /api/v1/marketplace/buyer-session", a.requireMarketplace(a.marketplaceBuyerSession))
	m.HandleFunc("POST /api/v1/marketplace/buyer/logout", a.requireMarketplaceBuyer(a.marketplaceBuyerLogout))
	m.HandleFunc("POST /api/v1/marketplace/buyer/shops/{shopId}/session", a.requireMarketplaceBuyer(a.marketplaceBuyerShopSession))
	m.HandleFunc("GET /api/v1/marketplace/buyer/conversations", a.requireMarketplaceBuyer(a.marketplaceBuyerConversations))
	m.HandleFunc("GET /ws/marketplace", a.marketplaceBuyerSocket)
}

func (a *API) platformMarketplace(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Name string `json:"name"`
		Plan string `json:"plan"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !validDisplayName(in.Name) {
		fail(w, 400, "商城名称需1至120字")
		return
	}
	if in.Plan == "" {
		in.Plan = "ENTERPRISE"
	}
	if in.Plan != "STARTER" && in.Plan != "GROWTH" && in.Plan != "ENTERPRISE" {
		fail(w, 400, "套餐无效")
		return
	}
	key, hash, err := auth.NewOpaqueToken()
	if err != nil {
		fail(w, 500, "生成密钥失败")
		return
	}
	id := uuid.New()
	if _, err = a.db.Exec(r.Context(), `insert into marketplace(id,name,key_hash,plan) values($1,$2,$3,$4)`, id, in.Name, hash, in.Plan); err != nil {
		fail(w, 500, "创建商城失败")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	respond(w, 201, map[string]any{"id": id, "name": in.Name, "apiKey": key, "plan": in.Plan})
}
func (a *API) platformMarketplaceStatus(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "商城ID无效")
		return
	}
	var in struct {
		Status string `json:"status"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Status != "ACTIVE" && in.Status != "DISABLED" {
		fail(w, 400, "状态无效")
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "保存失败")
		return
	}
	defer tx.Rollback(r.Context())
	tag, err := tx.Exec(r.Context(), `update marketplace set status=$2 where id=$1`, id, in.Status)
	if err != nil || tag.RowsAffected() == 0 {
		fail(w, 404, "商城不存在")
		return
	}
	// 停用商城时撤销店员与买家会话，恢复后必须重新登录。
	if in.Status == "DISABLED" {
		if _, err = tx.Exec(r.Context(), `delete from agent_session where agent_id in(select agent_id from marketplace_staff where marketplace_id=$1)`, id); err != nil {
			fail(w, 500, "撤销会话失败")
			return
		}
		if _, err = tx.Exec(r.Context(), `update marketplace_buyer_session set revoked_at=now() where marketplace_id=$1`, id); err != nil {
			fail(w, 500, "撤销会话失败")
			return
		}
	}
	if tx.Commit(r.Context()) != nil {
		fail(w, 500, "保存失败")
		return
	}
	respond(w, 200, map[string]any{"ok": true})
}

func (a *API) requireMarketplace(next func(http.ResponseWriter, *http.Request, uuid.UUID)) http.HandlerFunc {
	return a.limit(a.openRate, func(w http.ResponseWriter, r *http.Request) {
		key := r.Header.Get("X-TongYu-Marketplace-Key")
		var id uuid.UUID
		if key == "" || a.db.QueryRow(r.Context(), `select id from marketplace where key_hash=$1 and status='ACTIVE'`, auth.HashToken(key)).Scan(&id) != nil {
			failCode(w, 401, "MARKETPLACE_KEY_INVALID", "商城密钥无效或已停用")
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		next(w, r, id)
	})
}

func (a *API) marketplaceShop(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	shop := r.PathValue("shopId")
	var in struct {
		Name   string `json:"name"`
		Status string `json:"status"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !validExternalID(shop) || !validDisplayName(in.Name) {
		fail(w, 400, "店铺ID或名称无效")
		return
	}
	if in.Status == "" {
		in.Status = "ACTIVE"
	}
	if in.Status != "ACTIVE" && in.Status != "SUSPENDED" {
		fail(w, 400, "店铺状态需ACTIVE或SUSPENDED")
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "开通店铺失败")
		return
	}
	defer tx.Rollback(r.Context())
	// 同商城建店串行化，避免重试创建多租户；套餐由平台授权，商城不能自升套餐。
	var plan string
	if tx.QueryRow(r.Context(), `select plan from marketplace where id=$1 and status='ACTIVE' for update`, mid).Scan(&plan) != nil {
		fail(w, 401, "商城已停用")
		return
	}
	var tenant, inbox uuid.UUID
	err = tx.QueryRow(r.Context(), `select tenant_id,inbox_id from marketplace_shop where marketplace_id=$1 and external_id=$2`, mid, shop).Scan(&tenant, &inbox)
	created := err == pgx.ErrNoRows
	if err != nil && !created {
		fail(w, 500, "读取店铺失败")
		return
	}
	key := ""
	if created {
		tenant, inbox = uuid.New(), uuid.New()
		key = "shop-" + inbox.String()
		seats, messages := planLimits(plan)
		if _, err = tx.Exec(r.Context(), `insert into tenant(id,name,slug,status) values($1,$2,$3,$4)`, tenant, in.Name, "shop-"+tenant.String(), in.Status); err == nil {
			_, err = tx.Exec(r.Context(), `insert into tenant_subscription(tenant_id,plan,status,seat_limit,monthly_message_limit,monthly_ai_limit) values($1,$2,'ACTIVE',$3,$4,0)`, tenant, plan, seats, messages)
		}
		if err == nil {
			_, err = tx.Exec(r.Context(), `insert into inbox(id,tenant_id,name,public_key,status,auto_assign) values($1,$2,$3,$4,'ACTIVE',false)`, inbox, tenant, in.Name, key)
		}
		if err == nil {
			_, err = tx.Exec(r.Context(), `insert into marketplace_shop(marketplace_id,external_id,tenant_id,inbox_id) values($1,$2,$3,$4)`, mid, shop, tenant, inbox)
		}
	} else {
		_, err = tx.Exec(r.Context(), `update tenant set name=$2,status=$3,updated_at=now() where id=$1`, tenant, in.Name, in.Status)
		if err == nil {
			err = tx.QueryRow(r.Context(), `select public_key from inbox where id=$1`, inbox).Scan(&key)
		}
	}
	if err == nil && in.Status == "SUSPENDED" {
		_, err = tx.Exec(r.Context(), `delete from agent_session where agent_id in(select id from agent where tenant_id=$1)`, tenant)
	}
	if err != nil || tx.Commit(r.Context()) != nil {
		fail(w, 500, "保存店铺失败")
		return
	}
	status := 200
	if created {
		status = 201
	}
	respond(w, status, map[string]any{"shopId": shop, "tenantId": tenant, "inboxId": inbox, "inboxKey": key, "created": created, "status": in.Status})
}
func (a *API) marketplaceShopDetail(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	var tenant, inbox uuid.UUID
	var name, key, status string
	if a.db.QueryRow(r.Context(), `select s.tenant_id,s.inbox_id,t.name,t.status,i.public_key from marketplace_shop s join tenant t on t.id=s.tenant_id join inbox i on i.id=s.inbox_id where s.marketplace_id=$1 and s.external_id=$2`, mid, r.PathValue("shopId")).Scan(&tenant, &inbox, &name, &status, &key) != nil {
		fail(w, 404, "店铺不存在")
		return
	}
	respond(w, 200, map[string]any{"shopId": r.PathValue("shopId"), "tenantId": tenant, "inboxId": inbox, "name": name, "status": status, "inboxKey": key})
}

func (a *API) marketplaceStaff(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	shop, staff := r.PathValue("shopId"), r.PathValue("staffId")
	var in struct {
		Name   string `json:"displayName"`
		Role   string `json:"role"`
		Status string `json:"status"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !validExternalID(staff) || !validDisplayName(in.Name) || !auth.ValidRole(in.Role) {
		fail(w, 400, "店员ID、昵称或角色无效")
		return
	}
	if in.Status == "" {
		in.Status = "ACTIVE"
	}
	if in.Status != "ACTIVE" && in.Status != "DISABLED" {
		fail(w, 400, "店员状态无效")
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "同步店员失败")
		return
	}
	defer tx.Rollback(r.Context())
	var tenant, inbox uuid.UUID
	if tx.QueryRow(r.Context(), `select s.tenant_id,s.inbox_id from marketplace_shop s join tenant t on t.id=s.tenant_id join marketplace m on m.id=s.marketplace_id where s.marketplace_id=$1 and s.external_id=$2 and t.status='ACTIVE' and m.status='ACTIVE' for update of t`, mid, shop).Scan(&tenant, &inbox) != nil {
		fail(w, 404, "店铺不存在或已停用")
		return
	}
	var agent uuid.UUID
	err = tx.QueryRow(r.Context(), `select agent_id from marketplace_staff where marketplace_id=$1 and shop_id=$2 and external_id=$3`, mid, shop, staff).Scan(&agent)
	created := err == pgx.ErrNoRows
	if created {
		if in.Status == "ACTIVE" {
			var count, limit int
			if tx.QueryRow(r.Context(), `select seat_limit,(select count(*) from agent where tenant_id=$1 and status='ACTIVE') from tenant_subscription where tenant_id=$1`, tenant).Scan(&limit, &count) != nil {
				fail(w, 500, "读取席位失败")
				return
			}
			if count >= limit {
				failCode(w, 403, "SEAT_LIMIT_REACHED", "店铺客服席位已满")
				return
			}
		}
		agent = uuid.New()
		password, _, e := auth.NewOpaqueToken()
		if e != nil {
			fail(w, 500, "创建店员失败")
			return
		}
		hash, e := auth.HashPassword(password)
		if e != nil {
			fail(w, 500, "创建店员失败")
			return
		}
		_, err = tx.Exec(r.Context(), `insert into agent(id,tenant_id,email,display_name,password_hash,role,status) values($1,$2,$3,$4,$5,$6,$7)`, agent, tenant, agent.String()+"@marketplace.invalid", in.Name, hash, in.Role, in.Status)
		if err == nil {
			_, err = tx.Exec(r.Context(), `insert into marketplace_staff(marketplace_id,shop_id,external_id,agent_id) values($1,$2,$3,$4)`, mid, shop, staff, agent)
		}
	} else if err == nil {
		// 恢复停用成员也必须检查席位，角色变更使旧会话失效。
		var oldStatus, oldRole string
		if tx.QueryRow(r.Context(), `select status,role from agent where id=$1`, agent).Scan(&oldStatus, &oldRole) != nil {
			fail(w, 500, "读取店员失败")
			return
		}
		if oldStatus != "ACTIVE" && in.Status == "ACTIVE" {
			var count, limit int
			if tx.QueryRow(r.Context(), `select seat_limit,(select count(*) from agent where tenant_id=$1 and status='ACTIVE') from tenant_subscription where tenant_id=$1`, tenant).Scan(&limit, &count) != nil || count >= limit {
				failCode(w, 403, "SEAT_LIMIT_REACHED", "店铺客服席位已满")
				return
			}
		}
		_, err = tx.Exec(r.Context(), `update agent set display_name=$2,role=$3,status=$4,updated_at=now() where id=$1`, agent, in.Name, in.Role, in.Status)
		if err == nil && (oldStatus != in.Status || oldRole != in.Role) {
			_, err = tx.Exec(r.Context(), `delete from agent_session where agent_id=$1`, agent)
		}
	}
	if err == nil {
		_, err = tx.Exec(r.Context(), `insert into agent_inbox(agent_id,inbox_id) values($1,$2) on conflict do nothing`, agent, inbox)
	}
	if err != nil || tx.Commit(r.Context()) != nil {
		fail(w, 500, "保存店员失败")
		return
	}
	status := 200
	if created {
		status = 201
	}
	respond(w, status, map[string]any{"agentId": agent, "staffId": staff, "shopId": shop, "role": in.Role, "status": in.Status, "created": created})
}

func (a *API) marketplaceStaffSession(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	var in struct {
		ExternalID string `json:"externalId"`
	}
	if !decode(w, r, &in) {
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "登录失败")
		return
	}
	defer tx.Rollback(r.Context())
	var p auth.Principal
	var name, role string
	if tx.QueryRow(r.Context(), `select ag.id,ag.tenant_id,ag.display_name,ag.role,s.inbox_id from marketplace_staff ms join marketplace_shop s on s.marketplace_id=ms.marketplace_id and s.external_id=ms.shop_id join marketplace m on m.id=s.marketplace_id join agent ag on ag.id=ms.agent_id join tenant t on t.id=s.tenant_id where ms.marketplace_id=$1 and ms.shop_id=$2 and ms.external_id=$3 and ag.status='ACTIVE' and t.status='ACTIVE' and m.status='ACTIVE' for update of ag`, mid, r.PathValue("shopId"), in.ExternalID).Scan(&p.AgentID, &p.TenantID, &name, &role, &p.InboxID) != nil {
		fail(w, 404, "店员不存在或已停用")
		return
	}
	if !a.tenantActive(r.Context(), p.TenantID) {
		fail(w, 403, "店铺服务已到期")
		return
	}
	p.Name = name
	p.Role = role
	p.SessionID = uuid.New()
	token, err := a.tokens.IssueAgent(p)
	if err == nil {
		_, err = tx.Exec(r.Context(), `insert into agent_session(id,agent_id,token_hash,expires_at) values($1,$2,$3,$4)`, p.SessionID, p.AgentID, auth.HashToken(token), time.Now().Add(a.cfg.AgentSessionTTL))
	}
	if err != nil || tx.Commit(r.Context()) != nil {
		fail(w, 500, "登录失败")
		return
	}
	respond(w, 200, map[string]any{"token": token, "expiresIn": int(a.cfg.AgentSessionTTL.Seconds()), "agent": map[string]any{"id": p.AgentID, "displayName": name, "role": role}, "tenantId": p.TenantID, "inboxId": p.InboxID})
}

func (a *API) marketplaceBuyerSession(w http.ResponseWriter, r *http.Request, mid uuid.UUID) {
	var in struct {
		ExternalID string `json:"externalId"`
		Name       string `json:"displayName"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !validExternalID(in.ExternalID) || !validDisplayName(in.Name) {
		fail(w, 400, "买家ID或昵称无效")
		return
	}
	sid := uuid.New()
	token, err := a.tokens.IssueMarketplaceBuyer(mid, sid, in.ExternalID, in.Name)
	if err == nil {
		_, err = a.db.Exec(r.Context(), `insert into marketplace_buyer_session(id,marketplace_id,external_id,expires_at) select $1,$2,$3,now()+interval '1 hour' from marketplace where id=$2 and status='ACTIVE'`, sid, mid, in.ExternalID)
	}
	if err != nil {
		fail(w, 500, "签发买家身份失败")
		return
	}
	respond(w, 200, map[string]any{"token": token, "expiresIn": 3600})
}
func (a *API) marketplaceBuyerValid(ctx context.Context, p auth.Principal) bool {
	if p.Kind != auth.KindMarketplaceBuyer && p.Kind != auth.KindWidget && p.Kind != auth.KindIdentity {
		return false
	}
	if p.AgentID != uuid.Nil {
		var valid bool
		err := a.db.QueryRow(ctx, `select exists(select 1 from marketplace m join marketplace_staff ms on ms.marketplace_id=m.id join agent ag on ag.id=ms.agent_id join agent_session ss on ss.agent_id=ag.id where m.id=$1 and ms.agent_id=$2 and ss.id=$3 and ss.expires_at>now() and m.status='ACTIVE' and ag.status='ACTIVE')`, p.MarketplaceID, p.AgentID, p.SessionID).Scan(&valid)
		return err == nil && valid
	}
	var ok bool
	err := a.db.QueryRow(ctx, `select exists(select 1 from marketplace_buyer_session s join marketplace m on m.id=s.marketplace_id where s.id=$1 and s.marketplace_id=$2 and s.external_id=$3 and s.expires_at>now() and s.revoked_at is null and m.status='ACTIVE')`, p.SessionID, p.MarketplaceID, p.ExternalID).Scan(&ok)
	return err == nil && ok
}

func (a *API) marketplaceVisitorActive(ctx context.Context, p auth.Principal) bool {
	var disabled bool
	err := a.db.QueryRow(ctx, `select exists(select 1 from visitor v join marketplace_shop s on s.inbox_id=v.inbox_id join marketplace_staff ms on ms.marketplace_id=s.marketplace_id and ms.shop_id=s.external_id and ms.external_id=v.external_id join agent ag on ag.id=ms.agent_id where v.id=$1 and ag.status<>'ACTIVE')`, p.VisitorID).Scan(&disabled)
	return err == nil && !disabled
}
func (a *API) requireMarketplaceBuyer(next func(http.ResponseWriter, *http.Request, auth.Principal)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		p, err := a.tokens.Verify(bearer(r))
		if err != nil || p.Kind != auth.KindMarketplaceBuyer || !a.marketplaceBuyerValid(r.Context(), p) {
			failCode(w, 401, "BUYER_SESSION_INVALID", "买家登录已失效")
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		next(w, r, p)
	}
}
func (a *API) marketplaceBuyerLogout(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	if _, err := a.db.Exec(r.Context(), `update marketplace_buyer_session set revoked_at=now() where id=$1`, p.SessionID); err != nil {
		fail(w, 500, "退出失败")
		return
	}
	respond(w, 200, map[string]any{"ok": true})
}
func (a *API) marketplaceBuyerShopSession(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var tenant, inbox uuid.UUID
	var key string
	if a.db.QueryRow(r.Context(), `select s.tenant_id,s.inbox_id,i.public_key from marketplace_shop s join tenant t on t.id=s.tenant_id join inbox i on i.id=s.inbox_id where s.marketplace_id=$1 and s.external_id=$2 and t.status='ACTIVE' and i.status='ACTIVE'`, p.MarketplaceID, r.PathValue("shopId")).Scan(&tenant, &inbox, &key) != nil || !a.tenantActive(r.Context(), tenant) {
		fail(w, 404, "店铺不存在或服务不可用")
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "打开店铺聊天失败")
		return
	}
	defer tx.Rollback(r.Context())
	visitor, _, err := upsertVisitorExternal(r.Context(), tx, tenant, inbox, p.ExternalID, p.Name)
	token := ""
	if err == nil {
		token, err = a.tokens.IssueMarketplaceWidget(p, tenant, inbox, visitor)
	}
	identity := ""
	if err == nil {
		identity, err = a.tokens.IssueMarketplaceIdentity(p, tenant, inbox)
	}
	if err != nil || tx.Commit(r.Context()) != nil {
		fail(w, 500, "打开店铺聊天失败")
		return
	}
	respond(w, 200, map[string]any{"token": token, "identityToken": identity, "inboxKey": key, "visitorId": visitor, "tenantId": tenant, "shopId": r.PathValue("shopId")})
}

func (a *API) marketplaceBuyerConversations(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	limit := queryInt(r, "limit", 50)
	if limit < 1 {
		limit = 50
	}
	if limit > 100 {
		limit = 100
	}
	offset := queryInt(r, "offset", 0)
	if offset < 0 {
		offset = 0
	}
	rows, err := a.db.Query(r.Context(), `select c.id,s.external_id,t.name,c.status,coalesce(c.last_message_preview,''),c.last_sequence,c.updated_at,
 (select count(*) from message m where m.conversation_id=c.id and not m.is_private and m.sender_type='AGENT' and m.sequence>coalesce((select last_read_sequence from conversation_read where conversation_id=c.id and reader_type='VISITOR' and reader_id=v.id),0))
 from marketplace_shop s join tenant t on t.id=s.tenant_id join visitor v on v.inbox_id=s.inbox_id and v.external_id=$2 join conversation c on c.visitor_id=v.id and c.tenant_id=s.tenant_id
 where s.marketplace_id=$1 order by c.updated_at desc,c.id limit $3 offset $4`, p.MarketplaceID, p.ExternalID, limit, offset)
	if err != nil {
		fail(w, 500, "读取统一消息列表失败")
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var id uuid.UUID
		var shop, name, status, preview string
		var sequence, unread int64
		var at time.Time
		if rows.Scan(&id, &shop, &name, &status, &preview, &sequence, &at, &unread) != nil {
			fail(w, 500, "读取会话失败")
			return
		}
		items = append(items, map[string]any{"id": id, "shopId": shop, "shopName": name, "status": status, "lastMessagePreview": preview, "lastSequence": sequence, "updatedAt": at, "unread": unread})
	}
	if rows.Err() != nil {
		fail(w, 500, "读取会话失败")
		return
	}
	rows.Close()
	var unread, total int64
	if a.db.QueryRow(r.Context(), `select count(distinct c.id),count(m.id) from marketplace_shop s join visitor v on v.inbox_id=s.inbox_id and v.external_id=$2 join conversation c on c.visitor_id=v.id and c.tenant_id=s.tenant_id left join message m on m.conversation_id=c.id and not m.is_private and m.sender_type='AGENT' and m.sequence>coalesce((select last_read_sequence from conversation_read where conversation_id=c.id and reader_type='VISITOR' and reader_id=v.id),0) where s.marketplace_id=$1`, p.MarketplaceID, p.ExternalID).Scan(&total, &unread) != nil {
		fail(w, 500, "读取未读汇总失败")
		return
	}
	respond(w, 200, map[string]any{"items": items, "total": total, "unread": unread, "limit": limit, "offset": offset})
}

func marketplaceBuyerChannel(mid uuid.UUID, external string) string {
	return "marketplace:" + mid.String() + ":" + hex.EncodeToString(auth.HashToken(external))
}
func (a *API) marketplaceBuyerSocket(w http.ResponseWriter, r *http.Request) {
	p, err := a.tokens.Verify(r.URL.Query().Get("token"))
	if err != nil || p.Kind != auth.KindMarketplaceBuyer || !a.marketplaceBuyerValid(r.Context(), p) {
		fail(w, 401, "买家登录已失效")
		return
	}
	conn, err := a.accept(r, w)
	if err != nil {
		return
	}
	sub := a.hub.Subscribe(conn, []string{marketplaceBuyerChannel(p.MarketplaceID, p.ExternalID)})
	defer a.hub.Unsubscribe(sub)
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
				if time.Now().Unix() >= p.ExpiresAt || !a.marketplaceBuyerValid(ctx, p) {
					conn.CloseNow()
					return
				}
			}
		}
	}()
	a.socketHello(sub, map[string]any{"kind": "marketplace_buyer"})
	a.pump(r.Context(), conn, sub, func(inbound) {})
}

// 统一消息频道只含会话变更提示，不能泄露内部备注或跨商城正文。
func (a *API) publishMarketplaceConversation(ctx context.Context, conversation uuid.UUID) {
	var mid uuid.UUID
	var external string
	if a.db.QueryRow(ctx, `select s.marketplace_id,v.external_id from conversation c join visitor v on v.id=c.visitor_id join marketplace_shop s on s.inbox_id=c.inbox_id where c.id=$1`, conversation).Scan(&mid, &external) != nil {
		return
	}
	a.publish(ctx, []string{marketplaceBuyerChannel(mid, external)}, realtime.Event{Type: "conversation.updated", ConversationID: conversation.String(), Data: map[string]any{"conversationId": conversation}})
}
