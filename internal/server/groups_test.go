package server

import (
	"context"
	"encoding/json"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/tongyu/tongyu/internal/auth"
	"github.com/tongyu/tongyu/internal/platform/database"
	"github.com/tongyu/tongyu/internal/realtime"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestGroupMembershipIsolationAndIdempotency(t *testing.T) {
	dsn := os.Getenv("TONGYU_TEST_DATABASE")
	if dsn == "" {
		t.Skip("database not configured")
	}
	ctx := context.Background()
	db, e := pgxpool.New(ctx, dsn)
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	if e = database.Migrate(ctx, db); e != nil {
		t.Fatal(e)
	}
	tenant, inbox, owner, other, outsider := uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, e := db.Exec(ctx, q, args...); e != nil {
			t.Fatal(e)
		}
	}
	exec(`insert into tenant(id,name,slug,status) values($1,'groups test',$2,'ACTIVE')`, tenant, tenant.String())
	exec(`insert into tenant_subscription(tenant_id,plan,status) values($1,'GROWTH','ACTIVE')
		on conflict (tenant_id) do update set plan='GROWTH', status='ACTIVE'`, tenant)
	exec(`insert into inbox(id,tenant_id,name,public_key,status) values($1,$2,'test',$3,'ACTIVE')`, inbox, tenant, inbox.String())
	for _, id := range []uuid.UUID{owner, other, outsider} {
		exec(`insert into agent(id,tenant_id,email,display_name,password_hash,role,status) values($1,$2,$3,'test','x','AGENT','ACTIVE')`, id, tenant, id.String())
	}
	exec(`insert into agent_inbox(agent_id,inbox_id) values($1,$2)`, owner, inbox)
	defer func() {
		db.Exec(ctx, `delete from chat_group_invite where group_id in(select id from chat_group where tenant_id=$1)`, tenant)
		db.Exec(ctx, `delete from chat_group_message where group_id in(select id from chat_group where tenant_id=$1)`, tenant)
		db.Exec(ctx, `delete from chat_group_member where group_id in(select id from chat_group where tenant_id=$1)`, tenant)
		db.Exec(ctx, `delete from chat_group where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from visitor where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from agent_inbox where inbox_id=$1`, inbox)
		db.Exec(ctx, `delete from agent where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from inbox where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from tenant_subscription where tenant_id=$1`, tenant)
		db.Exec(ctx, `delete from tenant where id=$1`, tenant)
	}()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	hub := realtime.NewHub(logger)
	a := &API{db: db, bus: realtime.NewBus(db, hub, logger), tokens: auth.NewTokenService("test-group-secret", time.Hour, time.Hour)}
	p := auth.Principal{Kind: auth.KindAgent, TenantID: tenant, AgentID: owner}
	member := auth.Principal{Kind: auth.KindAgent, TenantID: tenant, AgentID: other}
	outside := auth.Principal{Kind: auth.KindAgent, TenantID: tenant, AgentID: outsider}
	var pathMessage, pathCall string
	call := func(fn func(http.ResponseWriter, *http.Request, auth.Principal), p auth.Principal, id uuid.UUID, body any) *httptest.ResponseRecorder {
		t.Helper()
		raw, _ := json.Marshal(body)
		r := httptest.NewRequest("POST", "/", strings.NewReader(string(raw)))
		r.SetPathValue("id", id.String())
		r.SetPathValue("message", pathMessage)
		r.SetPathValue("call", pathCall)
		w := httptest.NewRecorder()
		fn(w, r, p)
		return w
	}
	create := call(a.groupCreate, p, uuid.Nil, map[string]any{"name": "Internal", "kind": "INTERNAL", "agentIds": []uuid.UUID{other}})
	if create.Code != 201 {
		t.Fatalf("create %d %s", create.Code, create.Body.String())
	}
	var g struct {
		ID uuid.UUID `json:"id"`
	}
	json.Unmarshal(create.Body.Bytes(), &g)
	if w := call(a.groupDetail, outside, g.ID, nil); w.Code != 404 {
		t.Fatalf("outsider read %d", w.Code)
	}
	if w := call(a.groupUpdate, member, g.ID, map[string]any{"name": "hijack"}); w.Code != 403 {
		t.Fatalf("nonowner update %d", w.Code)
	}

	session1, session2 := uuid.New(), uuid.New()
	roomCreate := call(a.groupRoomAction, p, g.ID, map[string]any{"action": "create", "sessionId": session1, "mediaKind": "VIDEO"})
	if roomCreate.Code != 200 {
		t.Fatalf("room create %d %s", roomCreate.Code, roomCreate.Body.String())
	}
	var roomResult struct {
		ID uuid.UUID `json:"id"`
	}
	json.Unmarshal(roomCreate.Body.Bytes(), &roomResult)
	roomBody := func(action string, session uuid.UUID) map[string]any {
		return map[string]any{"action": action, "roomId": roomResult.ID, "sessionId": session}
	}
	if w := call(a.groupRoomAction, outside, g.ID, roomBody("join", uuid.New())); w.Code != 404 {
		t.Fatalf("outsider room join %d", w.Code)
	}
	if w := call(a.groupRoomAction, member, g.ID, roomBody("join", session2)); w.Code != 200 {
		t.Fatalf("room join %d %s", w.Code, w.Body.String())
	}
	if w := call(a.groupRoomAction, member, g.ID, roomBody("join", uuid.New())); w.Code != 409 {
		t.Fatalf("duplicate browser %d", w.Code)
	}
	signal := roomBody("signal", session1)
	signal["recipientSession"] = session2
	signal["payload"] = groupSDP{Type: "offer", SDP: "v=0\r\n"}
	if w := call(a.groupRoomAction, p, g.ID, signal); w.Code != 200 {
		t.Fatalf("signal %d %s", w.Code, w.Body.String())
	}
	if w := call(a.groupRooms, member, g.ID, nil); strings.Contains(w.Body.String(), "v=0") {
		t.Fatal("SDP exposed without joined browser session")
	}
	request := httptest.NewRequest("GET", "/?session="+session2.String(), nil)
	request.SetPathValue("id", g.ID.String())
	response := httptest.NewRecorder()
	a.groupRooms(response, request, member)
	if response.Code != 200 || !strings.Contains(response.Body.String(), "v=0") {
		t.Fatalf("receiver missing SDP %d %s", response.Code, response.Body.String())
	}

	// Group lock serializes admission; the seventh live participant is rejected.
	for n := 0; n < 5; n++ {
		visitor := uuid.New()
		extra := auth.Principal{Kind: auth.KindWidget, TenantID: tenant, VisitorID: visitor}
		exec(`insert into chat_group_member(group_id,actor_kind,actor_id,name) values($1,'widget',$2,'capacity test')`, g.ID, visitor)
		sid := uuid.New()
		w := call(a.groupRoomAction, extra, g.ID, roomBody("join", sid))
		expected := 200
		if n == 4 {
			expected = 409
		}
		if w.Code != expected {
			t.Fatalf("capacity member %d got %d %s", n, w.Code, w.Body.String())
		}

	}
	if w := call(a.groupRoomAction, member, g.ID, roomBody("end", session2)); w.Code != 403 {
		t.Fatalf("noncreator room end %d", w.Code)
	}
	exec(`delete from chat_group_room_member where room_id=$1 and actor_kind='widget'`, roomResult.ID)
	exec(`delete from chat_group_member where group_id=$1 and actor_kind='widget'`, g.ID)
	if w := call(a.groupRoomAction, p, g.ID, roomBody("leave", session1)); w.Code != 200 {
		t.Fatalf("room leave %d", w.Code)
	}
	if w := call(a.groupRoomAction, p, g.ID, signal); w.Code != 403 {
		t.Fatalf("left member signal %d", w.Code)
	}
	if w := call(a.groupRoomAction, member, g.ID, roomBody("leave", session2)); w.Code != 200 {
		t.Fatalf("last leave %d", w.Code)
	}
	var roomState string
	db.QueryRow(ctx, `select state from chat_group_room where id=$1`, roomResult.ID).Scan(&roomState)
	if roomState != "ENDED" {
		t.Fatal("empty room remained active")
	}
	if w := call(a.groupInvite, p, g.ID, nil); w.Code != 400 {
		t.Fatalf("internal invitation %d", w.Code)
	}
	payload := map[string]any{"content": "hello group", "clientId": uuid.New()}
	for i := 0; i < 2; i++ {
		w := call(a.groupSend, member, g.ID, payload)
		if w.Code != 201 && w.Code != 200 {
			t.Fatalf("send %d %s", w.Code, w.Body.String())
		}
	}
	var count int
	db.QueryRow(ctx, `select count(*) from chat_group_message where group_id=$1`, g.ID).Scan(&count)
	if count != 1 {
		t.Fatalf("duplicate message count %d", count)
	}
	wrong := p
	wrong.TenantID = uuid.New()
	if w := call(a.groupMessages, wrong, g.ID, nil); w.Code != 404 {
		t.Fatalf("cross tenant %d", w.Code)
	}

	if w := call(a.groupNickname, member, g.ID, map[string]any{"name": ""}); w.Code != 400 {
		t.Fatalf("empty nickname %d", w.Code)
	}
	if w := call(a.groupNickname, member, g.ID, map[string]any{"name": "new nickname"}); w.Code != 200 {
		t.Fatalf("nickname %d", w.Code)
	}
	var nickname string
	db.QueryRow(ctx, `select name from chat_group_member where group_id=$1 and actor_id=$2`, g.ID, other).Scan(&nickname)
	if nickname != "new nickname" {
		t.Fatalf("nickname not persisted %s", nickname)
	}
	var messageID uuid.UUID
	db.QueryRow(ctx, `select id from chat_group_message where group_id=$1`, g.ID).Scan(&messageID)
	pathMessage = messageID.String()
	if w := call(a.groupRecall, p, g.ID, nil); w.Code != 403 {
		t.Fatalf("recall other author %d", w.Code)
	}
	for i := 0; i < 2; i++ {
		if w := call(a.groupRecall, member, g.ID, nil); w.Code != 200 {
			t.Fatalf("recall %d", w.Code)
		}
	}
	history := call(a.groupMessages, p, g.ID, nil)
	if strings.Contains(history.Body.String(), "hello group") || !strings.Contains(history.Body.String(), `"recalled":true`) {
		t.Fatalf("recalled content exposed %s", history.Body.String())
	}
	sdp := map[string]any{"type": "offer", "sdp": "v=0\r\n"}
	startCall := func() uuid.UUID {
		w := call(a.groupCallStart, p, g.ID, map[string]any{"recipientKind": "agent", "recipientId": other, "offer": sdp})
		if w.Code != 201 {
			t.Fatalf("call start %d %s", w.Code, w.Body.String())
		}
		var result struct {
			ID uuid.UUID `json:"id"`
		}
		json.Unmarshal(w.Body.Bytes(), &result)
		pathCall = result.ID.String()
		return result.ID
	}
	startCall()
	if w := call(a.groupCallStart, p, g.ID, map[string]any{"recipientKind": "agent", "recipientId": other, "offer": sdp}); w.Code != 409 {
		t.Fatalf("busy call %d", w.Code)
	}
	answer := map[string]any{"action": "accept", "answer": map[string]any{"type": "answer", "sdp": "v=0\r\n"}}
	if w := call(a.groupCallAction, p, g.ID, answer); w.Code != 403 {
		t.Fatalf("caller accept %d", w.Code)
	}
	if w := call(a.groupCallAction, outside, g.ID, answer); w.Code != 404 {
		t.Fatalf("outsider accept %d", w.Code)
	}
	if w := call(a.groupCallAction, member, g.ID, answer); w.Code != 200 {
		t.Fatalf("callee accept %d %s", w.Code, w.Body.String())
	}
	if w := call(a.groupCallAction, member, g.ID, answer); w.Code != 409 {
		t.Fatalf("duplicate accept %d", w.Code)
	}
	if w := call(a.groupCallAction, p, g.ID, map[string]any{"action": "end"}); w.Code != 200 {
		t.Fatalf("end %d", w.Code)
	}
	signals := call(a.groupCalls, p, g.ID, nil)
	if strings.Contains(signals.Body.String(), `"offer"`) || strings.Contains(signals.Body.String(), `"answer"`) {
		t.Fatalf("ended call leaks SDP %s", signals.Body.String())
	}
	startCall()
	if w := call(a.groupCallAction, member, g.ID, map[string]any{"action": "decline"}); w.Code != 200 {
		t.Fatalf("decline %d", w.Code)
	}
	missed := startCall()
	exec(`update chat_group_call set created_at=now()-interval '61 seconds' where id=$1`, missed)
	if w := call(a.groupCalls, p, g.ID, nil); !strings.Contains(w.Body.String(), "MISSED") {
		t.Fatalf("missed call %s", w.Body.String())
	}
	if w := call(a.groupCallAction, member, g.ID, answer); w.Code != 409 {
		t.Fatalf("expired accept %d", w.Code)
	}
	// A third member must not receive either participant's SDP.
	if w := call(a.groupAdd, p, g.ID, map[string]any{"agentId": outsider}); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	live := startCall()
	if w := call(a.groupCalls, outside, g.ID, nil); strings.Contains(w.Body.String(), live.String()) {
		t.Fatalf("SDP leaks to third member %s", w.Body.String())
	}
	if w := call(a.groupDissolve, member, g.ID, nil); w.Code != 403 {
		t.Fatalf("nonowner dissolve %d", w.Code)
	}
	if w := call(a.groupDissolve, p, g.ID, nil); w.Code != 200 {
		t.Fatalf("dissolve %d", w.Code)
	}
	var liveState string
	db.QueryRow(ctx, `select state from chat_group_call where id=$1`, live).Scan(&liveState)
	if liveState != "ENDED" {
		t.Fatalf("dissolve left call live %s", liveState)
	}
	if w := call(a.groupNickname, member, g.ID, map[string]any{"name": "closed"}); w.Code != 409 {
		t.Fatalf("closed nickname %d", w.Code)
	}
	if w := call(a.groupUpdate, p, g.ID, map[string]any{"name": "revive"}); w.Code != 409 {
		t.Fatalf("revive dissolved %d", w.Code)
	}
	if w := call(a.groupCallStart, p, g.ID, map[string]any{"recipientKind": "agent", "recipientId": other, "offer": sdp}); w.Code != 409 {
		t.Fatalf("closed call %d", w.Code)
	}
	// Use a new group for the existing archive checks.
	created := call(a.groupCreate, p, uuid.Nil, map[string]any{"name": "archive test", "kind": "INTERNAL", "agentIds": []uuid.UUID{other}})
	json.Unmarshal(created.Body.Bytes(), &g)

	exec(`delete from chat_group_member where group_id=$1 and actor_id=$2`, g.ID, other)
	if w := call(a.groupSend, member, g.ID, map[string]any{"content": "removed", "clientId": uuid.New()}); w.Code != 404 {
		t.Fatalf("removed member send %d", w.Code)
	}
	w := call(a.groupUpdate, p, g.ID, map[string]any{"name": "archived", "archived": true})
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	if w := call(a.groupSend, p, g.ID, map[string]any{"content": "closed", "clientId": uuid.New()}); w.Code != 409 {
		t.Fatalf("archived send %d", w.Code)
	}
	service := call(a.groupCreate, p, uuid.Nil, map[string]any{"name": "service", "kind": "SERVICE", "inboxId": inbox.String()})
	if service.Code != 201 {
		t.Fatalf("service create %s", service.Body.String())
	}
	json.Unmarshal(service.Body.Bytes(), &g)
	invitation := call(a.groupInvite, p, g.ID, nil)
	var link struct {
		URL string `json:"url"`
	}
	json.Unmarshal(invitation.Body.Bytes(), &link)
	ticket := strings.TrimPrefix(link.URL, "/groups.html?invite=")
	join := func() *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "/", strings.NewReader(`{"name":"customer"}`))
		r.SetPathValue("ticket", ticket)
		w := httptest.NewRecorder()
		a.groupJoin(w, r)
		return w
	}
	joined := join()
	if joined.Code != 201 {
		t.Fatalf("customer join %d %s", joined.Code, joined.Body.String())
	}
	var guest struct {
		Token string `json:"token"`
	}
	json.Unmarshal(joined.Body.Bytes(), &guest)
	visitor, e := a.tokens.Verify(guest.Token)
	if e != nil {
		t.Fatal(e)
	}
	if w := call(a.groupNickname, visitor, g.ID, map[string]any{"name": "customer new"}); w.Code != 200 {
		t.Fatalf("customer nickname %d", w.Code)
	}

	serviceSession := uuid.New()
	liveRoom := call(a.groupRoomAction, p, g.ID, map[string]any{"action": "create", "sessionId": serviceSession, "mediaKind": "AUDIO"})
	if liveRoom.Code != 200 {
		t.Fatalf("service room %d %s", liveRoom.Code, liveRoom.Body.String())
	}
	json.Unmarshal(liveRoom.Body.Bytes(), &roomResult)
	visitorSession := uuid.New()
	if w := call(a.groupRoomAction, visitor, g.ID, roomBody("join", visitorSession)); w.Code != 200 {
		t.Fatalf("customer room join %d", w.Code)
	}
	signal = roomBody("signal", serviceSession)
	signal["recipientSession"] = visitorSession
	signal["payload"] = groupSDP{Type: "offer", SDP: "v=0\r\n"}
	if w := call(a.groupRoomAction, p, g.ID, signal); w.Code != 200 {
		t.Fatalf("service signal %d", w.Code)
	}
	if w := call(a.groupDissolve, p, g.ID, nil); w.Code != 200 {
		t.Fatalf("service dissolve %d", w.Code)
	}
	db.QueryRow(ctx, `select state from chat_group_room where id=$1`, roomResult.ID).Scan(&roomState)
	if roomState != "ENDED" {
		t.Fatal("dissolve left room active")
	}
	var signalsRemaining int
	db.QueryRow(ctx, `select count(*) from chat_group_room_signal where room_id=$1`, roomResult.ID).Scan(&signalsRemaining)
	if signalsRemaining != 0 {
		t.Fatal("dissolve retained private SDP")
	}
	if w := join(); w.Code != 404 {
		t.Fatalf("dissolved invite usable %d", w.Code)
	}
	if w := call(a.groupInvite, p, g.ID, nil); w.Code != 400 {
		t.Fatalf("dissolved new invite %d", w.Code)
	}
	if w := call(a.groupSend, visitor, g.ID, map[string]any{"content": "closed", "clientId": uuid.New()}); w.Code != 409 {
		t.Fatalf("dissolved customer send %d", w.Code)
	}

}
