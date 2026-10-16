package server

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/tongyu/tongyu/internal/auth"
)

func (a *API) registerNotifications(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/console/notifications", a.requireAgent(a.notifications))
	mux.HandleFunc("POST /api/v1/console/notifications/read", a.requireAgent(a.readNotifications))
	mux.HandleFunc("POST /api/v1/console/notifications/quiet", a.requireAgent(a.quietNotifications))
	mux.HandleFunc("GET /api/v1/console/push/key", a.requireAgent(a.pushKey))
	mux.HandleFunc("POST /api/v1/console/push/subscription/status", a.requireAgent(a.pushSubscriptionStatus))
	mux.HandleFunc("PUT /api/v1/console/push/subscription", a.requireAgent(a.subscribePush))
	mux.HandleFunc("DELETE /api/v1/console/push/subscription", a.requireAgent(a.unsubscribePush))
}

// 通知收件人沿用工作台入口权限；不广播到其他企业或无入口权限的坐席。
func enqueueMessageNotifications(ctx context.Context, tx pgx.Tx, tenantID, conversationID, messageID uuid.UUID) error {
	_, err := tx.Exec(ctx, `with inserted as (
 insert into agent_notification(tenant_id,agent_id,conversation_id,message_id,title)
 select c.tenant_id,ag.id,c.id,$3,coalesce(nullif(v.display_name,''),'客户') || ' 发来了新消息'
 from conversation c join visitor v on v.id=c.visitor_id
 join agent_inbox ai on ai.inbox_id=c.inbox_id
 join agent ag on ag.id=ai.agent_id and ag.tenant_id=c.tenant_id and ag.status='ACTIVE'
 where c.id=$1 and c.tenant_id=$2 and (c.assignee_id is null or c.assignee_id=ag.id)
 on conflict(agent_id,message_id) do nothing returning id,agent_id
 ) insert into push_delivery(notification_id,subscription_id)
 select n.id,s.id from inserted n join push_subscription s on s.agent_id=n.agent_id
 join agent_session ss on ss.id=s.session_id and ss.expires_at>now()`, conversationID, tenantID, messageID)
	return err
}

// 读通知时再次验证入口权限，入口成员被移除后不能继续查看旧通知。
const notificationScope = ` n.tenant_id=$1 and n.agent_id=$2 and exists(select 1 from conversation c join agent_inbox ai on ai.inbox_id=c.inbox_id where c.id=n.conversation_id and ai.agent_id=$2 and (c.assignee_id is null or c.assignee_id=$2))`

func (a *API) notifications(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	rows, err := a.db.Query(r.Context(), `select n.id,n.conversation_id,n.kind,n.title,n.created_at,n.read_at from agent_notification n where `+notificationScope+` order by n.created_at desc limit 100`, p.TenantID, p.AgentID)
	if err != nil {
		fail(w, 500, "读取通知失败")
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var id, cid uuid.UUID
		var kind, title string
		var created time.Time
		var read *time.Time
		if rows.Scan(&id, &cid, &kind, &title, &created, &read) != nil {
			fail(w, 500, "读取通知失败")
			return
		}
		items = append(items, map[string]any{"id": id, "conversationId": cid, "kind": kind, "title": title, "createdAt": created, "readAt": read})
	}
	if rows.Err() != nil {
		fail(w, 500, "读取通知失败")
		return
	}
	var unread int
	if a.db.QueryRow(r.Context(), `select count(*) from agent_notification n where `+notificationScope+` and read_at is null`, p.TenantID, p.AgentID).Scan(&unread) != nil {
		fail(w, 500, "读取未读数失败")
		return
	}
	var quiet *time.Time
	if err := a.db.QueryRow(r.Context(), `select quiet_until from agent_alert_preference where agent_id=$1 and tenant_id=$2`, p.AgentID, p.TenantID).Scan(&quiet); err != nil && err != pgx.ErrNoRows {
		fail(w, 500, "读取提醒设置失败")
		return
	}
	respond(w, 200, map[string]any{"items": items, "unread": unread, "quietUntil": quiet})
}

