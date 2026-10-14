package server

import (
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/relaydesk/relaydesk/internal/auth"
	"net/http"
)

const maxGroupMembers = 5000

type groupPolicyInput struct {
	ActorExternalID string  `json:"actorExternalId"`
	SpeakingMode    *string `json:"speakingMode"`
	MaxMembers      *int    `json:"maxMembers"`
	RequireIdentity *bool   `json:"requireIdentity"`
}

func validGroupPolicy(in groupPolicyInput) bool {
	return (in.SpeakingMode == nil || *in.SpeakingMode == "ALL" || *in.SpeakingMode == "MANAGERS") && (in.MaxMembers == nil || *in.MaxMembers >= 2 && *in.MaxMembers <= maxGroupMembers)
}

// 所有角色与发言权限均从数据库判断，不能由客户端自报店员身份。
func groupManagerLocked(r *http.Request, tx pgx.Tx, gid uuid.UUID, kind string, actor uuid.UUID) bool {
	var allowed bool
	err := tx.QueryRow(r.Context(), `select exists(select 1 from chat_group g join chat_group_member m on m.group_id=g.id where g.id=$1 and m.actor_kind=$2 and m.actor_id=$3 and (m.is_manager or g.owner_kind=$2 and g.owner_id=$3))`, gid, kind, actor).Scan(&allowed)
	return err == nil && allowed
}

func (a *API) saveGroupPolicy(w http.ResponseWriter, r *http.Request, tx pgx.Tx, gid uuid.UUID, in groupPolicyInput) {
	defer tx.Rollback(r.Context())
	var closed bool
	var count int
	if err := tx.QueryRow(r.Context(), `select archived or dissolved_at is not null,(select count(*) from chat_group_member where group_id=$1) from chat_group where id=$1`, gid).Scan(&closed, &count); err != nil {
		fail(w, 500, "读取群失败")
		return
	}
	if closed {
		fail(w, 409, "群已归档或解散")
		return
	}
	if in.MaxMembers != nil && *in.MaxMembers < count {
		fail(w, 409, "容量不能小于现有成员数")
		return
	}
	if _, err := tx.Exec(r.Context(), `update chat_group set speaking_mode=coalesce($2,speaking_mode),max_members=coalesce($3,max_members),require_identity=coalesce($4,require_identity),updated_at=now() where id=$1`, gid, in.SpeakingMode, in.MaxMembers, in.RequireIdentity); err != nil {
		fail(w, 500, "保存群规则失败")
		return
	}
	a.finishExternalGroup(w, r, tx, gid)
}

func (a *API) groupPolicy(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in groupPolicyInput
	if !decode(w, r, &in) {
		return
	}
	if !validGroupPolicy(in) {
		fail(w, 400, "发言模式需为ALL或MANAGERS，群容量需为2至5000")
		return
	}
	gid, ok := a.groupAllowed(r, p, true)
	if !ok {
		fail(w, 403, "仅群主可设置群规则")
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "保存失败")
		return
	}
	if !groupOwnerLocked(r, tx, gid, p) {
		tx.Rollback(r.Context())
		fail(w, 403, "仅当前群主可设置群规则")
		return
	}
	a.saveGroupPolicy(w, r, tx, gid, in)
}

func (a *API) openGroupPolicy(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	var in groupPolicyInput
	if !decode(w, r, &in) {
		return
	}
	if !validGroupPolicy(in) {
		fail(w, 400, "发言模式需为ALL或MANAGERS，群容量需为2至5000")
		return
	}
	tx, gid, ok := a.lockExternalGroup(w, r, p, in.ActorExternalID, true, false)
	if !ok {
		return
	}
	a.saveGroupPolicy(w, r, tx, gid, in)
}

// 宿主后端先校验店员属于店铺，群主再授权为群管理员。
func (a *API) openGroupManager(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	var in struct {
		ActorExternalID string `json:"actorExternalId"`
		ExternalID      string `json:"externalId"`
		IsManager       bool   `json:"isManager"`
	}
	if !decode(w, r, &in) {
		return
	}
	tx, gid, ok := a.lockExternalGroup(w, r, p, in.ActorExternalID, true, false)
	if !ok {
		return
	}
	defer tx.Rollback(r.Context())
	tag, err := tx.Exec(r.Context(), `update chat_group_member m set is_manager=$3 from visitor v where m.group_id=$1 and m.actor_kind='widget' and v.id=m.actor_id and v.external_id=$2`, gid, in.ExternalID, in.IsManager)
	if err != nil {
		fail(w, 500, "设置管理员失败")
		return
	}
	if tag.RowsAffected() == 0 {
		fail(w, 404, "用户必须先加入群")
		return
	}
	a.finishExternalGroup(w, r, tx, gid)
}

func (a *API) groupManager(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Kind      string    `json:"kind"`
		ID        uuid.UUID `json:"id"`
		IsManager bool      `json:"isManager"`
	}
	if !decode(w, r, &in) {
		return
	}
	if (in.Kind != auth.KindAgent && in.Kind != auth.KindWidget) || in.ID == uuid.Nil {
		fail(w, 400, "成员标识无效")
		return
	}
	gid, ok := a.groupAllowed(r, p, true)
	if !ok {
		fail(w, 403, "仅群主可授权管理员")
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "设置失败")
		return
	}
	defer tx.Rollback(r.Context())
	if !groupOwnerLocked(r, tx, gid, p) {
		fail(w, 403, "仅当前群主可授权管理员")
		return
	}
	tag, err := tx.Exec(r.Context(), `update chat_group_member set is_manager=$4 where group_id=$1 and actor_kind=$2 and actor_id=$3 and exists(select 1 from chat_group where id=$1 and not archived and dissolved_at is null)`, gid, in.Kind, in.ID, in.IsManager)
	if err != nil {
		fail(w, 500, "设置失败")
		return
	}
	if tag.RowsAffected() == 0 {
		fail(w, 409, "群已关闭或用户不是成员")
		return
	}
	a.finishExternalGroup(w, r, tx, gid)
}

func (a *API) openGroupInvite(w http.ResponseWriter, r *http.Request, p apiKeyPrincipal) {
	var in struct {
		ActorExternalID string `json:"actorExternalId"`
	}
	if !decode(w, r, &in) {
		return
	}
	tx, gid, ok := a.lockExternalGroup(w, r, p, in.ActorExternalID, false, false)
	if !ok {
		return
	}
	defer tx.Rollback(r.Context())
	var actor uuid.UUID
	if tx.QueryRow(r.Context(), `select m.actor_id from chat_group_member m join visitor v on v.id=m.actor_id where m.group_id=$1 and m.actor_kind='widget' and v.external_id=$2`, gid, in.ActorExternalID).Scan(&actor) != nil || !groupManagerLocked(r, tx, gid, auth.KindWidget, actor) {
		fail(w, 403, "仅群主或管理员可邀请")
		return
	}
	a.issueGroupInvite(w, r, tx, gid)
}
