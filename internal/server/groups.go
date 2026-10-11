package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"github.com/google/uuid"
	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/realtime"
	"net/http"
	"strings"
)

func groupActor(p auth.Principal) uuid.UUID {
	if p.Kind == auth.KindAgent {
		return p.AgentID
	}
	return p.VisitorID
}
func (a *API) groupAuth(next func(http.ResponseWriter, *http.Request, auth.Principal)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		p, e := a.tokens.Verify(bearer(r))
		if e != nil || (p.Kind != auth.KindAgent && p.Kind != auth.KindWidget) {
			fail(w, 401, "请重新登录")
			return
		}
		if p.Kind == auth.KindAgent && !a.authn.SessionValid(r.Context(), p.SessionID, p.AgentID) {
			fail(w, 401, "登录已失效")
			return
		}
		if !a.tenantActive(r.Context(), p.TenantID) {
			fail(w, 403, "企业已停用")
			return
		}
		if p.Kind == auth.KindAgent {
			var active bool
			p, active = a.currentAgent(r.Context(), p)
			if !active {
				fail(w, 401, "账号已停用")
				return
			}
		}
		if !a.allowPlanRoute(w, r, p) {
			return
		}
		next(w, r, p)
	}
}
func (a *API) registerGroups(m *http.ServeMux) {
	m.HandleFunc("GET /api/v1/groups", a.groupAuth(a.groupList))
	m.HandleFunc("POST /api/v1/groups", a.requireAgent(a.groupCreate))
	m.HandleFunc("GET /api/v1/groups/{id}", a.groupAuth(a.groupDetail))
	m.HandleFunc("PATCH /api/v1/groups/{id}", a.requireAgent(a.groupUpdate))
	m.HandleFunc("GET /api/v1/groups/{id}/messages", a.groupAuth(a.groupMessages))
	m.HandleFunc("POST /api/v1/groups/{id}/messages", a.groupAuth(a.groupSend))
	m.HandleFunc("POST /api/v1/groups/{id}/read", a.groupAuth(a.groupRead))
	m.HandleFunc("POST /api/v1/groups/{id}/members", a.requireAgent(a.groupAdd))
	m.HandleFunc("DELETE /api/v1/groups/{id}/members/{kind}/{actor}", a.groupAuth(a.groupRemove))
	m.HandleFunc("POST /api/v1/groups/{id}/invite", a.requireAgent(a.groupInvite))
	m.HandleFunc("POST /api/v1/group-join/{ticket}", a.limit(a.widgetRate, a.groupJoin))
	// 已入群的登录客户用 identityToken 换群聊会话，无需再走邀请链。
	m.HandleFunc("POST /api/v1/groups/session", a.limit(a.widgetRate, a.groupSession))
	m.HandleFunc("PATCH /api/v1/groups/{id}/me", a.groupAuth(a.groupNickname))
	m.HandleFunc("POST /api/v1/groups/{id}/messages/{message}/recall", a.groupAuth(a.groupRecall))
	m.HandleFunc("POST /api/v1/groups/{id}/dissolve", a.requireAgent(a.groupDissolve))
	m.HandleFunc("GET /api/v1/groups/{id}/calls", a.groupAuth(a.groupCalls))
	m.HandleFunc("POST /api/v1/groups/{id}/calls", a.groupAuth(a.groupCallStart))
	m.HandleFunc("POST /api/v1/groups/{id}/calls/{call}", a.groupAuth(a.groupCallAction))
	m.HandleFunc("GET /ws/groups", a.groupSocket)
	m.HandleFunc("GET /api/v1/groups/{id}/rooms", a.groupAuth(a.groupRooms))
	m.HandleFunc("POST /api/v1/groups/{id}/rooms", a.groupAuth(a.groupRoomAction))
}
func (a *API) groupAllowed(r *http.Request, p auth.Principal, owner bool) (uuid.UUID, bool) {
	id, e := uuid.Parse(r.PathValue("id"))
	if e != nil {
		return id, false
	}
	var ok bool
	e = a.db.QueryRow(r.Context(), `select exists(select 1 from chat_group g join chat_group_member m on m.group_id=g.id where g.id=$1 and g.tenant_id=$2 and m.actor_kind=$3 and m.actor_id=$4 and (not $5 or g.owner_id=$4 and $3='agent'))`, id, p.TenantID, p.Kind, groupActor(p), owner).Scan(&ok)
	return id, e == nil && ok
}
func (a *API) groupList(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	rows, e := a.db.Query(r.Context(), `select g.id,g.name,g.kind,g.archived,g.dissolved_at is not null,g.announcement,g.sequence,(select count(*) from chat_group_message gm where gm.group_id=g.id and gm.sequence>m.last_read and (gm.actor_kind<>m.actor_kind or gm.actor_id<>m.actor_id)),g.owner_id,(select count(*) from chat_group_member mm where mm.group_id=g.id) from chat_group g join chat_group_member m on m.group_id=g.id where g.tenant_id=$1 and m.actor_kind=$2 and m.actor_id=$3 order by g.updated_at desc limit 100`, p.TenantID, p.Kind, groupActor(p))
	if e != nil {
		fail(w, 500, "读取群列表失败")
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var id, owner uuid.UUID
		var name, kind, announcement string
		var archived, dissolved bool
		var seq, read, count int64
		if rows.Scan(&id, &name, &kind, &archived, &dissolved, &announcement, &seq, &read, &owner, &count) != nil {
			continue
		}
		items = append(items, map[string]any{"id": id, "name": name, "kind": kind, "archived": archived, "dissolved": dissolved, "announcement": announcement, "sequence": seq, "unread": read, "ownerId": owner, "memberCount": count})
	}
	respond(w, 200, map[string]any{"items": items})
}
func (a *API) groupCreate(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Name     string      `json:"name"`
		Kind     string      `json:"kind"`
		InboxID  string      `json:"inboxId"`
		AgentIDs []uuid.UUID `json:"agentIds"`
	}
	if !decode(w, r, &in) {
		return
	}
	in.Name = strings.TrimSpace(in.Name)
	if len([]rune(in.Name)) == 0 || len([]rune(in.Name)) > 120 || (in.Kind != "INTERNAL" && in.Kind != "SERVICE") || len(in.AgentIDs) > 100 {
		fail(w, 400, "请填写群名称和正确的群类型（最多100名成员）")
		return
	}
	var inbox any
	if in.Kind == "SERVICE" {
		id, e := uuid.Parse(in.InboxID)
		var ok bool
		if e == nil {
			a.db.QueryRow(r.Context(), `select exists(select 1 from agent_inbox where inbox_id=$1 and agent_id=$2)`, id, p.AgentID).Scan(&ok)
		}
		if !ok {
			fail(w, 403, "请选择有接待权限的客服入口")
			return
		}
		inbox = id
	}
	tx, e := a.db.Begin(r.Context())
	if e != nil {
		fail(w, 500, "建群失败")
		return
	}
	defer tx.Rollback(r.Context())
	id := uuid.New()
	if _, e = tx.Exec(r.Context(), `insert into chat_group(id,tenant_id,inbox_id,name,kind,owner_id) values($1,$2,$3,$4,$5,$6)`, id, p.TenantID, inbox, in.Name, in.Kind, p.AgentID); e != nil {
		fail(w, 500, "建群失败")
		return
	}
	ids := append(in.AgentIDs, p.AgentID)
	for _, actor := range ids {
		var name string
		e = tx.QueryRow(r.Context(), `select display_name from agent where id=$1 and tenant_id=$2 and status='ACTIVE'`, actor, p.TenantID).Scan(&name)
		if e != nil {
			fail(w, 400, "成员必须是同企业有效账号")
			return
		}
		if _, e = tx.Exec(r.Context(), `insert into chat_group_member(group_id,actor_kind,actor_id,name) values($1,'agent',$2,$3) on conflict do nothing`, id, actor, name); e != nil {
			fail(w, 500, "添加成员失败")
			return
		}
	}
	if e = tx.Commit(r.Context()); e != nil {
		fail(w, 500, "建群失败")
		return
	}
	a.groupPublish(r.Context(), id)
	respond(w, 201, map[string]any{"id": id})
}
func (a *API) groupDetail(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.groupAllowed(r, p, false)
	if !ok {
		fail(w, 404, "群不存在或你不是群成员")
		return
	}
	rows, e := a.db.Query(r.Context(), `select actor_kind,actor_id,name,last_read from chat_group_member where group_id=$1 order by actor_kind,name`, id)
	if e != nil {
		fail(w, 500, "读取成员失败")
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var kind, name string
		var actor uuid.UUID
		var read int64
		if rows.Scan(&kind, &actor, &name, &read) == nil {
			items = append(items, map[string]any{"kind": kind, "id": actor, "name": name, "lastRead": read})
		}
	}
	respond(w, 200, map[string]any{"members": items})
}
func (a *API) groupUpdate(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.groupAllowed(r, p, true)
	if !ok {
		fail(w, 403, "仅群主可修改群资料")
		return
	}
	var in struct {
		Name         string `json:"name"`
		Announcement string `json:"announcement"`
		Archived     bool   `json:"archived"`
	}
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.Name) == "" || len([]rune(in.Name)) > 120 || len([]rune(in.Announcement)) > 2000 {
		fail(w, 400, "群名称或公告长度不正确")
		return
	}
	tx, e := a.db.Begin(r.Context())
	if e != nil {
		fail(w, 500, "保存失败")
		return
	}
	defer tx.Rollback(r.Context())
	result, e := tx.Exec(r.Context(), `update chat_group set name=$2,announcement=$3,archived=$4,updated_at=now() where id=$1 and dissolved_at is null`, id, in.Name, in.Announcement, in.Archived)
	if e != nil {
		fail(w, 500, "保存失败")
		return
	}
	if result.RowsAffected() == 0 {
		fail(w, 409, "群已解散，不能修改")
		return
	}
	if in.Archived {
		if _, e = tx.Exec(r.Context(), `update chat_group_call set state='ENDED',offer='{}',answer=null,updated_at=now() where group_id=$1 and state in ('RINGING','ACCEPTED')`, id); e != nil {
			fail(w, 500, "保存失败")
			return
		}
	}
	if pruneGroupRooms(r.Context(), tx, id) != nil || tx.Commit(r.Context()) != nil {
		fail(w, 500, "保存失败")
		return
	}
	a.groupPublish(r.Context(), id)
	respond(w, 200, map[string]any{"ok": true})
}
func (a *API) groupMessages(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.groupAllowed(r, p, false)
	if !ok {
		fail(w, 404, "群不存在或你不是群成员")
		return
	}
	after := queryInt64(r, "after", 0)
	before := queryInt64(r, "before", 0)
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	rows, e := a.db.Query(r.Context(), `select id,sequence,actor_kind,actor_id,name,case when recalled_at is null then content else '' end,created_at,recalled_at is not null from chat_group_message where group_id=$1 and ($2=0 or sequence>$2) and ($3=0 or sequence<$3) and ($4='' or recalled_at is null and content ilike '%'||$4||'%') order by sequence desc limit 100`, id, after, before, q)
	if e != nil {
		fail(w, 500, "读取消息失败")
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var msg, actor uuid.UUID
		var seq int64
		var kind, name, content string
		var at any
		var recalled bool
		if rows.Scan(&msg, &seq, &kind, &actor, &name, &content, &at, &recalled) == nil {
			items = append(items, map[string]any{"id": msg, "sequence": seq, "kind": kind, "actorId": actor, "name": name, "content": content, "createdAt": at, "recalled": recalled})
		}
	}
	respond(w, 200, map[string]any{"items": items})
}
func (a *API) groupSend(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.groupAllowed(r, p, false)
	if !ok {
		fail(w, 404, "你不是群成员")
		return
	}
	var in struct {
		Content  string    `json:"content"`
		ClientID uuid.UUID `json:"clientId"`
	}
	if !decode(w, r, &in) {
		return
	}
	if strings.TrimSpace(in.Content) == "" || len([]rune(in.Content)) > 4000 || in.ClientID == uuid.Nil {
		fail(w, 400, "消息不能为空且最多4000字，需要消息标识")
		return
	}
	tx, e := a.db.Begin(r.Context())
	if e != nil {
		fail(w, 500, "发送失败")
		return
	}
	defer tx.Rollback(r.Context())
	if _, e = tx.Exec(r.Context(), `select pg_advisory_xact_lock(hashtextextended($1,0))`, p.TenantID.String()); e != nil {
		fail(w, 500, "发送失败")
		return
	}
	var seq int64
	var archived bool
	if e = tx.QueryRow(r.Context(), `select sequence,(archived or dissolved_at is not null) from chat_group where id=$1 for update`, id).Scan(&seq, &archived); e != nil || archived {
		fail(w, 409, "群已归档或解散，不能发送消息")
		return
	}
	var name string
	if e = tx.QueryRow(r.Context(), `select name from chat_group_member where group_id=$1 and actor_kind=$2 and actor_id=$3`, id, p.Kind, groupActor(p)).Scan(&name); e != nil {
		fail(w, 403, "你已离开此群")
		return
	}
	var existing uuid.UUID
	e = tx.QueryRow(r.Context(), `select id from chat_group_message where group_id=$1 and actor_kind=$2 and actor_id=$3 and client_id=$4`, id, p.Kind, groupActor(p), in.ClientID).Scan(&existing)
	if e == nil {
		respond(w, 200, map[string]any{"id": existing})
		return
	}
	if e = a.checkMessageQuota(r.Context(), tx, p.TenantID); e != nil {
		if !failServiceError(w, e) {
			fail(w, 500, "无法读取消息额度")
		}
		return
	}
	msg := uuid.New()
	seq++
	if _, e = tx.Exec(r.Context(), `insert into chat_group_message(id,group_id,sequence,actor_kind,actor_id,name,content,client_id) values($1,$2,$3,$4,$5,$6,$7,$8)`, msg, id, seq, p.Kind, groupActor(p), name, in.Content, in.ClientID); e != nil {
		fail(w, 500, "发送失败")
		return
	}
	if _, e = tx.Exec(r.Context(), `update chat_group set sequence=$2,updated_at=now() where id=$1`, id, seq); e != nil {
		fail(w, 500, "发送失败")
		return
	}
	if e = tx.Commit(r.Context()); e != nil {
		fail(w, 500, "发送失败")
		return
	}
	a.groupPublish(r.Context(), id)
	respond(w, 201, map[string]any{"id": msg, "sequence": seq})
}
func (a *API) groupRead(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.groupAllowed(r, p, false)
	if !ok {
		fail(w, 404, "群不存在")
		return
	}
	var in struct {
		Sequence int64 `json:"sequence"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Sequence <= 0 {
		fail(w, 400, "sequence 必须大于零")
		return
	}
	var lastRead int64
	e := a.db.QueryRow(r.Context(), `update chat_group_member set last_read=greatest(last_read,least($4,(select sequence from chat_group where id=$1))) where group_id=$1 and actor_kind=$2 and actor_id=$3 returning last_read`, id, p.Kind, groupActor(p), in.Sequence).Scan(&lastRead)
	if e != nil {
		fail(w, 500, "更新已读失败")
		return
	}
	var unread int64
	_ = a.db.QueryRow(r.Context(), `select count(*) from chat_group_message where group_id=$1 and sequence>$2 and (actor_kind<>$3 or actor_id<>$4)`, id, lastRead, p.Kind, groupActor(p)).Scan(&unread)
	respond(w, 200, map[string]any{"readSequence": lastRead, "unread": unread})
}

func (a *API) groupAdd(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.groupAllowed(r, p, true)
	if !ok {
		fail(w, 403, "仅群主可添加成员")
		return
	}
	var in struct {
		AgentID uuid.UUID `json:"agentId"`
	}
	if !decode(w, r, &in) {
		return
	}
	tag, e := a.db.Exec(r.Context(), `insert into chat_group_member(group_id,actor_kind,actor_id,name) select $1,'agent',id,display_name from agent where id=$2 and tenant_id=$3 and status='ACTIVE' and exists(select 1 from chat_group where id=$1 and not archived and dissolved_at is null) on conflict do nothing`, id, in.AgentID, p.TenantID)
	if e != nil || tag.RowsAffected() == 0 {
		fail(w, 400, "成员已在群中或账号不可用")
		return
	}
	a.groupPublish(r.Context(), id)
	respond(w, 200, map[string]any{"ok": true})
}
func (a *API) groupRemove(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.groupAllowed(r, p, false)
	if !ok {
		fail(w, 404, "群不存在")
		return
	}
	target, e := uuid.Parse(r.PathValue("actor"))
	kind := r.PathValue("kind")
	if e != nil || (kind != "agent" && kind != "widget") {
		fail(w, 400, "成员标识错误")
		return
	}
	tx, e := a.db.Begin(r.Context())
	if e != nil {
		fail(w, 500, "移除失败")
		return
	}
	defer tx.Rollback(r.Context())
	var owner uuid.UUID
	if tx.QueryRow(r.Context(), `select owner_id from chat_group where id=$1 for update`, id).Scan(&owner) != nil {
		fail(w, 404, "群不存在")
		return
	}
	if kind == "agent" && target == owner {
		fail(w, 409, "群主请先归档群，不能直接退出")
		return
	}
	if !(p.Kind == auth.KindAgent && p.AgentID == owner) && !(kind == p.Kind && target == groupActor(p)) {
		fail(w, 403, "仅群主可移除他人")
		return
	}
	_, e = tx.Exec(r.Context(), `delete from chat_group_member where group_id=$1 and actor_kind=$2 and actor_id=$3`, id, kind, target)
	if e != nil {
		fail(w, 500, "移除失败")
		return
	}
	if _, e = tx.Exec(r.Context(), `update chat_group_call set state='ENDED',offer='{}',answer=null,updated_at=now() where group_id=$1 and state in ('RINGING','ACCEPTED') and (caller_kind=$2 and caller_id=$3 or recipient_kind=$2 and recipient_id=$3)`, id, kind, target); e != nil || pruneGroupRooms(r.Context(), tx, id) != nil || tx.Commit(r.Context()) != nil {
		fail(w, 500, "移除失败")
		return
	}
	a.groupPublish(r.Context(), id)
	respond(w, 200, map[string]any{"ok": true})
}
func inviteHash(s string) string { v := sha256.Sum256([]byte(s)); return hex.EncodeToString(v[:]) }
func (a *API) groupInvite(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.groupAllowed(r, p, true)
	if !ok {
		fail(w, 403, "仅群主可以邀请客户")
		return
	}
	var kind string
	var archived bool
	a.db.QueryRow(r.Context(), `select kind,(archived or dissolved_at is not null) from chat_group where id=$1`, id).Scan(&kind, &archived)
	if kind != "SERVICE" || archived {
		fail(w, 400, "只有未归档的客户服务群可邀请客户")
		return
	}
	ticket := uuid.NewString() + uuid.NewString()
	tx, e := a.db.Begin(r.Context())
	if e != nil {
		fail(w, 500, "创建邀请失败")
		return
	}
	defer tx.Rollback(r.Context())
	if _, e = tx.Exec(r.Context(), `update chat_group_invite set revoked=true where group_id=$1`, id); e != nil {
		fail(w, 500, "撤销旧邀请失败")
		return
	}
	if _, e = tx.Exec(r.Context(), `insert into chat_group_invite(token_hash,group_id,expires_at) values($1,$2,now()+interval '24 hours')`, inviteHash(ticket), id); e != nil {
		fail(w, 500, "生成邀请失败")
		return
	}
	if tx.Commit(r.Context()) != nil {
		fail(w, 500, "生成邀请失败")
		return
	}
	respond(w, 200, map[string]any{"url": strings.TrimRight(a.cfg.PublicBaseURL, "/") + "/groups.html?invite=" + ticket, "expiresIn": 86400})
}
func (a *API) groupJoin(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Name          string `json:"name"`
		IdentityToken string `json:"identityToken"`
	}
	if !decode(w, r, &in) {
		return
	}
	in.Name = strings.TrimSpace(in.Name)
	identityToken := strings.TrimSpace(in.IdentityToken)
	if identityToken == "" && (in.Name == "" || len([]rune(in.Name)) > 120) {
		fail(w, 400, "请输入称呼（最多120字）")
		return
	}
	if identityToken != "" && in.Name != "" && len([]rune(in.Name)) > 120 {
		fail(w, 400, "称呼最多120字")
		return
	}
	tx, e := a.db.Begin(r.Context())
	if e != nil {
		fail(w, 500, "加入失败")
		return
	}
	defer tx.Rollback(r.Context())
	var id, tenant, inbox uuid.UUID
	e = tx.QueryRow(r.Context(), `select g.id,g.tenant_id,g.inbox_id from chat_group_invite i join chat_group g on g.id=i.group_id join tenant t on t.id=g.tenant_id where i.token_hash=$1 and not i.revoked and i.expires_at>now() and g.kind='SERVICE' and not g.archived and g.dissolved_at is null and t.status in ('ACTIVE','TRIAL') for update of g`, inviteHash(r.PathValue("ticket"))).Scan(&id, &tenant, &inbox)
	if e != nil {
		fail(w, 404, "邀请已过期或已撤销")
		return
	}
	if !a.tenantHasFeature(r.Context(), tenant, "groups") {
		failCode(w, 403, "PLAN_FEATURE_REQUIRED", "当前套餐未包含群聊功能")
		return
	}

	var visitor uuid.UUID
	displayName := in.Name
	status := 201
	if identityToken != "" {
		// 登录客户：票据绑定入口，与一对一会话复用同一 visitor。
		identity, verifyErr := a.tokens.Verify(identityToken)
		if verifyErr != nil || identity.Kind != auth.KindIdentity || identity.TenantID != tenant || identity.InboxID != inbox || identity.ExternalID == "" {
			failCode(w, 401, "IDENTITY_TOKEN_INVALID", "访客身份票据无效、已过期或不属于此群入口")
			return
		}
		displayName = strings.TrimSpace(identity.Name)
		if displayName == "" {
			displayName = in.Name
		}
		if displayName == "" {
			displayName = "客户"
		}
		var upsertErr error
		visitor, _, upsertErr = upsertVisitorExternal(r.Context(), tx, tenant, inbox, identity.ExternalID, displayName)
		if upsertErr != nil {
			fail(w, 500, "加入失败")
			return
		}
		var already bool
		if tx.QueryRow(r.Context(), `select exists(select 1 from chat_group_member where group_id=$1 and actor_kind='widget' and actor_id=$2)`, id, visitor).Scan(&already) != nil {
			fail(w, 500, "加入失败")
			return
		}
		if already {
			_, _ = tx.Exec(r.Context(), `update chat_group_member set name=$3 where group_id=$1 and actor_kind='widget' and actor_id=$2`, id, visitor, displayName)
			status = 200
		} else {
			var count int
			if tx.QueryRow(r.Context(), `select count(*) from chat_group_member where group_id=$1`, id).Scan(&count) != nil || count >= 100 {
				fail(w, 409, "群成员已达到上限")
				return
			}
			if _, e = tx.Exec(r.Context(), `insert into chat_group_member(group_id,actor_kind,actor_id,name) values($1,'widget',$2,$3)`, id, visitor, displayName); e != nil {
				fail(w, 500, "加入失败")
				return
			}
		}
	} else {
		var count int
		if tx.QueryRow(r.Context(), `select count(*) from chat_group_member where group_id=$1`, id).Scan(&count) != nil || count >= 100 {
			fail(w, 409, "群成员已达到上限")
			return
		}
		visitor = uuid.New()
		if _, e = tx.Exec(r.Context(), `insert into visitor(id,tenant_id,inbox_id,display_name) values($1,$2,$3,$4)`, visitor, tenant, inbox, displayName); e != nil {
			fail(w, 500, "加入失败")
			return
		}
		if _, e = tx.Exec(r.Context(), `insert into chat_group_member(group_id,actor_kind,actor_id,name) values($1,'widget',$2,$3)`, id, visitor, displayName); e != nil {
			fail(w, 500, "加入失败")
			return
		}
	}
	token, e := a.tokens.IssueWidget(tenant, inbox, visitor)
	if e != nil || tx.Commit(r.Context()) != nil {
		fail(w, 500, "加入失败")
		return
	}
	if status == 201 {
		a.groupPublish(r.Context(), id)
	}
	respond(w, status, map[string]any{"token": token, "groupId": id, "visitorId": visitor})
}

// groupSession 供已入群的登录客户用 identityToken 打开群页，不依赖邀请链接。
func (a *API) groupSession(w http.ResponseWriter, r *http.Request) {
	var in struct {
		IdentityToken string `json:"identityToken"`
		GroupID       string `json:"groupId"`
	}
	if !decode(w, r, &in) {
		return
	}
	identityToken := strings.TrimSpace(in.IdentityToken)
	gid, err := uuid.Parse(strings.TrimSpace(in.GroupID))
	if identityToken == "" || err != nil {
		fail(w, 400, "需要 identityToken 与 groupId")
		return
	}
	identity, verifyErr := a.tokens.Verify(identityToken)
	if verifyErr != nil || identity.Kind != auth.KindIdentity || identity.ExternalID == "" {
		failCode(w, 401, "IDENTITY_TOKEN_INVALID", "访客身份票据无效或已过期")
		return
	}
	if !a.tenantHasFeature(r.Context(), identity.TenantID, "groups") {
		failCode(w, 403, "PLAN_FEATURE_REQUIRED", "当前套餐未包含群聊功能")
		return
	}

	var tenant, inbox, visitor uuid.UUID
	var kind string
	var closed bool
	var status string
	err = a.db.QueryRow(r.Context(), `
		select g.tenant_id, g.inbox_id, g.kind, (g.archived or g.dissolved_at is not null), t.status
		  from chat_group g join tenant t on t.id=g.tenant_id
		 where g.id=$1`, gid).Scan(&tenant, &inbox, &kind, &closed, &status)
	if err != nil || tenant != identity.TenantID || kind != "SERVICE" || (status != "ACTIVE" && status != "TRIAL") {
		fail(w, 404, "群不存在或不可用")
		return
	}
	if inbox != identity.InboxID {
		failCode(w, 401, "IDENTITY_TOKEN_INVALID", "访客身份票据不属于此群入口")
		return
	}
	if closed {
		fail(w, 409, "群已归档或解散")
		return
	}

	tx, e := a.db.Begin(r.Context())
	if e != nil {
		fail(w, 500, "打开群聊失败")
		return
	}
	defer tx.Rollback(r.Context())
	name := strings.TrimSpace(identity.Name)
	if name == "" {
		name = "客户"
	}
	visitor, _, e = upsertVisitorExternal(r.Context(), tx, tenant, inbox, identity.ExternalID, name)
	if e != nil {
		fail(w, 500, "打开群聊失败")
		return
	}
	var member bool
	if tx.QueryRow(r.Context(), `select exists(select 1 from chat_group_member where group_id=$1 and actor_kind='widget' and actor_id=$2)`, gid, visitor).Scan(&member) != nil || !member {
		fail(w, 403, "你还不是该群成员，请先接受邀请或由业务系统加人")
		return
	}
	token, e := a.tokens.IssueWidget(tenant, inbox, visitor)
	if e != nil || tx.Commit(r.Context()) != nil {
		fail(w, 500, "打开群聊失败")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	respond(w, 200, map[string]any{"token": token, "groupId": gid, "visitorId": visitor})
}
func (a *API) groupPublish(ctx context.Context, id uuid.UUID) {
	rows, e := a.db.Query(ctx, `select actor_kind,actor_id from chat_group_member where group_id=$1`, id)
	if e != nil {
		return
	}
	defer rows.Close()
	channels := []string{}
	for rows.Next() {
		var kind string
		var actor uuid.UUID
		if rows.Scan(&kind, &actor) == nil {
			if kind == auth.KindAgent {
				channels = append(channels, realtime.AgentChannel(actor.String()))
			} else {
				channels = append(channels, realtime.VisitorChannel(actor.String()))
			}
		}
	}
	a.publish(ctx, channels, realtime.Event{Type: "group.updated", Data: map[string]any{"groupId": id}})
}
func (a *API) groupSocket(w http.ResponseWriter, r *http.Request) {
	p, e := a.tokens.Verify(r.URL.Query().Get("token"))
	if e != nil || (p.Kind != auth.KindAgent && p.Kind != auth.KindWidget) || !a.tenantActive(r.Context(), p.TenantID) {
		fail(w, 401, "登录已失效")
		return
	}
	if p.Kind == auth.KindAgent && !a.authn.SessionValid(r.Context(), p.SessionID, p.AgentID) {
		fail(w, 401, "登录已失效")
		return
	}
	conn, e := a.accept(r, w)
	if e != nil {
		return
	}
	channel := realtime.VisitorChannel(p.VisitorID.String())
	if p.Kind == auth.KindAgent {
		channel = realtime.AgentChannel(p.AgentID.String())
	}
	sub := a.hub.Subscribe(conn, []string{channel})
	defer a.hub.Unsubscribe(sub)
	a.guardSocket(r.Context(), sub, p)
	a.socketHello(sub, map[string]any{"kind": "groups"})
	a.pump(r.Context(), conn, sub, func(inbound) {})
}
