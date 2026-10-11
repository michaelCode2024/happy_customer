package server

import (
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// 宿主用自己的用户 ID（externalId）往服务群加人，不在聊桥镜像整库用户。
func (a *API) registerOpenGroups(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/open/groups/{id}/members", a.requireAPIKey("write", a.openGroupAddMembers))
	mux.HandleFunc("POST /api/v1/open/groups/{id}/member-token", a.requireAPIKey("write", a.openGroupMemberToken))
}

type openGroupMemberIn struct {
	ExternalID  string `json:"externalId"`
	DisplayName string `json:"displayName"`
}

func (a *API) openGroupAddMembers(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	if !a.tenantHasFeature(r.Context(), p.TenantID, "groups") {
		failCode(w, 403, "PLAN_FEATURE_REQUIRED", "当前套餐未包含群聊功能，请联系平台管理员调整套餐")
		return
	}
	gid, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "群 ID 无效")
		return
	}
	var in struct {
		Members []openGroupMemberIn `json:"members"`
	}
	if !decode(w, r, &in) {
		return
	}
	if len(in.Members) == 0 || len(in.Members) > 50 {
		fail(w, 400, "members 每次 1 到 50 人")
		return
	}

	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "加人失败")
		return
	}
	defer tx.Rollback(r.Context())

	var tenant uuid.UUID
	var inbox *uuid.UUID
	var kind string
	var closed bool
	err = tx.QueryRow(r.Context(), `
		select g.tenant_id, g.inbox_id, g.kind, (g.archived or g.dissolved_at is not null)
		  from chat_group g
		 where g.id=$1 for update`, gid).Scan(&tenant, &inbox, &kind, &closed)
	if err != nil || tenant != p.TenantID {
		fail(w, 404, "群不存在或不属于当前企业")
		return
	}
	if kind != "SERVICE" || inbox == nil {
		fail(w, 400, "只能向客户服务群按用户 ID 加人")
		return
	}
	if closed {
		fail(w, 409, "群已归档或解散，不能加人")
		return
	}

	var memberCount int
	if tx.QueryRow(r.Context(), `select count(*) from chat_group_member where group_id=$1`, gid).Scan(&memberCount) != nil {
		fail(w, 500, "加人失败")
		return
	}

	added := []map[string]any{}
	already := []map[string]any{}
	skipped := []map[string]any{}
	seen := map[string]bool{}

	for _, item := range in.Members {
		externalID := strings.TrimSpace(item.ExternalID)
		name := strings.TrimSpace(item.DisplayName)
		if externalID == "" || len(externalID) > 200 {
			skipped = append(skipped, map[string]any{"externalId": item.ExternalID, "reason": "externalId 必须为 1 到 200 个字符"})
			continue
		}
		if seen[externalID] {
			skipped = append(skipped, map[string]any{"externalId": externalID, "reason": "请求内重复"})
			continue
		}
		seen[externalID] = true
		if name == "" {
			name = "客户"
		}
		if utf8.RuneCountInString(name) > 120 {
			skipped = append(skipped, map[string]any{"externalId": externalID, "reason": "displayName 最多 120 字"})
			continue
		}

		visitorID, _, upsertErr := upsertVisitorExternal(r.Context(), tx, tenant, *inbox, externalID, name)
		if upsertErr != nil {
			fail(w, 500, "创建或匹配访客失败")
			return
		}

		var isMember bool
		if tx.QueryRow(r.Context(), `select exists(select 1 from chat_group_member where group_id=$1 and actor_kind='widget' and actor_id=$2)`, gid, visitorID).Scan(&isMember) != nil {
			fail(w, 500, "加人失败")
			return
		}
		row := map[string]any{"externalId": externalID, "visitorId": visitorID, "displayName": name}
		if isMember {
			// 已是成员时刷新群昵称，便于宿主改展示名后同步。
			_, _ = tx.Exec(r.Context(), `update chat_group_member set name=$3 where group_id=$1 and actor_kind='widget' and actor_id=$2`, gid, visitorID, name)
			already = append(already, row)
			continue
		}
		if memberCount >= 100 {
			skipped = append(skipped, map[string]any{"externalId": externalID, "reason": "群成员已达到上限"})
			continue
		}
		if _, e := tx.Exec(r.Context(), `insert into chat_group_member(group_id,actor_kind,actor_id,name) values($1,'widget',$2,$3)`, gid, visitorID, name); e != nil {
			fail(w, 500, "加人失败")
			return
		}
		memberCount++
		added = append(added, row)
	}

	if tx.Commit(r.Context()) != nil {
		fail(w, 500, "加人失败")
		return
	}
	if len(added) > 0 {
		a.groupPublish(r.Context(), gid)
	}
	respond(w, 200, map[string]any{
		"groupId":        gid,
		"added":          added,
		"alreadyMembers": already,
		"skipped":        skipped,
	})
}

