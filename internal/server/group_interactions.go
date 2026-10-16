package server

import (
	"encoding/json"
	"net/http"
	"os"
	"strings"

	"github.com/google/uuid"
	"github.com/tongyu/tongyu/internal/auth"
)

func (a *API) groupNickname(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.groupAllowed(r, p, false)
	if !ok {
		fail(w, 404, "你不是群成员")
		return
	}
	var in struct {
		Name string `json:"name"`
	}
	if !decode(w, r, &in) {
		return
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" || len([]rune(in.Name)) > 120 {
		fail(w, 400, "昵称需要1至120字")
		return
	}
	result, e := a.db.Exec(r.Context(), `update chat_group_member set name=$4 where group_id=$1 and actor_kind=$2 and actor_id=$3 and exists(select 1 from chat_group where id=$1 and dissolved_at is null)`, id, p.Kind, groupActor(p), in.Name)
	if e != nil {
		fail(w, 500, "修改昵称失败")
		return
	}
	if result.RowsAffected() == 0 {
		fail(w, 409, "群已解散或你已退出")
		return
	}
	a.groupPublish(r.Context(), id)
	respond(w, 200, map[string]any{"ok": true})
}

func (a *API) groupRecall(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.groupAllowed(r, p, false)
	if !ok {
		fail(w, 404, "你不是群成员")
		return
	}
	msg, e := uuid.Parse(r.PathValue("message"))
	if e != nil {
		fail(w, 400, "消息标识不正确")
		return
	}
	result, e := a.db.Exec(r.Context(), `update chat_group_message set recalled_at=coalesce(recalled_at,now()),content='',metadata='{}' where id=$1 and group_id=$2 and actor_kind=$3 and actor_id=$4`, msg, id, p.Kind, groupActor(p))
	if e != nil {
		fail(w, 500, "撤回失败")
		return
	}
	if result.RowsAffected() == 0 {
		fail(w, 403, "只能撤回自己发送的消息")
		return
	}
	a.groupPublish(r.Context(), id)
	respond(w, 200, map[string]any{"ok": true})
}

func (a *API) groupDissolve(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.groupAllowed(r, p, true)
	if !ok {
		fail(w, 403, "仅群主可解散群聊")
		return
	}
	tx, e := a.db.Begin(r.Context())
	if e != nil {
		fail(w, 500, "解散失败")
		return
	}
	defer tx.Rollback(r.Context())
	if !groupOwnerLocked(r, tx, id, p) {
		fail(w, 403, "仅当前群主可管理群")
		return
	}
	if _, e = tx.Exec(r.Context(), `update chat_group set dissolved_at=coalesce(dissolved_at,now()),archived=true,updated_at=now() where id=$1`, id); e != nil {
		fail(w, 500, "解散失败")
		return
	}
	if _, e = tx.Exec(r.Context(), `update chat_group_invite set revoked=true where group_id=$1`, id); e != nil {
		fail(w, 500, "解散失败")
		return
	}
	if _, e = tx.Exec(r.Context(), `update chat_group_call set state='ENDED',offer='{}',answer=null,updated_at=now() where group_id=$1 and state in ('RINGING','ACCEPTED')`, id); e != nil {
		fail(w, 500, "解散失败")
		return
	}
	if pruneGroupRooms(r.Context(), tx, id) != nil || tx.Commit(r.Context()) != nil {
		fail(w, 500, "解散失败")
		return
	}
	a.groupPublish(r.Context(), id)
	respond(w, 200, map[string]any{"ok": true})
}