func (a *API) quietNotifications(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Minutes int `json:"minutes"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Minutes != 0 && in.Minutes != 60 {
		fail(w, 400, "免打扰时长无效")
		return
	}
	var until *time.Time
	if in.Minutes > 0 {
		t := time.Now().Add(time.Hour)
		until = &t
	}
	_, err := a.db.Exec(r.Context(), `insert into agent_alert_preference(agent_id,tenant_id,quiet_until) values($1,$2,$3) on conflict(agent_id) do update set quiet_until=excluded.quiet_until`, p.AgentID, p.TenantID, until)
	if err != nil {
		fail(w, 500, "保存免打扰失败")
		return
	}
	respond(w, 200, map[string]any{"quietUntil": until})
}

func (a *API) readNotifications(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		ID  string `json:"id"`
		All bool   `json:"all"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !in.All {
		if _, err := uuid.Parse(in.ID); err != nil {
			fail(w, 400, "请选择通知")
			return
		}
	}
	_, err := a.db.Exec(r.Context(), `update agent_notification n set read_at=now() where `+notificationScope+` and read_at is null and ($3 or n.id::text=$4)`, p.TenantID, p.AgentID, in.All, in.ID)
	if err != nil {
		fail(w, 500, "更新通知失败")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) vapidKeys(ctx context.Context) (string, string, error) {
	var private, public string
	err := a.db.QueryRow(ctx, `select private_key,public_key from push_identity where id=true`).Scan(&private, &public)
	if err == pgx.ErrNoRows {
		private, public, err = webpush.GenerateVAPIDKeys()
		if err != nil {
			return "", "", err
		}
		_, err = a.db.Exec(ctx, `insert into push_identity(id,private_key,public_key) values(true,$1,$2) on conflict(id) do nothing`, private, public)
		if err == nil {
			err = a.db.QueryRow(ctx, `select private_key,public_key from push_identity where id=true`).Scan(&private, &public)
		}
	}
	return private, public, err
}
func (a *API) pushKey(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	_, public, err := a.vapidKeys(r.Context())
	if err != nil {
		fail(w, 503, "推送服务暂不可用")
		return
	}
	respond(w, 200, map[string]any{"publicKey": public})
}

// 推送端点由浏览器返回，但仍是不可信输入；只允许已知推送服务，禁止请求内网。
func validPushEndpoint(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" || u.Fragment != "" || len(raw) > 2048 {
		return false
	}
	h := strings.ToLower(u.Hostname())
	for _, domain := range []string{"fcm.googleapis.com", "updates.push.services.mozilla.com", "push.apple.com", "notify.windows.com"} {
		if h == domain || strings.HasSuffix(h, "."+domain) {
			return true
		}
	}
	return false
}
func (a *API) pushSubscriptionStatus(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Endpoint string `json:"endpoint"`
	}
	if !decode(w, r, &in) {
		return
	}
	if !validPushEndpoint(in.Endpoint) {
		fail(w, 400, "推送订阅无效")
		return
	}
	var enabled bool
	err := a.db.QueryRow(r.Context(), `select exists(select 1 from push_subscription s join agent_session ss on ss.id=s.session_id where s.tenant_id=$1 and s.agent_id=$2 and s.endpoint=$3 and ss.expires_at>now())`, p.TenantID, p.AgentID, in.Endpoint).Scan(&enabled)
	if err != nil {
		fail(w, 500, "读取通知状态失败")
		return
	}
	respond(w, 200, map[string]any{"enabled": enabled})
}

