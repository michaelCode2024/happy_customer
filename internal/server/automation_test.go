package server

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/tongyu/tongyu/internal/auth"
	"github.com/tongyu/tongyu/internal/platform/database"
	"github.com/tongyu/tongyu/internal/realtime"
	"github.com/tongyu/tongyu/internal/webhook"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestAutomationPrecedenceAndHandoff(t *testing.T) {
	c := defaultAutomation()
	c.Enabled = true
	c.CooldownSeconds = 0
	c.OfflineReply = "offline"
	c.ReceivedReply = "received"
	c.SystemReply = "system"
	c.KeywordRules = []automationRule{{ID: "low", Keywords: []string{"退款"}, MatchMode: "CONTAINS", Reply: "low", Enabled: true, Priority: 1}, {ID: "high", Keywords: []string{"退款"}, MatchMode: "EXACT", Reply: "high", Enabled: true, Priority: 9}}
	cases := []struct {
		content                  string
		assigned, paused, online bool
		reply, rule              string
		handoff                  bool
	}{{"退款", false, false, true, "high", "keyword:high", false}, {"我要退款", false, false, false, "low", "keyword:low", false}, {"其他", false, false, false, "offline", "offline", false}, {"其他", false, false, true, "received", "received", false}, {"退款", true, false, true, "", "", false}, {"退款", false, true, false, "", "", false}, {"请转人工", true, false, true, c.HandoffMessage, "handoff", true}}
	for _, tc := range cases {
		reply, rule, handoff := automationAnswer(c, messageView{MessageType: "TEXT", Content: tc.content}, tc.assigned, tc.paused, tc.online)
		if reply != tc.reply || rule != tc.rule || handoff != tc.handoff {
			t.Errorf("%+v got %q %q %v", tc, reply, rule, handoff)
		}
	}
	c.MenuItems = []channelItem{{ID: "menu", Title: "服务时间", Action: "REPLY", Value: "9:00–18:00"}}
	raw, _ := json.Marshal(map[string]string{"menuId": "menu"})
	reply, _, _ := automationAnswer(c, messageView{Content: "服务时间", Metadata: raw}, true, true, true)
	if reply != "9:00–18:00" {
		t.Fatal("explicit menu ignored")
	}
	// 后台把标题改成「营业时间」后，访客手里的旧按钮内容仍是旧标题，
	// 必须继续按 id 命中，否则点下去变成哑弹。
	c.MenuItems[0].Title = "营业时间"
	reply, _, _ = automationAnswer(c, messageView{Content: "服务时间", Metadata: raw, MessageType: "TEXT"}, true, true, true)
	if reply != "9:00–18:00" {
		t.Fatal("renamed menu broke stale button")
	}
	// 但客户端不能凭空指定一个不存在的菜单动作。
	forged, _ := json.Marshal(map[string]string{"menuId": "not-exist"})
	reply, _, _ = automationAnswer(c, messageView{Content: "服务时间", Metadata: forged, MessageType: "TEXT"}, true, true, true)
	if reply != "" {
		t.Fatal("unknown menu id accepted")
	}
	c.Enabled = false
	reply, _, _ = automationAnswer(c, messageView{Content: "退款", MessageType: "TEXT"}, false, false, true)
	if reply != "" {
		t.Fatal("disabled bot replied")
	}
	// 转人工是交接动作而不是机器人话术，关掉自动回复也应该生效。
	reply, rule, handoff := automationAnswer(c, messageView{Content: "请转人工", MessageType: "TEXT"}, false, false, true)
	if reply != c.HandoffMessage || rule != "handoff" || !handoff {
		t.Fatalf("disabled automation dropped handoff keyword: %q %q %v", reply, rule, handoff)
	}
}

// 系统兜底只在对应场景没填文案时补位，不能被「收到消息回复」整段遮蔽。
func TestAutomationSystemReplyFillsMissingCopy(t *testing.T) {
	c := defaultAutomation()
	c.Enabled = true
	c.SystemReply = "系统兜底"
	c.ReceivedReply = "收到你的消息"
	if reply, rule, _ := automationAnswer(c, messageView{MessageType: "TEXT", Content: "问题"}, false, false, false); reply != "系统兜底" || rule != "system" {
		t.Fatalf("offline without offline reply should use system fallback: %q %q", reply, rule)
	}
	if reply, rule, _ := automationAnswer(c, messageView{MessageType: "TEXT", Content: "问题"}, false, false, true); reply != "收到你的消息" || rule != "received" {
		t.Fatalf("online should keep received reply: %q %q", reply, rule)
	}
	c.ReceivedReply = ""
	if reply, rule, _ := automationAnswer(c, messageView{MessageType: "TEXT", Content: "问题"}, false, false, true); reply != "系统兜底" || rule != "system" {
		t.Fatalf("online without received reply should use system fallback: %q %q", reply, rule)
	}
	c.OfflineReply = "离线专属"
	if reply, rule, _ := automationAnswer(c, messageView{MessageType: "TEXT", Content: "问题"}, false, false, false); reply != "离线专属" || rule != "offline" {
		t.Fatalf("offline reply must win over system fallback: %q %q", reply, rule)
	}
}
func TestAutomationRejectsUnsafeAndAmbiguousMenu(t *testing.T) {
	c := defaultAutomation()
	c.MenuItems = []channelItem{{ID: "menu", Title: "link", Action: "LINK", Value: "javascript:alert(1)"}}
	if validateAutomation(c) == nil {
		t.Fatal("unsafe URL accepted")
	}
	c.MenuItems[0].Value = "https://example.com/help"
	if validateAutomation(c) != nil {
		t.Fatal("safe link rejected")
	}
	c.QuickLinks = []channelItem{c.MenuItems[0]}
	if validateAutomation(c) == nil {
		t.Fatal("duplicate action id accepted")
	}
	c.QuickLinks = nil
	c.CooldownSeconds = -1
	if validateAutomation(c) == nil {
		t.Fatal("invalid cooldown accepted")
	}
}

