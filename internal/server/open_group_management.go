package server

import (
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/relaydesk/relaydesk/internal/auth"
)

// 登录凭证管理群时也在群锁内复核所有权，防止转让后的旧群主并发写入。
func groupOwnerLocked(r *http.Request, tx pgx.Tx, gid uuid.UUID, p auth.Principal) bool {
	var owner, tenant uuid.UUID
	var kind string
	if tx.QueryRow(r.Context(), `select owner_id,owner_kind,tenant_id from chat_group where id=$1 for update`, gid).Scan(&owner, &kind, &tenant) != nil || owner != groupActor(p) || kind != p.Kind || tenant != p.TenantID {
		return false
	}
	var member bool
	err := tx.QueryRow(r.Context(), `select exists(select 1 from chat_group_member where group_id=$1 and actor_kind=$2 and actor_id=$3)`, gid, p.Kind, groupActor(p)).Scan(&member)
	return err == nil && member
}

// 群页使用已认证的聊天身份转让；目标必须为同群、同身份类型的现有成员。
func (a *API) groupTransfer(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Kind string    `json:"kind"`
		ID   uuid.UUID `json:"id"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Kind != p.Kind || in.ID == uuid.Nil {
		fail(w, 400, "新群主身份类型或ID无效")
		return
	}
	gid, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "群ID无效")
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "转让失败")
		return
	}
	defer tx.Rollback(r.Context())
	if !groupOwnerLocked(r, tx, gid, p) {
		fail(w, 403, "仅当前群主可转让")
		return
	}
	var closed bool
	if tx.QueryRow(r.Context(), `select archived or dissolved_at is not null from chat_group where id=$1`, gid).Scan(&closed) != nil {
		fail(w, 500, "读取群失败")
		return
	}
	if closed {
		fail(w, 409, "群已归档或解散")
		return
	}
	tag, err := tx.Exec(r.Context(), `update chat_group g set owner_id=$2,updated_at=now() where id=$1 and exists(select 1 from chat_group_member where group_id=$1 and actor_kind=$3 and actor_id=$2)`, gid, in.ID, in.Kind)
	if err != nil {
		fail(w, 500, "转让失败")
		return
	}
	if tag.RowsAffected() == 0 {
		fail(w, 400, "新群主必须是现有成员")
		return
	}
	a.finishExternalGroup(w, r, tx, gid)
}

func validExternalMember(m openGroupMemberIn) bool {
	return strings.TrimSpace(m.ExternalID) != "" && len(strings.TrimSpace(m.ExternalID)) <= 200 && utf8.RuneCountInString(strings.TrimSpace(m.DisplayName)) <= 120
}

// 外部用户仅映射为 visitor，绝不建立 agent 或复制宿主用户目录。
func (a *API) openGroupCreate(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	var in struct {
		InboxKey        string              `json:"inboxKey"`
		ExternalGroupID string              `json:"externalGroupId"`
		Name            string              `json:"name"`
		Owner           openGroupMemberIn   `json:"owner"`
		Members         []openGroupMemberIn `json:"members"`
		MaxMembers      int                 `json:"maxMembers"`
		SpeakingMode    string              `json:"speakingMode"`
		RequireIdentity *bool               `json:"requireIdentity"`
	}
	if !decode(w, r, &in) {
		return
	}
	in.Name = strings.TrimSpace(in.Name)
	in.ExternalGroupID = strings.TrimSpace(in.ExternalGroupID)
	if in.MaxMembers == 0 {
		in.MaxMembers = 2000
	}
	if in.SpeakingMode == "" {
		in.SpeakingMode = "ALL"
	}
	requireIdentity := true
	if in.RequireIdentity != nil {
		requireIdentity = *in.RequireIdentity
	}
	if !validGroupPolicy(groupPolicyInput{MaxMembers: &in.MaxMembers, SpeakingMode: &in.SpeakingMode}) {
		fail(w, 400, "发言模式或群容量无效（2至5000）")
		return
	}
	if in.Name == "" || utf8.RuneCountInString(in.Name) > 120 || in.ExternalGroupID == "" || len(in.ExternalGroupID) > 200 || !validExternalMember(in.Owner) || len(in.Members) > 99 {
		fail(w, 400, "请提供群名称、externalGroupId、有效群主及最多99名成员")
		return
	}
	for _, m := range in.Members {
		if !validExternalMember(m) {
			fail(w, 400, "成员ID或昵称无效")
			return
		}
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "建群失败")
		return
	}
	defer tx.Rollback(r.Context())
	var inbox uuid.UUID
	// 对同一入口的建群重试串行化，避免重复群以及部分写入。
	if err = tx.QueryRow(r.Context(), `select id from inbox where tenant_id=$1 and public_key=$2 and status='ACTIVE' for update`, p.TenantID, in.InboxKey).Scan(&inbox); err != nil {
		fail(w, 404, "入口不存在或已停用")
		return
	}
	var existing uuid.UUID
	err = tx.QueryRow(r.Context(), `select id from chat_group where tenant_id=$1 and inbox_id=$2 and external_group_id=$3`, p.TenantID, inbox, in.ExternalGroupID).Scan(&existing)
	if err == nil {
		if !externalGroupActor(r, tx, existing, in.Owner.ExternalID, true) {
			fail(w, 409, "externalGroupId 已使用且群主不匹配")
			return
		}
		respond(w, 200, map[string]any{"id": existing, "groupId": existing, "created": false})
		return
	}
	if err != pgx.ErrNoRows {
		fail(w, 500, "读取群失败")
		return
	}
	owner, _, err := upsertVisitorExternal(r.Context(), tx, p.TenantID, inbox, strings.TrimSpace(in.Owner.ExternalID), strings.TrimSpace(in.Owner.DisplayName))
	if err != nil {
		fail(w, 500, "建立群主映射失败")
		return
	}
	gid := uuid.New()
	if _, err = tx.Exec(r.Context(), `insert into chat_group(id,tenant_id,inbox_id,name,kind,owner_kind,owner_id,external_group_id,max_members,speaking_mode,require_identity) values($1,$2,$3,$4,'SERVICE','widget',$5,$6,$7,$8,$9)`, gid, p.TenantID, inbox, in.Name, owner, in.ExternalGroupID, in.MaxMembers, in.SpeakingMode, requireIdentity); err != nil {
		fail(w, 500, "建群失败")
		return
	}
	for _, m := range append([]openGroupMemberIn{in.Owner}, in.Members...) {
		name := strings.TrimSpace(m.DisplayName)
		if name == "" {
			name = "客户"
		}
		visitor, _, e := upsertVisitorExternal(r.Context(), tx, p.TenantID, inbox, strings.TrimSpace(m.ExternalID), name)
		if e != nil {
			fail(w, 500, "建立成员映射失败")
			return
		}
		if _, e = tx.Exec(r.Context(), `insert into chat_group_member(group_id,actor_kind,actor_id,name) values($1,'widget',$2,$3) on conflict do nothing`, gid, visitor, name); e != nil {
			fail(w, 500, "添加成员失败")
			return
		}
	}
	var memberCount int
	if tx.QueryRow(r.Context(), `select count(*) from chat_group_member where group_id=$1`, gid).Scan(&memberCount) != nil {
		fail(w, 500, "读取成员失败")
		return
	}
	if memberCount > in.MaxMembers {
		fail(w, 400, "初始成员数超过群容量")
		return
	}
	if tx.Commit(r.Context()) != nil {
		fail(w, 500, "建群失败")
		return
	}
	a.groupPublish(r.Context(), gid)
	respond(w, 201, map[string]any{"id": gid, "groupId": gid, "created": true})
}

func externalGroupActor(r *http.Request, tx pgx.Tx, gid uuid.UUID, externalID string, owner bool) bool {
	var ok bool
	err := tx.QueryRow(r.Context(), `select exists(select 1 from chat_group g join chat_group_member m on m.group_id=g.id and m.actor_kind='widget' join visitor v on v.id=m.actor_id and v.inbox_id=g.inbox_id and v.tenant_id=g.tenant_id where g.id=$1 and v.external_id=$2 and (not $3 or g.owner_kind='widget' and g.owner_id=v.id))`, gid, strings.TrimSpace(externalID), owner).Scan(&ok)
	return err == nil && ok
}

// 所有管理动作先锁群再检查群主，使转让、移除、解散与加人互斥。
func (a *API) lockExternalGroup(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal, actor string, owner, allowClosed bool) (pgx.Tx, uuid.UUID, bool) {
	gid, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "群ID无效")
		return nil, gid, false
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "操作失败")
		return nil, gid, false
	}
	var closed bool
	err = tx.QueryRow(r.Context(), `select g.archived or g.dissolved_at is not null from chat_group g join inbox i on i.id=g.inbox_id where g.id=$1 and g.tenant_id=$2 and g.kind='SERVICE' and g.owner_kind='widget' and i.status='ACTIVE' for update of g`, gid, p.TenantID).Scan(&closed)
	if err != nil {
		tx.Rollback(r.Context())
		fail(w, 404, "第三方群不存在或入口已停用")
		return nil, gid, false
	}
	if !externalGroupActor(r, tx, gid, actor, owner) {
		tx.Rollback(r.Context())
		fail(w, 403, "用户不是群成员或没有群主管理权限")
		return nil, gid, false
	}
	if closed && !allowClosed {
		tx.Rollback(r.Context())
		fail(w, 409, "群已归档或解散")
		return nil, gid, false
	}
	return tx, gid, true
}

func (a *API) openGroupList(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	actor := strings.TrimSpace(r.URL.Query().Get("externalId"))
	if actor == "" || len(actor) > 200 {
		fail(w, 400, "需要当前登录用户externalId")
		return
	}
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
	rows, err := a.db.Query(r.Context(), `select g.id,g.name,g.external_group_id,g.archived,g.dissolved_at is not null,v.external_id from chat_group g join inbox i on i.id=g.inbox_id and i.status='ACTIVE' join chat_group_member m on m.group_id=g.id and m.actor_kind='widget' join visitor u on u.id=m.actor_id and u.external_id=$2 left join visitor v on v.id=g.owner_id and g.owner_kind='widget' where g.tenant_id=$1 and g.owner_kind='widget' order by g.updated_at desc,g.id limit $3 offset $4`, p.TenantID, actor, limit, offset)
	if err != nil {
		fail(w, 500, "读取群列表失败")
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var id uuid.UUID
		var name, key, owner string
		var archived, dissolved bool
		if rows.Scan(&id, &name, &key, &archived, &dissolved, &owner) != nil {
			fail(w, 500, "读取群列表失败")
			return
		}
		items = append(items, map[string]any{"id": id, "name": name, "externalGroupId": key, "ownerExternalId": owner, "archived": archived, "dissolved": dissolved})
	}
	if rows.Err() != nil {
		fail(w, 500, "读取群列表失败")
		return
	}
	respond(w, 200, map[string]any{"items": items, "limit": limit, "offset": offset})
}

func (a *API) openGroupDetail(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	tx, gid, ok := a.lockExternalGroup(w, r, p, r.URL.Query().Get("externalId"), false, true)
	if !ok {
		return
	}
	defer tx.Rollback(r.Context())
	var name, key, announcement, owner string
	var archived, dissolved bool
	var mode string
	var capacity int
	var requireIdentity bool
	if tx.QueryRow(r.Context(), `select g.name,g.external_group_id,g.announcement,g.archived,g.dissolved_at is not null,v.external_id,g.speaking_mode,g.max_members,g.require_identity from chat_group g join visitor v on v.id=g.owner_id where g.id=$1`, gid).Scan(&name, &key, &announcement, &archived, &dissolved, &owner, &mode, &capacity, &requireIdentity) != nil {
		fail(w, 500, "读取群失败")
		return
	}
	rows, err := tx.Query(r.Context(), `select v.external_id,m.name,m.is_manager from chat_group_member m join visitor v on v.id=m.actor_id where m.group_id=$1 and m.actor_kind='widget' order by v.external_id`, gid)
	if err != nil {
		fail(w, 500, "读取成员失败")
		return
	}
	members := []map[string]any{}
	for rows.Next() {
		var id, n string
		var manager bool
		if rows.Scan(&id, &n, &manager) != nil {
			rows.Close()
			fail(w, 500, "读取成员失败")
			return
		}
		members = append(members, map[string]any{"externalId": id, "displayName": n, "isOwner": id == owner, "isManager": manager})
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		fail(w, 500, "读取成员失败")
		return
	}
	respond(w, 200, map[string]any{"id": gid, "name": name, "externalGroupId": key, "announcement": announcement, "ownerExternalId": owner, "archived": archived, "dissolved": dissolved, "members": members, "speakingMode": mode, "maxMembers": capacity, "requireIdentity": requireIdentity})
}

func (a *API) finishExternalGroup(w http.ResponseWriter, r *http.Request, tx pgx.Tx, gid uuid.UUID) {
	if tx.Commit(r.Context()) != nil {
		fail(w, 500, "保存失败")
		return
	}
	a.groupPublish(r.Context(), gid)
	respond(w, 200, map[string]any{"ok": true})
}

func (a *API) openGroupEdit(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	var in struct {
		ActorExternalID string  `json:"actorExternalId"`
		Name            *string `json:"name"`
		Announcement    *string `json:"announcement"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Name != nil {
		n := strings.TrimSpace(*in.Name)
		in.Name = &n
		if n == "" || utf8.RuneCountInString(n) > 120 {
			fail(w, 400, "群名称需1至120字")
			return
		}
	}
	if in.Announcement != nil && utf8.RuneCountInString(*in.Announcement) > 2000 {
		fail(w, 400, "公告最多2000字")
		return
	}
	tx, gid, ok := a.lockExternalGroup(w, r, p, in.ActorExternalID, true, false)
	if !ok {
		return
	}
	defer tx.Rollback(r.Context())
	if _, err := tx.Exec(r.Context(), `update chat_group set name=coalesce($2,name),announcement=coalesce($3,announcement),updated_at=now() where id=$1`, gid, in.Name, in.Announcement); err != nil {
		fail(w, 500, "保存失败")
		return
	}
	a.finishExternalGroup(w, r, tx, gid)
}