func (a *API) subscribePush(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in webpush.Subscription
	if !decode(w, r, &in) {
		return
	}
	key, e1 := base64.RawURLEncoding.DecodeString(in.Keys.P256dh)
	secret, e2 := base64.RawURLEncoding.DecodeString(in.Keys.Auth)
	if !validPushEndpoint(in.Endpoint) || e1 != nil || len(key) != 65 || key[0] != 4 || e2 != nil || len(secret) != 16 {
		fail(w, 400, "推送订阅无效")
		return
	}
	_, err := a.db.Exec(r.Context(), `insert into push_subscription(tenant_id,agent_id,session_id,endpoint,p256dh,auth) values($1,$2,$3,$4,$5,$6)
 on conflict(endpoint) do update set tenant_id=excluded.tenant_id,agent_id=excluded.agent_id,session_id=excluded.session_id,p256dh=excluded.p256dh,auth=excluded.auth,updated_at=now()`, p.TenantID, p.AgentID, p.SessionID, in.Endpoint, in.Keys.P256dh, in.Keys.Auth)
	if err != nil {
		fail(w, 500, "保存推送订阅失败")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}
func (a *API) unsubscribePush(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Endpoint string `json:"endpoint"`
	}
	if !decode(w, r, &in) {
		return
	}
	_, err := a.db.Exec(r.Context(), `delete from push_subscription where tenant_id=$1 and agent_id=$2 and endpoint=$3`, p.TenantID, p.AgentID, in.Endpoint)
	if err != nil {
		fail(w, 500, "关闭推送失败")
		return
	}
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) pushLoop(ctx context.Context) {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.deliverPushBatch(ctx)
		}
	}
}
func (a *API) deliverPushBatch(ctx context.Context) {
	// 事务锁领取批次，多实例不会同时推送同一条；到期重试，进程退出后可恢复。
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return
	}
	defer tx.Rollback(ctx)
	rows, err := tx.Query(ctx, `select d.notification_id,d.subscription_id,n.conversation_id,s.endpoint,s.p256dh,s.auth
 from push_delivery d join agent_notification n on n.id=d.notification_id join push_subscription s on s.id=d.subscription_id
 join agent_session ss on ss.id=s.session_id and ss.expires_at>now()
 join agent ag on ag.id=s.agent_id and ag.status='ACTIVE'
 join tenant t on t.id=n.tenant_id and t.status='ACTIVE'
 where d.completed_at is null and d.attempts<5 and d.next_attempt_at<=now() and n.read_at is null
 and not exists(select 1 from agent_alert_preference pref where pref.agent_id=n.agent_id and pref.quiet_until>now())
 and n.created_at>now()-interval '24 hours'
 and exists(select 1 from conversation c join agent_inbox ai on ai.inbox_id=c.inbox_id where c.id=n.conversation_id and ai.agent_id=n.agent_id and (c.assignee_id is null or c.assignee_id=n.agent_id))
 order by d.next_attempt_at limit 10 for update of d skip locked`)
	if err != nil {
		return
	}
	type job struct {
		n, s, c               uuid.UUID
		endpoint, key, secret string
	}
	jobs := []job{}
	for rows.Next() {
		var j job
		if rows.Scan(&j.n, &j.s, &j.c, &j.endpoint, &j.key, &j.secret) != nil {
			rows.Close()
			return
		}
		jobs = append(jobs, j)
	}
	rowErr := rows.Err()
	rows.Close()
	if rowErr != nil {
		return
	}
	for _, j := range jobs {
		if _, err = tx.Exec(ctx, `update push_delivery set attempts=attempts+1,next_attempt_at=now()+interval '2 minutes' where notification_id=$1 and subscription_id=$2`, j.n, j.s); err != nil {
			return
		}
	}
	if tx.Commit(ctx) != nil || len(jobs) == 0 {
		return
	}
	private, public, err := a.vapidKeys(ctx)
	if err != nil {
		return
	}
	client := &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	for _, j := range jobs {
		if !validPushEndpoint(j.endpoint) {
			continue
		}
		payload, _ := json.Marshal(map[string]any{"title": "通语 · 新消息", "body": "有客户消息待处理，请打开工作台查看。", "url": "/console/?surface=agent&conversation=" + j.c.String(), "tag": "tongyu-" + j.c.String()})
		resp, err := webpush.SendNotificationWithContext(ctx, payload, &webpush.Subscription{Endpoint: j.endpoint, Keys: webpush.Keys{P256dh: j.key, Auth: j.secret}}, &webpush.Options{Subscriber: a.cfg.PublicBaseURL, VAPIDPublicKey: public, VAPIDPrivateKey: private, TTL: 300, HTTPClient: client})
		if err != nil {
			continue
		}
		resp.Body.Close()
		if resp.StatusCode == 404 || resp.StatusCode == 410 {
			_, _ = a.db.Exec(ctx, `delete from push_subscription where id=$1`, j.s)
		} else if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			_, _ = a.db.Exec(ctx, `update push_delivery set completed_at=now() where notification_id=$1 and subscription_id=$2`, j.n, j.s)
		}
	}
}
