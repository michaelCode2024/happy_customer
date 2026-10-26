package server

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
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
	mux.HandleFunc("POST /api/v1/console/me/activity", a.requireAgent(a.consoleActivity))
}

// 可见性单独记录，不动坐席手工设置的 ONLINE/AWAY：状态是「愿不愿意接活」，
// 可见是「眼睛在不在这个屏上」。推送只跳过后者，避免人盯着工作台时手机还响。
func (a *API) consoleActivity(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	var in struct {
		Visible *bool `json:"visible"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Visible == nil {
		fail(w, 400, "缺少可见状态")
		return
	}
	var focused any
	if *in.Visible {
		focused = time.Now()
	}
	if _, err := a.db.Exec(r.Context(), `insert into agent_presence(agent_id,status,last_seen_at,focused_at) values($1,'ONLINE',now(),$2)
		on conflict (agent_id) do update set last_seen_at=now(), focused_at=$2`, p.AgentID, focused); err != nil {
		fail(w, 500, "更新活跃状态失败")
		return
	}
	respond(w, 200, map[string]any{"visible": *in.Visible})
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

// pushJob 是一次待发送的推送：通知、订阅、会话与渲染锁屏所需的字段。
type pushJob struct {
	n, s, c                                         uuid.UUID
	kind, storedTitle, messageType, content, sender string
	deleted                                         bool
	attempts                                        int
	endpoint, key, secret                           string
}

func (a *API) deliverPushBatch(ctx context.Context) {
	// 事务锁领取批次，多实例不会同时推送同一条；到期重试，进程退出后可恢复。
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return
	}
	defer tx.Rollback(ctx)
	// 消息正文和访客称呼在投递时再读：撤回、改名要反映到锁屏，不能用入队时的占位句。
	rows, err := tx.Query(ctx, `select d.notification_id,d.subscription_id,n.conversation_id,n.kind,n.title,
 coalesce(msg.message_type,''),coalesce(msg.content,''),coalesce(msg.deleted_at is not null,false),
 coalesce(nullif(vs.display_name,''),''),
 s.endpoint,s.p256dh,s.auth
 from push_delivery d join agent_notification n on n.id=d.notification_id join push_subscription s on s.id=d.subscription_id
 join agent_session ss on ss.id=s.session_id and ss.expires_at>now()
 join agent ag on ag.id=s.agent_id and ag.status='ACTIVE'
 join tenant t on t.id=n.tenant_id and t.status='ACTIVE'
 left join message msg on msg.id=n.message_id
 left join conversation cv on cv.id=n.conversation_id
 left join visitor vs on vs.id=cv.visitor_id
 where d.completed_at is null and d.attempts<5 and d.next_attempt_at<=now() and n.read_at is null
 and not exists(select 1 from agent_alert_preference pref where pref.agent_id=n.agent_id and pref.quiet_until>now())
 and n.created_at>now()-interval '24 hours'
 and exists(select 1 from conversation c join agent_inbox ai on ai.inbox_id=c.inbox_id where c.id=n.conversation_id and ai.agent_id=n.agent_id and (c.assignee_id is null or c.assignee_id=n.agent_id))
 and not exists(select 1 from agent_presence ap where ap.agent_id=n.agent_id and ap.focused_at>now()-interval '90 seconds')
 order by d.next_attempt_at limit 10 for update of d skip locked`)
	if err != nil {
		a.logger.Warn("claim push batch failed", "error", err)
		return
	}
	jobs := []pushJob{}
	for rows.Next() {
		var j pushJob
		if err := rows.Scan(&j.n, &j.s, &j.c, &j.kind, &j.storedTitle, &j.messageType, &j.content, &j.deleted, &j.sender, &j.endpoint, &j.key, &j.secret); err != nil {
			a.logger.Warn("read push job failed", "error", err)
			rows.Close()
			return
		}
		jobs = append(jobs, j)
	}
	rowErr := rows.Err()
	rows.Close()
	if rowErr != nil {
		a.logger.Warn("iterate push jobs failed", "error", rowErr)
		return
	}
	// range 变量是副本，次数必须写回切片，后面失败日志才能读到真实 attempt。
	for i := range jobs {
		if err = tx.QueryRow(ctx, `update push_delivery set attempts=attempts+1,next_attempt_at=now()+interval '2 minutes' where notification_id=$1 and subscription_id=$2 returning attempts`, jobs[i].n, jobs[i].s).Scan(&jobs[i].attempts); err != nil {
			a.logger.Warn("reserve push attempt failed", "error", err, "notification", jobs[i].n, "subscription", jobs[i].s)
			return
		}
	}
	if err := tx.Commit(ctx); err != nil {
		a.logger.Warn("commit push batch failed", "error", err)
		return
	}
	if len(jobs) == 0 {
		return
	}
	private, public, err := a.vapidKeys(ctx)
	if err != nil {
		a.logger.Error("load vapid keys failed", "error", err)
		return
	}
	client := &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	for _, j := range jobs {
		if !validPushEndpoint(j.endpoint) {
			a.logger.Warn("skip push to disallowed endpoint", "notification", j.n, "subscription", j.s)
			continue
		}
		title, body := pushNotice(j.kind, j.storedTitle, j.sender, j.messageType, j.content, j.deleted)
		payload, _ := json.Marshal(map[string]any{"title": title, "body": body, "url": "/console/?surface=agent&conversation=" + j.c.String(), "tag": "tongyu-" + j.c.String()})
		resp, err := webpush.SendNotificationWithContext(ctx, payload, &webpush.Subscription{Endpoint: j.endpoint, Keys: webpush.Keys{P256dh: j.key, Auth: j.secret}}, &webpush.Options{Subscriber: a.cfg.PublicBaseURL, VAPIDPublicKey: public, VAPIDPrivateKey: private, TTL: 300, HTTPClient: client})
		if err != nil {
			a.pushAttemptFailed(ctx, j, err)
			continue
		}
		resp.Body.Close()
		switch {
		case resp.StatusCode == 404 || resp.StatusCode == 410:
			// 端点已失效：删除订阅，后续会话不再重复尝试。
			if _, err := a.db.Exec(ctx, `delete from push_subscription where id=$1`, j.s); err != nil {
				a.logger.Warn("drop stale push subscription failed", "error", err, "subscription", j.s, "status", resp.StatusCode)
			}
		case resp.StatusCode >= 200 && resp.StatusCode < 300:
			if _, err := a.db.Exec(ctx, `update push_delivery set completed_at=now() where notification_id=$1 and subscription_id=$2`, j.n, j.s); err != nil {
				a.logger.Warn("mark push delivered failed", "error", err, "notification", j.n, "subscription", j.s)
			}
		default:
			a.pushAttemptFailed(ctx, j, fmt.Errorf("push service status %d", resp.StatusCode))
		}
	}
}

// 每次投递失败都留日志，重试用尽单独记一条：坐席感知不到推送失效，只有日志能查。
func (a *API) pushAttemptFailed(ctx context.Context, j pushJob, cause error) {
	attrs := []any{"error", cause, "notification", j.n, "subscription", j.s, "attempt", j.attempts}
	if j.attempts >= 5 {
		a.logger.Error("push delivery gave up", attrs...)
		return
	}
	a.logger.Warn("push delivery failed; will retry", attrs...)
}

// 系统通知按会话里能看见的内容来写：标题是谁，正文是说了什么。
// 分配提醒没有消息正文，正文沿用入队时的那句说明。
// 控制符和双向文字符先去掉，避免锁屏上的名字或正文被改向。
func pushNotice(kind, storedTitle, sender, messageType, content string, deleted bool) (string, string) {
	name := noticeField(sender, 40)
	if name == "" {
		name = "客户"
	}
	if kind != "" && kind != "MESSAGE" {
		text := noticeField(storedTitle, 80)
		if text == "" {
			text = "有新的工作台提醒"
		}
		return name, text
	}
	if messageType == "" && strings.TrimSpace(content) == "" && !deleted {
		if text := noticeField(storedTitle, 80); text != "" {
			return name, text
		}
	}
	return name, pushMessageBody(messageType, content, deleted)
}

func pushMessageBody(messageType, content string, deleted bool) string {
	if deleted {
		return "消息已撤回"
	}
	switch strings.ToUpper(strings.TrimSpace(messageType)) {
	case "", "TEXT", "RICH":
		body := noticeField(content, 80)
		if body == "" {
			return "发来一条消息"
		}
		return body
	default:
		label := messageTypeLabel(messageType)
		caption := noticeField(content, 60)
		if caption == "" {
			return label
		}
		if strings.HasPrefix(caption, label) {
			return noticeField(caption, 80)
		}
		return noticeField(label+" "+caption, 80)
	}
}

func noticeField(value string, limit int) string {
	var b strings.Builder
	for _, r := range value {
		if r < 0x20 || r == 0x7f || (r >= 0x202a && r <= 0x202e) || (r >= 0x2066 && r <= 0x2069) {
			b.WriteRune(' ')
			continue
		}
		b.WriteRune(r)
	}
	return truncateRunes(strings.Join(strings.Fields(b.String()), " "), limit)
}
