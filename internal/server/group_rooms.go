package server

import (
	"context"
	"encoding/json"
	"github.com/jackc/pgx/v5"
	"net/http"
	"os"
	"strconv"

	"github.com/google/uuid"
	"github.com/relaydesk/relaydesk/internal/auth"
)

// All room mutations lock the group first, matching membership and dissolve.
// SDP is only returned to its addressed, currently joined browser session.
func (a *API) groupRooms(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	gid, ok := a.groupAllowed(r, p, false)
	if !ok {
		fail(w, 404, "你不是群成员")
		return
	}
	tx, e := a.db.Begin(r.Context())
	if e != nil {
		fail(w, 500, "读取通话失败")
		return
	}
	defer tx.Rollback(r.Context())
	var closed bool
	if e = tx.QueryRow(r.Context(), `select archived or dissolved_at is not null from chat_group where id=$1 for update`, gid).Scan(&closed); e != nil {
		fail(w, 500, "读取通话失败")
		return
	}
	var stillMember bool
	if e = tx.QueryRow(r.Context(), `select exists(select 1 from chat_group_member where group_id=$1 and actor_kind=$2 and actor_id=$3)`, gid, p.Kind, groupActor(p)).Scan(&stillMember); e != nil || !stillMember {
		fail(w, 404, "你已离开群聊")
		return
	}
	_, e = tx.Exec(r.Context(), `delete from chat_group_room_member m using chat_group_room c where c.id=m.room_id and c.group_id=$1 and (m.seen_at<now()-interval '45 seconds' or not exists(select 1 from chat_group_member g where g.group_id=$1 and g.actor_kind=m.actor_kind and g.actor_id=m.actor_id))`, gid)
	if e != nil {
		fail(w, 500, "读取成员失败")
		return
	}
	_, e = tx.Exec(r.Context(), `update chat_group_room c set state='ENDED' where group_id=$1 and state='ACTIVE' and ($2 or not exists(select 1 from chat_group_room_member m where m.room_id=c.id))`, gid, closed)
	if e != nil {
		fail(w, 500, "读取通话失败")
		return
	}
	_, e = tx.Exec(r.Context(), `delete from chat_group_room_signal s using chat_group_room c where c.id=s.room_id and c.group_id=$1 and (c.state='ENDED' or s.created_at<now()-interval '2 minutes')`, gid)
	if e != nil {
		fail(w, 500, "读取通话失败")
		return
	}
	var rid, creator uuid.UUID
	var kind, ck string
	e = tx.QueryRow(r.Context(), `select id,media_kind,creator_kind,creator_id from chat_group_room where group_id=$1 and state='ACTIVE'`, gid).Scan(&rid, &kind, &ck, &creator)
	ice := []any{}
	if raw := os.Getenv("RELAYDESK_RTC_ICE_SERVERS"); raw != "" {
		json.Unmarshal([]byte(raw), &ice)
	}
	if e != nil {
		if e != pgx.ErrNoRows {
			fail(w, 500, "读取通话失败")
			return
		}
		if tx.Commit(r.Context()) != nil {
			fail(w, 500, "读取通话失败")
			return
		}
		respond(w, 200, map[string]any{"room": nil, "iceServers": ice})
		return
	}
	rows, e := tx.Query(r.Context(), `select m.actor_kind,m.actor_id,m.session_id,g.name,m.muted,m.camera from chat_group_room_member m join chat_group_member g on g.group_id=$2 and g.actor_kind=m.actor_kind and g.actor_id=m.actor_id where m.room_id=$1 order by m.session_id`, rid, gid)
	if e != nil {
		fail(w, 500, "读取成员失败")
		return
	}
	members := []map[string]any{}
	var mySession uuid.UUID
	for rows.Next() {
		var k, name string
		var id, sid uuid.UUID
		var muted, camera bool
		if rows.Scan(&k, &id, &sid, &name, &muted, &camera) != nil {
			rows.Close()
			fail(w, 500, "读取成员失败")
			return
		}
		members = append(members, map[string]any{"kind": k, "id": id, "sessionId": sid, "name": name, "muted": muted, "camera": camera})
		if k == p.Kind && id == groupActor(p) {
			mySession = sid
		}
	}
	rows.Close()
	if rows.Err() != nil {
		fail(w, 500, "读取成员失败")
		return
	}
	signals := []map[string]any{}
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	// Require the caller's current browser session, not merely actor identity.
	if mySession != uuid.Nil && r.URL.Query().Get("session") == mySession.String() {
		rows, e = tx.Query(r.Context(), `select s.id,s.sender_session,s.payload from chat_group_room_signal s where s.room_id=$1 and s.recipient_session=$2 and s.id>$3 and exists(select 1 from chat_group_room_member m where m.room_id=$1 and m.session_id=s.sender_session) order by s.id limit 100`, rid, mySession, after)
		if e != nil {
			fail(w, 500, "读取协商失败")
			return
		}
		for rows.Next() {
			var id int64
			var sender uuid.UUID
			var payload []byte
			if rows.Scan(&id, &sender, &payload) != nil {
				rows.Close()
				fail(w, 500, "读取协商失败")
				return
			}
			signals = append(signals, map[string]any{"id": id, "senderSession": sender, "payload": json.RawMessage(payload)})
		}
		rows.Close()
		if rows.Err() != nil {
			fail(w, 500, "读取协商失败")
			return
		}
	}
	if tx.Commit(r.Context()) != nil {
		fail(w, 500, "读取通话失败")
		return
	}
	respond(w, 200, map[string]any{"room": map[string]any{"id": rid, "mediaKind": kind, "creatorKind": ck, "creatorId": creator, "members": members}, "signals": signals, "iceServers": ice, "maxParticipants": 6})
}