// 宿主校验本站登录后，为已入群用户签发群聊会话 token，前端写入 sessionStorage 打开群页。
func (a *API) openGroupMemberToken(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	if !a.tenantHasFeature(r.Context(), p.TenantID, "groups") {
		failCode(w, 403, "PLAN_FEATURE_REQUIRED", "当前套餐未包含群聊功能，请联系平台管理员调整套餐")
		return
	}
	gid, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "群 ID 无效")
		return
	}
	var in struct {
		ExternalID string `json:"externalId"`
	}
	if !decode(w, r, &in) {
		return
	}
	externalID := strings.TrimSpace(in.ExternalID)
	if externalID == "" || len(externalID) > 200 {
		fail(w, 400, "externalId 必须为 1 到 200 个字符")
		return
	}

	var tenant, inbox, visitor uuid.UUID
	var kind string
	var closed bool
	err = a.db.QueryRow(r.Context(), `
		select g.tenant_id, g.inbox_id, g.kind, (g.archived or g.dissolved_at is not null), v.id
		  from chat_group g
		  join visitor v on v.tenant_id=g.tenant_id and v.inbox_id=g.inbox_id and v.external_id=$2
		  join chat_group_member m on m.group_id=g.id and m.actor_kind='widget' and m.actor_id=v.id
		 where g.id=$1`, gid, externalID).Scan(&tenant, &inbox, &kind, &closed, &visitor)
	if err != nil {
		if err == pgx.ErrNoRows {
			fail(w, 404, "用户不是该群成员，请先按 externalId 加人")
			return
		}
		fail(w, 500, "签发失败")
		return
	}
	if tenant != p.TenantID || kind != "SERVICE" {
		fail(w, 404, "群不存在或不属于当前企业")
		return
	}
	if closed {
		fail(w, 409, "群已归档或解散")
		return
	}
	token, err := a.tokens.IssueWidget(tenant, inbox, visitor)
	if err != nil {
		fail(w, 500, "签发失败")
		return
	}
	expiresIn := int(time.Hour.Seconds())
	// cfg 为值类型；未配置 TTL 时用 1 小时，与访客会话默认一致。
	if a.cfg.WidgetTokenTTL > 0 {
		expiresIn = int(a.cfg.WidgetTokenTTL.Seconds())
	}
	w.Header().Set("Cache-Control", "no-store")
	respond(w, 200, map[string]any{
		"token":     token,
		"visitorId": visitor,
		"groupId":   gid,
		"expiresIn": expiresIn,
	})
}

// upsertVisitorExternal 与一对一 bootstrap 相同：同入口同 externalId 复用 visitor。
func upsertVisitorExternal(ctx handlerContext, q interface {
	QueryRow(handlerContext, string, ...any) pgx.Row
}, tenantID, inboxID uuid.UUID, externalID, displayName string) (uuid.UUID, bool, error) {
	var visitorID uuid.UUID
	var created bool
	err := q.QueryRow(ctx, `
		insert into visitor(id, tenant_id, inbox_id, external_id, display_name, custom_attributes, last_seen_at)
		values($1,$2,$3,$4,$5,'{}'::jsonb, now())
		on conflict (inbox_id, external_id) where external_id is not null
		do update set display_name = coalesce(excluded.display_name, visitor.display_name),
		              updated_at = now(), last_seen_at = now()
		returning id, (xmax = 0) as inserted`,
		uuid.New(), tenantID, inboxID, externalID, nullable(displayName)).Scan(&visitorID, &created)
	return visitorID, created, err
}