// SDP is private signaling data. Only the two participants may read it;
// terminal transitions clear it, and reads never return expired offers.
func (a *API) groupCalls(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.groupAllowed(r, p, false)
	if !ok {
		fail(w, 404, "你不是群成员")
		return
	}
	_, e := a.db.Exec(r.Context(), `update chat_group_call set state=case when state='RINGING' then 'MISSED' else 'ENDED' end,offer='{}',answer=null,updated_at=now() where group_id=$1 and (state='RINGING' and created_at<now()-interval '60 seconds' or state='ACCEPTED' and updated_at<now()-interval '2 hours')`, id)
	if e != nil {
		fail(w, 500, "读取通话失败")
		return
	}
	rows, e := a.db.Query(r.Context(), `select c.id,c.caller_kind,c.caller_id,c.recipient_kind,c.recipient_id,c.state,c.offer,c.answer,c.created_at,coalesce(cm.name,'已离群成员'),coalesce(rm.name,'已离群成员') from chat_group_call c left join chat_group_member cm on cm.group_id=c.group_id and cm.actor_kind=c.caller_kind and cm.actor_id=c.caller_id left join chat_group_member rm on rm.group_id=c.group_id and rm.actor_kind=c.recipient_kind and rm.actor_id=c.recipient_id where c.group_id=$1 and (c.caller_kind=$2 and c.caller_id=$3 or c.recipient_kind=$2 and c.recipient_id=$3) order by c.created_at desc limit 20`, id, p.Kind, groupActor(p))
	if e != nil {
		fail(w, 500, "读取通话失败")
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var call, caller, recipient uuid.UUID
		var ck, rk, state, cn, rn string
		var offer, answer []byte
		var at any
		if rows.Scan(&call, &ck, &caller, &rk, &recipient, &state, &offer, &answer, &at, &cn, &rn) != nil {
			continue
		}
		item := map[string]any{"id": call, "callerKind": ck, "callerId": caller, "recipientKind": rk, "recipientId": recipient, "state": state, "createdAt": at, "callerName": cn, "recipientName": rn}
		if state == "RINGING" || state == "ACCEPTED" {
			item["offer"] = json.RawMessage(offer)
			if len(answer) > 0 {
				item["answer"] = json.RawMessage(answer)
			}
		}
		items = append(items, item)
	}
	ice := []any{}
	// Deployers provide their own STUN/TURN configuration; no third-party
	// server receives network metadata by default.
	if raw := os.Getenv("TONGYU_RTC_ICE_SERVERS"); raw != "" {
		json.Unmarshal([]byte(raw), &ice)
	}
	respond(w, 200, map[string]any{"items": items, "iceServers": ice})
}

type groupSDP struct {
	Type string `json:"type"`
	SDP  string `json:"sdp"`
}

func validGroupSDP(s groupSDP, kind string) bool {
	return s.Type == kind && strings.HasPrefix(s.SDP, "v=0") && len(s.SDP) <= 65536
}