func (a *API) openGroupTransfer(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	var in struct {
		ActorExternalID string `json:"actorExternalId"`
		OwnerExternalID string `json:"ownerExternalId"`
	}
	if !decode(w, r, &in) {
		return
	}
	tx, gid, ok := a.lockExternalGroup(w, r, p, in.ActorExternalID, true, false)
	if !ok {
		return
	}
	defer tx.Rollback(r.Context())
	tag, err := tx.Exec(r.Context(), `update chat_group g set owner_id=v.id,updated_at=now() from visitor v,chat_group_member m where g.id=$1 and v.inbox_id=g.inbox_id and v.tenant_id=g.tenant_id and v.external_id=$2 and m.group_id=g.id and m.actor_kind='widget' and m.actor_id=v.id`, gid, strings.TrimSpace(in.OwnerExternalID))
	if err != nil {
		fail(w, 500, "转让失败")
		return
	}
	if tag.RowsAffected() == 0 {
		fail(w, 400, "新群主必须是现有群成员")
		return
	}
	a.finishExternalGroup(w, r, tx, gid)
}

func (a *API) openGroupRemove(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	actor := r.URL.Query().Get("actorExternalId")
	target := r.PathValue("externalId")
	tx, gid, ok := a.lockExternalGroup(w, r, p, actor, strings.TrimSpace(actor) != target, false)
	if !ok {
		return
	}
	defer tx.Rollback(r.Context())
	var visitor, owner uuid.UUID
	err := tx.QueryRow(r.Context(), `select v.id,g.owner_id from chat_group g join visitor v on v.inbox_id=g.inbox_id and v.tenant_id=g.tenant_id and v.external_id=$2 where g.id=$1`, gid, target).Scan(&visitor, &owner)
	if err == pgx.ErrNoRows {
		a.finishExternalGroup(w, r, tx, gid)
		return
	}
	if err != nil {
		fail(w, 500, "移除失败")
		return
	}
	if visitor == owner {
		fail(w, 409, "请先转让群主或解散群，不能移除群主")
		return
	}
	if _, err = tx.Exec(r.Context(), `delete from chat_group_member where group_id=$1 and actor_kind='widget' and actor_id=$2`, gid, visitor); err != nil {
		fail(w, 500, "移除失败")
		return
	}
	if _, err = tx.Exec(r.Context(), `update chat_group_call set state='ENDED',offer='{}',answer=null,updated_at=now() where group_id=$1 and state in ('RINGING','ACCEPTED') and (caller_kind='widget' and caller_id=$2 or recipient_kind='widget' and recipient_id=$2)`, gid, visitor); err != nil || pruneGroupRooms(r.Context(), tx, gid) != nil {
		fail(w, 500, "停止通话失败")
		return
	}
	a.finishExternalGroup(w, r, tx, gid)
}

func (a *API) openGroupDissolve(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	var in struct {
		ActorExternalID string `json:"actorExternalId"`
	}
	if !decode(w, r, &in) {
		return
	}
	tx, gid, ok := a.lockExternalGroup(w, r, p, in.ActorExternalID, true, true)
	if !ok {
		return
	}
	defer tx.Rollback(r.Context())
	for _, q := range []string{`update chat_group set dissolved_at=coalesce(dissolved_at,now()),archived=true,updated_at=now() where id=$1`, `update chat_group_invite set revoked=true where group_id=$1`, `update chat_group_call set state='ENDED',offer='{}',answer=null,updated_at=now() where group_id=$1 and state in ('RINGING','ACCEPTED')`} {
		if _, err := tx.Exec(r.Context(), q, gid); err != nil {
			fail(w, 500, "解散失败")
			return
		}
	}
	if pruneGroupRooms(r.Context(), tx, gid) != nil {
		fail(w, 500, "停止通话失败")
		return
	}
	a.finishExternalGroup(w, r, tx, gid)
}