func TestAutomationDatabaseDelivery(t *testing.T) {
	dsn := os.Getenv("TONGYU_TEST_DATABASE")
	if dsn == "" {
		t.Skip("database not configured")
	}
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err = database.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	tenant, inbox, visitor, conversation := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	defer func() {
		for _, table := range []string{"message", "conversation", "visitor", "inbox", "tenant"} {
			col := "tenant_id"
			if table == "tenant" {
				col = "id"
			}
			_, _ = pool.Exec(ctx, "delete from "+table+" where "+col+"=$1", tenant)
		}
	}()
	run := func(sql string, args ...any) {
		t.Helper()
		if _, e := pool.Exec(ctx, sql, args...); e != nil {
			t.Fatal(e)
		}
	}
	run(`insert into tenant(id,name,slug,status) values($1,'automation test',$2,'ACTIVE')`, tenant, tenant.String())
	run(`insert into tenant_subscription(tenant_id,plan,status) values($1,'GROWTH','ACTIVE')`, tenant)
	run(`insert into inbox(id,tenant_id,name,public_key,status) values($1,$2,'automation',$3,'ACTIVE')`, inbox, tenant, inbox.String())
	run(`insert into visitor(id,tenant_id,inbox_id) values($1,$2,$3)`, visitor, tenant, inbox)
	run(`insert into conversation(id,tenant_id,inbox_id,visitor_id,status) values($1,$2,$3,$4,'OPEN')`, conversation, tenant, inbox, visitor)
	a := &API{db: pool, logger: slog.Default(), bus: realtime.NewBus(pool, realtime.NewHub(slog.Default()), slog.Default()), webhooks: webhook.NewDispatcher(pool, 3, slog.Default())}
	c := defaultAutomation()
	c.Enabled = true
	c.CooldownSeconds = 3600
	c.ReceivedReply = "收到你的咨询"
	c.HandoffMessage = "自定义转接提示"
	raw, _ := json.Marshal(c)
	run(`insert into inbox_automation(inbox_id,tenant_id,config) values($1,$2,$3)`, inbox, tenant, raw)
	if len(a.publicAutomation(ctx, inbox)) == 0 {
		t.Fatal("growth presentation missing")
	}
	run(`update tenant_subscription set plan='TRIAL' where tenant_id=$1`, tenant)
	if len(a.publicAutomation(ctx, inbox)) != 0 {
		t.Fatal("downgraded presentation leaked")
	}
	run(`update tenant_subscription set plan='GROWTH' where tenant_id=$1`, tenant)
	q := messageView{ID: uuid.New(), MessageType: "TEXT", Content: "问题"}
	if !a.maybeAutomationReply(ctx, tenant, conversation, q) {
		t.Fatal("automation not handled")
	}
	a.maybeAutomationReply(ctx, tenant, conversation, q)
	q.ID = uuid.New()
	a.maybeAutomationReply(ctx, tenant, conversation, q)
	var count int
	pool.QueryRow(ctx, `select count(*) from message where conversation_id=$1`, conversation).Scan(&count)
	if count != 1 {
		t.Fatalf("cooldown/duplicate replies: %d", count)
	}
	q.ID = uuid.New()
	q.Content = "转人工"
	a.maybeAutomationReply(ctx, tenant, conversation, q)
	var paused bool
	pool.QueryRow(ctx, `select bot_paused from conversation where id=$1`, conversation).Scan(&paused)
	if !paused {
		t.Fatal("handoff did not pause bot")
	}
	// 配置的转人工提示必须就是访客看到的那条转接通知，不能退化成固定文案。
	var transferNotice string
	if err := pool.QueryRow(ctx, `select content from message where conversation_id=$1 and metadata->>'receptionState'='TRANSFERRING' order by sequence limit 1`, conversation).Scan(&transferNotice); err != nil {
		t.Fatalf("transferring notice missing: %v", err)
	}
	if transferNotice != c.HandoffMessage {
		t.Fatalf("configured handoff notice not delivered: %q", transferNotice)
	}
	pool.QueryRow(ctx, `select count(*) from message where conversation_id=$1`, conversation).Scan(&count)
	if count != 3 {
		t.Fatal("handoff incorrectly blocked by cooldown")
	}
	q.ID = uuid.New()
	q.Content = "问题"
	a.maybeAutomationReply(ctx, tenant, conversation, q)
	pool.QueryRow(ctx, `select count(*) from message where conversation_id=$1`, conversation).Scan(&count)
	if count != 3 {
		t.Fatal("bot replied after handoff")
	}
	// 已交接后再次点转人工必须有回执，不能静默结束。
	agentID := uuid.New()
	run(`insert into agent(id,tenant_id,email,display_name,role,status,password_hash) values($1,$2,'handoff@test.local','测试客服','AGENT','ACTIVE','x')`, agentID, tenant)
	run(`insert into agent_inbox(agent_id,inbox_id) values($1,$2)`, agentID, inbox)
	run(`insert into agent_presence(agent_id,status,last_seen_at) values($1,'ONLINE',now()) on conflict(agent_id) do update set status='ONLINE', last_seen_at=now()`, agentID)
	run(`update conversation set assignee_id=$1, assigned_at=now(),accepted_at=now() where id=$2`, agentID, conversation)
	q.ID = uuid.New()
	q.Content = "转人工"
	a.maybeAutomationReply(ctx, tenant, conversation, q)
	var activeReply string
	pool.QueryRow(ctx, `select content from message where conversation_id=$1 order by sequence desc limit 1`, conversation).Scan(&activeReply)
	if !strings.Contains(activeReply, "已在接待中") {
		t.Fatalf("repeat handoff should confirm active agent, got %q", activeReply)
	}
	// 即使异步匹配早已完成，落库时发现人工接管也不能再发送普通自动回复。
	if _, err := a.appendMessage(ctx, tenant, conversation, messageInput{SenderType: "SYSTEM", MessageType: "TEXT", Content: "stale bot reply", AutomationOnly: true, AutomationRespectAgent: true}); err == nil {
		t.Fatal("stale automation persisted after handoff")
	}
	createBody, _ := json.Marshal(map[string]any{"name": "空域名入口", "publicKey": uuid.NewString()})
	createRequest := httptest.NewRequest("POST", "/", bytes.NewReader(createBody))
	createRecorder := httptest.NewRecorder()
	a.adminCreateInbox(createRecorder, createRequest, auth.Principal{TenantID: tenant})
	if createRecorder.Code != 201 {
		t.Fatalf("create without domains: %d %s", createRecorder.Code, createRecorder.Body)
	}
	validMessagesRequest := httptest.NewRequest("GET", "/", nil)
	validMessagesRequest.SetPathValue("id", inbox.String())
	validMessagesRequest.SetPathValue("conversationId", conversation.String())
	validRecorder := httptest.NewRecorder()
	a.adminChannelMessages(validRecorder, validMessagesRequest, auth.Principal{TenantID: tenant})
	if validRecorder.Code != 200 {
		t.Fatalf("admin message history: %d %s", validRecorder.Code, validRecorder.Body)
	}
	var createdInbox map[string]any
	_ = json.Unmarshal(createRecorder.Body.Bytes(), &createdInbox)
	wrongInboxRequest := httptest.NewRequest("GET", "/", nil)
	wrongInboxRequest.SetPathValue("id", createdInbox["id"].(string))
	wrongInboxRequest.SetPathValue("conversationId", conversation.String())
	wrongRecorder := httptest.NewRecorder()
	a.adminChannelMessages(wrongRecorder, wrongInboxRequest, auth.Principal{TenantID: tenant})
	if wrongRecorder.Code != 404 {
		t.Fatal("conversation can be read through another inbox")
	}
	// 配置版本冲突必须返回 409，其他租户不能读取该入口。
	body, _ := json.Marshal(map[string]any{"config": c, "revision": 0})
	r := httptest.NewRequest("PUT", "/", bytes.NewReader(body))
	r.SetPathValue("id", inbox.String())
	w := httptest.NewRecorder()
	a.adminAutomation(w, r, auth.Principal{TenantID: tenant})
	if w.Code != 409 {
		t.Fatalf("stale save: %d %s", w.Code, w.Body)
	}
	r = httptest.NewRequest("GET", "/", nil)
	r.SetPathValue("id", inbox.String())
	w = httptest.NewRecorder()
	a.adminAutomation(w, r, auth.Principal{TenantID: uuid.New()})
	if w.Code != 404 {
		t.Fatal("cross tenant access allowed")
	}
}