func (a *API) groupCallStart(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.groupAllowed(r, p, false)
	if !ok {
		fail(w, 404, "你不是群成员")
		return
	}
	var in struct {
		RecipientKind string    `json:"recipientKind"`
		RecipientID   uuid.UUID `json:"recipientId"`
		Offer         groupSDP  `json:"offer"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !validGroupSDP(in.Offer, "offer") || in.RecipientID == uuid.Nil || in.RecipientKind != "agent" && in.RecipientKind != "widget" || in.RecipientKind == p.Kind && in.RecipientID == groupActor(p) {
		fail(w, 400, "请选择另一位群成员，并提供语音协商信息")
		return
	}
	tx, e := a.db.Begin(r.Context())
	if e != nil {
		fail(w, 500, "呼叫失败")
		return
	}
	defer tx.Rollback(r.Context())
	var closed bool
	if e = tx.QueryRow(r.Context(), `select archived or dissolved_at is not null from chat_group where id=$1 for update`, id).Scan(&closed); e != nil || closed {
		fail(w, 409, "群已归档或解散")
		return
	}
	var roomActive bool
	if e := tx.QueryRow(r.Context(), `select exists(select 1 from chat_group_room where group_id=$1 and state='ACTIVE')`, id).Scan(&roomActive); e != nil || roomActive {
		fail(w, 409, "群内已有多人通话，请先加入或结束")
		return
	}
	var valid bool
	tx.QueryRow(r.Context(), `select exists(select 1 from chat_group_member where group_id=$1 and actor_kind=$2 and actor_id=$3) and exists(select 1 from chat_group_member where group_id=$1 and actor_kind=$4 and actor_id=$5)`, id, in.RecipientKind, in.RecipientID, p.Kind, groupActor(p)).Scan(&valid)
	if !valid {
		fail(w, 404, "通话成员已离开此群")
		return
	}
	var busy bool
	tx.QueryRow(r.Context(), `select exists(select 1 from chat_group_call where group_id=$1 and (state='RINGING' and created_at>now()-interval '60 seconds' or state='ACCEPTED' and updated_at>now()-interval '2 hours') and (caller_kind=$2 and caller_id=$3 or recipient_kind=$2 and recipient_id=$3 or caller_kind=$4 and caller_id=$5 or recipient_kind=$4 and recipient_id=$5))`, id, p.Kind, groupActor(p), in.RecipientKind, in.RecipientID).Scan(&busy)
	if busy {
		fail(w, 409, "你或对方已有通话，请稍后再试")
		return
	}
	raw, _ := json.Marshal(in.Offer)
	call := uuid.New()
	if _, e = tx.Exec(r.Context(), `insert into chat_group_call(id,group_id,caller_kind,caller_id,recipient_kind,recipient_id,offer) values($1,$2,$3,$4,$5,$6,$7)`, call, id, p.Kind, groupActor(p), in.RecipientKind, in.RecipientID, raw); e != nil || tx.Commit(r.Context()) != nil {
		fail(w, 500, "呼叫失败")
		return
	}
	a.groupPublish(r.Context(), id)
	respond(w, 201, map[string]any{"id": call})
}

func (a *API) groupCallAction(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.groupAllowed(r, p, false)
	if !ok {
		fail(w, 404, "你不是群成员")
		return
	}
	call, e := uuid.Parse(r.PathValue("call"))
	if e != nil {
		fail(w, 400, "通话标识不正确")
		return
	}
	var in struct {
		Action string   `json:"action"`
		Answer groupSDP `json:"answer"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Action != "accept" && in.Action != "decline" && in.Action != "end" {
		fail(w, 400, "通话操作不正确")
		return
	}
	tx, e := a.db.Begin(r.Context())
	if e != nil {
		fail(w, 500, "通话操作失败")
		return
	}
	defer tx.Rollback(r.Context())
	// Same lock order as dissolve/start prevents accepting a dissolved group.
	var closed bool
	if e = tx.QueryRow(r.Context(), `select archived or dissolved_at is not null from chat_group where id=$1 for update`, id).Scan(&closed); e != nil {
		fail(w, 404, "群不存在")
		return
	}
	var ck, rk, state string
	var caller, recipient uuid.UUID
	var live bool
	e = tx.QueryRow(r.Context(), `select caller_kind,caller_id,recipient_kind,recipient_id,state,created_at>now()-interval '60 seconds' from chat_group_call where id=$1 and group_id=$2 for update`, call, id).Scan(&ck, &caller, &rk, &recipient, &state, &live)
	isCaller := ck == p.Kind && caller == groupActor(p)
	isRecipient := rk == p.Kind && recipient == groupActor(p)
	if e != nil || !isCaller && !isRecipient {
		fail(w, 404, "通话不存在")
		return
	}
	next := "ENDED"
	var answer any
	if in.Action == "accept" || in.Action == "decline" {
		if !isRecipient {
			fail(w, 403, "只有被呼叫方可以接听或拒接")
			return
		}
		if closed || state != "RINGING" || !live {
			fail(w, 409, "来电已结束或超时")
			return
		}
		next = "DECLINED"
		if in.Action == "accept" {
			if !validGroupSDP(in.Answer, "answer") {
				fail(w, 400, "接听需要有效语音协商信息")
				return
			}
			next = "ACCEPTED"
			raw, _ := json.Marshal(in.Answer)
			answer = raw
		}
	} else if state != "RINGING" && state != "ACCEPTED" {
		respond(w, 200, map[string]any{"ok": true})
		return
	}
	if _, e = tx.Exec(r.Context(), `update chat_group_call set state=$2::varchar(16),answer=$3::jsonb,offer=case when $2::varchar(16)='ACCEPTED' then offer else '{}'::jsonb end,updated_at=now() where id=$1`, call, next, answer); e != nil || tx.Commit(r.Context()) != nil {
		fail(w, 500, "通话操作失败")
		return
	}
	a.groupPublish(r.Context(), id)
	respond(w, 200, map[string]any{"ok": true})
}