func (a *API) groupRoomAction(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	gid, ok := a.groupAllowed(r, p, false)
	if !ok {
		fail(w, 404, "你不是群成员")
		return
	}
	var in struct {
		Action    string    `json:"action"`
		RoomID    uuid.UUID `json:"roomId"`
		SessionID uuid.UUID `json:"sessionId"`
		MediaKind string    `json:"mediaKind"`
		Recipient uuid.UUID `json:"recipientSession"`
		Payload   groupSDP  `json:"payload"`
		Muted     bool      `json:"muted"`
		Camera    bool      `json:"camera"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.SessionID == uuid.Nil {
		fail(w, 400, "缺少浏览器会话标识")
		return
	}
	if in.Action == "create" && (in.MediaKind != "AUDIO" && in.MediaKind != "VIDEO") {
		fail(w, 400, "请选择语音或视频通话")
		return
	}
	if in.Action == "signal" && (!validGroupSDP(in.Payload, "offer") && !validGroupSDP(in.Payload, "answer")) {
		fail(w, 400, "协商信息不正确")
		return
	}
	tx, e := a.db.Begin(r.Context())
	if e != nil {
		fail(w, 500, "操作失败")
		return
	}
	defer tx.Rollback(r.Context())
	var closed bool
	var owner uuid.UUID
	if e = tx.QueryRow(r.Context(), `select archived or dissolved_at is not null,owner_id from chat_group where id=$1 for update`, gid).Scan(&closed, &owner); e != nil || closed {
		fail(w, 409, "群已归档或解散")
		return
	}
	var member bool
	if e = tx.QueryRow(r.Context(), `select exists(select 1 from chat_group_member where group_id=$1 and actor_kind=$2 and actor_id=$3)`, gid, p.Kind, groupActor(p)).Scan(&member); e != nil || !member {
		fail(w, 403, "你已离开群聊")
		return
	}
	_, e = tx.Exec(r.Context(), `delete from chat_group_room_member m using chat_group_room c where c.id=m.room_id and c.group_id=$1 and m.seen_at<now()-interval '45 seconds'`, gid)
	if e != nil {
		fail(w, 500, "操作失败")
		return
	}
	_, e = tx.Exec(r.Context(), `update chat_group_room c set state='ENDED' where group_id=$1 and state='ACTIVE' and not exists(select 1 from chat_group_room_member m where m.room_id=c.id)`, gid)
	if e != nil {
		fail(w, 500, "操作失败")
		return
	}
	if in.Action == "create" {
		var busy bool
		if e = tx.QueryRow(r.Context(), `select exists(select 1 from chat_group_room where group_id=$1 and state='ACTIVE') or exists(select 1 from chat_group_call where group_id=$1 and (state='RINGING' and created_at>now()-interval '60 seconds' or state='ACCEPTED' and updated_at>now()-interval '2 hours'))`, gid).Scan(&busy); e != nil || busy {
			fail(w, 409, "群内已有通话，请加入或结束后再发起")
			return
		}
		in.RoomID = uuid.New()
		_, e = tx.Exec(r.Context(), `insert into chat_group_room(id,group_id,media_kind,creator_kind,creator_id) values($1,$2,$3,$4,$5)`, in.RoomID, gid, in.MediaKind, p.Kind, groupActor(p))
		if e != nil {
			fail(w, 500, "发起失败")
			return
		}
	}
	var ck, kind string
	var creator uuid.UUID
	if e = tx.QueryRow(r.Context(), `select creator_kind,creator_id,media_kind from chat_group_room where id=$1 and group_id=$2 and state='ACTIVE'`, in.RoomID, gid).Scan(&ck, &creator, &kind); e != nil {
		fail(w, 409, "通话已结束")
		return
	}
	var joined bool
	if e = tx.QueryRow(r.Context(), `select exists(select 1 from chat_group_room_member where room_id=$1 and actor_kind=$2 and actor_id=$3 and session_id=$4)`, in.RoomID, p.Kind, groupActor(p), in.SessionID).Scan(&joined); e != nil {
		fail(w, 500, "操作失败")
		return
	}
	switch in.Action {
	case "create", "join":
		var count int
		var another bool
		if e = tx.QueryRow(r.Context(), `select count(*),coalesce(bool_or(actor_kind=$2 and actor_id=$3 and session_id<>$4),false) from chat_group_room_member where room_id=$1`, in.RoomID, p.Kind, groupActor(p), in.SessionID).Scan(&count, &another); e != nil {
			fail(w, 500, "加入失败")
			return
		}
		if another {
			fail(w, 409, "此账号已在其他页面加入，请先退出")
			return
		}
		if count >= 6 && !joined {
			fail(w, 409, "通话最多支持6人")
			return
		}
		_, e = tx.Exec(r.Context(), `insert into chat_group_room_member(room_id,actor_kind,actor_id,session_id,camera) values($1,$2,$3,$4,$5) on conflict(room_id,actor_kind,actor_id) do update set seen_at=now()`, in.RoomID, p.Kind, groupActor(p), in.SessionID, kind == "VIDEO" && in.Camera)
	case "heartbeat":
		if !joined {
			fail(w, 403, "你未加入或会话已失效")
			return
		}
		_, e = tx.Exec(r.Context(), `update chat_group_room_member set seen_at=now(),muted=$5,camera=$6 where room_id=$1 and actor_kind=$2 and actor_id=$3 and session_id=$4`, in.RoomID, p.Kind, groupActor(p), in.SessionID, in.Muted, kind == "VIDEO" && in.Camera)
	case "signal":
		if !joined {
			fail(w, 403, "请先加入通话")
			return
		}
		var receiver bool
		if e = tx.QueryRow(r.Context(), `select exists(select 1 from chat_group_room_member where room_id=$1 and session_id=$2 and session_id<>$3)`, in.RoomID, in.Recipient, in.SessionID).Scan(&receiver); e != nil || !receiver {
			fail(w, 409, "对方已退出通话")
			return
		}
		// One offer and answer per live pair; retry replaces the same description.
		_, e = tx.Exec(r.Context(), `delete from chat_group_room_signal where room_id=$1 and sender_session=$2 and recipient_session=$3`, in.RoomID, in.SessionID, in.Recipient)
		if e != nil {
			fail(w, 500, "协商失败")
			return
		}
		payload, _ := json.Marshal(in.Payload)
		_, e = tx.Exec(r.Context(), `insert into chat_group_room_signal(room_id,sender_session,recipient_session,payload) values($1,$2,$3,$4)`, in.RoomID, in.SessionID, in.Recipient, payload)
	case "leave":
		if !joined {
			fail(w, 403, "你未加入通话")
			return
		}
		_, e = tx.Exec(r.Context(), `delete from chat_group_room_member where room_id=$1 and actor_kind=$2 and actor_id=$3 and session_id=$4`, in.RoomID, p.Kind, groupActor(p), in.SessionID)
	case "end":
		if !(ck == p.Kind && creator == groupActor(p)) && !(p.Kind == "agent" && owner == groupActor(p)) {
			fail(w, 403, "仅发起人或群主可结束所有人的通话")
			return
		}
		_, e = tx.Exec(r.Context(), `update chat_group_room set state='ENDED' where id=$1`, in.RoomID)
	default:
		fail(w, 400, "操作不正确")
		return
	}
	if e != nil {
		fail(w, 500, "通话操作失败")
		return
	}
	_, e = tx.Exec(r.Context(), `update chat_group_room c set state='ENDED' where id=$1 and not exists(select 1 from chat_group_room_member m where m.room_id=c.id)`, in.RoomID)
	if e != nil {
		fail(w, 500, "结束失败")
		return
	}
	_, e = tx.Exec(r.Context(), `delete from chat_group_room_signal s using chat_group_room c where c.id=s.room_id and c.id=$1 and (c.state='ENDED' or not exists(select 1 from chat_group_room_member m where m.room_id=c.id and m.session_id=s.sender_session) or not exists(select 1 from chat_group_room_member m where m.room_id=c.id and m.session_id=s.recipient_session))`, in.RoomID)
	if e != nil {
		fail(w, 500, "结束失败")
		return
	}
	if tx.Commit(r.Context()) != nil {
		fail(w, 500, "操作失败")
		return
	}
	if in.Action != "heartbeat" && in.Action != "signal" {
		a.groupPublish(r.Context(), gid)
	}
	respond(w, 200, map[string]any{"id": in.RoomID, "ok": true})
}

func pruneGroupRooms(ctx context.Context, tx pgx.Tx, gid uuid.UUID) error {
	if _, e := tx.Exec(ctx, `delete from chat_group_room_member m using chat_group_room c where c.id=m.room_id and c.group_id=$1 and not exists(select 1 from chat_group_member g where g.group_id=$1 and g.actor_kind=m.actor_kind and g.actor_id=m.actor_id)`, gid); e != nil {
		return e
	}
	if _, e := tx.Exec(ctx, `update chat_group_room c set state='ENDED' where group_id=$1 and state='ACTIVE' and (exists(select 1 from chat_group g where g.id=$1 and (g.archived or g.dissolved_at is not null)) or not exists(select 1 from chat_group_room_member m where m.room_id=c.id))`, gid); e != nil {
		return e
	}
	_, e := tx.Exec(ctx, `delete from chat_group_room_signal s using chat_group_room c where c.id=s.room_id and c.group_id=$1 and (c.state='ENDED' or not exists(select 1 from chat_group_room_member m where m.room_id=c.id and m.session_id=s.sender_session) or not exists(select 1 from chat_group_room_member m where m.room_id=c.id and m.session_id=s.recipient_session))`, gid)
	return e
}
