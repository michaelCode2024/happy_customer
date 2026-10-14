package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/relaydesk/relaydesk/internal/auth"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

type quotaReader interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}
type quotaView struct {
	TenantID     uuid.UUID  `json:"tenantId"`
	Name         string     `json:"name"`
	Slug         string     `json:"slug"`
	Owner        string     `json:"owner"`
	Plan         string     `json:"plan"`
	Status       string     `json:"status"`
	TenantStatus string     `json:"tenantStatus"`
	SeatLimit    int        `json:"seatLimit"`
	MessageLimit int        `json:"monthlyMessageLimit"`
	AILimit      int        `json:"monthlyAiLimit"`
	MessageBonus int64      `json:"messageBonus"`
	AIBonus      int64      `json:"aiBonus"`
	UsedMessages int64      `json:"usedMessages"`
	UsedAI       int64      `json:"usedAi"`
	UsedSeats    int        `json:"usedSeats"`
	Starts       *time.Time `json:"serviceStartsAt"`
	Ends         *time.Time `json:"serviceEndsAt"`
	TrialEnds    *time.Time `json:"trialEndsAt"`
	Version      time.Time  `json:"version"`
	Month        string     `json:"month"`
}

func readQuota(ctx context.Context, db quotaReader, id uuid.UUID) (quotaView, error) {
	q := quotaView{TenantID: id}
	err := db.QueryRow(ctx, `select t.name,t.slug,t.status,coalesce((select display_name from agent where tenant_id=t.id and role='SUPERVISOR' order by created_at limit 1),''),
 s.plan,s.status,s.seat_limit,s.monthly_message_limit,s.monthly_ai_limit,s.service_starts_at,s.service_ends_at,s.trial_ends_at,s.updated_at,
 coalesce(b.messages,0),coalesce(b.ai,0),coalesce(u.used,0),
 (select count(*) from agent where tenant_id=t.id and status='ACTIVE' and email<>'bot@relaydesk.local'),to_char(now(),'YYYY-MM')
 from tenant t join tenant_subscription s on s.tenant_id=t.id
 left join tenant_quota_bonus b on b.tenant_id=t.id and b.month=date_trunc('month',now())::date
 left join tenant_ai_quota_usage u on u.tenant_id=t.id and u.month=date_trunc('month',now())::date where t.id=$1`, id).Scan(&q.Name, &q.Slug, &q.TenantStatus, &q.Owner, &q.Plan, &q.Status, &q.SeatLimit, &q.MessageLimit, &q.AILimit, &q.Starts, &q.Ends, &q.TrialEnds, &q.Version, &q.MessageBonus, &q.AIBonus, &q.UsedAI, &q.UsedSeats, &q.Month)
	if err == nil {
		err = db.QueryRow(ctx, monthlyUsageSQL, id).Scan(&q.UsedMessages)
	}
	return q, err
}
func (a *API) platformQuota(w http.ResponseWriter, r *http.Request, _ auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "企业标识不合法")
		return
	}
	q, err := readQuota(r.Context(), a.db, id)
	if err != nil {
		fail(w, 404, "企业或套餐不存在")
		return
	}
	respond(w, 200, q)
}
func (a *API) platformQuotas(w http.ResponseWriter, r *http.Request, _ auth.Principal) {
	limit := queryInt(r, "limit", 100)
	if limit > 100 {
		limit = 100
	}
	offset := queryInt(r, "offset", 0)
	rows, err := a.db.Query(r.Context(), `select t.id from tenant t join tenant_subscription s on s.tenant_id=t.id where $1='' or t.name ilike '%'||$1||'%' or t.slug ilike '%'||$1||'%' order by t.created_at desc limit $2 offset $3`, strings.TrimSpace(r.URL.Query().Get("q")), limit, offset)
	if err != nil {
		fail(w, 500, "读取企业额度失败")
		return
	}
	ids := []uuid.UUID{}
	for rows.Next() {
		var id uuid.UUID
		if rows.Scan(&id) != nil {
			rows.Close()
			fail(w, 500, "读取企业额度失败")
			return
		}
		ids = append(ids, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		fail(w, 500, "读取企业额度失败")
		return
	}
	items := []quotaView{}
	for _, id := range ids {
		q, e := readQuota(r.Context(), a.db, id)
		if e != nil {
			fail(w, 500, "读取企业额度失败")
			return
		}
		items = append(items, q)
	}
	respond(w, 200, map[string]any{"items": items, "hasMore": len(ids) == limit})
}

type quotaRequest struct {
	RequestID     uuid.UUID  `json:"requestId"`
	Mode          string     `json:"mode"`
	Reason        string     `json:"reason"`
	Version       time.Time  `json:"version"`
	Plan          string     `json:"plan"`
	Status        string     `json:"status"`
	Seats         int        `json:"seatLimit"`
	Messages      int        `json:"monthlyMessageLimit"`
	AI            int        `json:"monthlyAiLimit"`
	ExtraMessages int64      `json:"extraMessages"`
	ExtraAI       int64      `json:"extraAi"`
	Starts        *time.Time `json:"serviceStartsAt"`
	Ends          *time.Time `json:"serviceEndsAt"`
}

func validateQuota(in quotaRequest) string {
	if in.RequestID == uuid.Nil || in.Version.IsZero() {
		return "缺少提交标识，请刷新页面"
	}
	if utf8.RuneCountInString(strings.TrimSpace(in.Reason)) < 2 || utf8.RuneCountInString(in.Reason) > 200 {
		return "调整说明需填写2至200个字符"
	}
	if in.Mode == "ADD" {
		if in.ExtraMessages < 0 || in.ExtraAI < 0 || in.ExtraMessages > 1000000000 || in.ExtraAI > 1000000000 || in.ExtraMessages+in.ExtraAI == 0 {
			return "追加额度需为有效的正整数"
		}
		return ""
	}
	if in.Mode != "SET" {
		return "不支持的分配方式"
	}
	if in.Plan != "TRIAL" && in.Plan != "STARTER" && in.Plan != "GROWTH" && in.Plan != "ENTERPRISE" {
		return "套餐不合法"
	}
	if in.Status != "ACTIVE" && in.Status != "PAST_DUE" && in.Status != "CANCELED" {
		return "服务状态不合法"
	}
	if in.Seats < 1 || in.Seats > 1000000 || in.Messages < 1 || in.Messages > 1000000000 || in.AI < 0 || in.AI > 1000000000 {
		return "额度超出允许范围"
	}
	if !planFeatures(in.Plan)["ai"] && in.AI > 0 {
		return "所选套餐不包含AI功能，请选择旗舰版或企业版"
	}
	if in.Starts == nil {
		return "请选择生效时间"
	}
	if in.Ends != nil && !in.Ends.After(*in.Starts) {
		return "到期时间必须晚于生效时间"
	}
	return ""
}
func (a *API) platformAssignQuota(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "企业标识不合法")
		return
	}
	var in quotaRequest
	if !decode(w, r, &in) {
		return
	}
	in.Reason = strings.TrimSpace(in.Reason)
	if msg := validateQuota(in); msg != "" {
		fail(w, 400, msg)
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "分配失败")
		return
	}
	defer tx.Rollback(r.Context())
	// Same lock as message sends and AI reservations; snapshot and ledger commit together.
	if _, err = tx.Exec(r.Context(), `select pg_advisory_xact_lock(hashtextextended($1,0))`, id.String()); err != nil {
		fail(w, 500, "分配失败")
		return
	}
	// Recheck the role in the transaction, protecting against in-flight demotion.
	var role string
	if tx.QueryRow(r.Context(), `select role from platform_admin where id=$1 and status='ACTIVE' for share`, p.PlatformAdminID).Scan(&role) != nil || role != "SUPER_ADMIN" {
		failCode(w, 403, "SUPER_ADMIN_REQUIRED", "只有超级管理员可以分配和调整额度")
		return
	}
	requestBody, _ := json.Marshal(in)
	var previousBody []byte
	var previousQuota []byte
	var previousTenant, previousActor uuid.UUID
	err = tx.QueryRow(r.Context(), `select tenant_id,actor_id,request_value,after_value from quota_adjustment where request_id=$1`, in.RequestID).Scan(&previousTenant, &previousActor, &previousBody, &previousQuota)
	if err == nil {
		var previous quotaRequest
		_ = json.Unmarshal(previousBody, &previous)
		normalized, _ := json.Marshal(previous)
		if previousTenant != id || previousActor != p.PlatformAdminID || !bytes.Equal(normalized, requestBody) {
			fail(w, 409, "提交标识已被使用")
			return
		}
		respond(w, 200, map[string]any{"status": "OK", "replayed": true, "quota": json.RawMessage(previousQuota)})
		return
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		fail(w, 500, "读取分配记录失败")
		return
	}
	if _, err = tx.Exec(r.Context(), `select tenant_id from tenant_subscription where tenant_id=$1 for update`, id); err != nil {
		fail(w, 500, "读取套餐失败")
		return
	}
	before, err := readQuota(r.Context(), tx, id)
	if err != nil {
		fail(w, 404, "企业或套餐不存在")
		return
	}
	if !before.Version.Equal(in.Version) {
		failCode(w, 409, "QUOTA_CHANGED", "额度已被其他操作调整，请刷新后重试")
		return
	}
	if in.Mode == "SET" {
		if in.Seats < before.UsedSeats {
			fail(w, 409, "坐席上限不能低于当前启用的坐席数量")
			return
		}
		if _, err = tx.Exec(r.Context(), `update tenant_subscription set plan=$2,status=$3,seat_limit=$4,monthly_message_limit=$5,monthly_ai_limit=$6,service_starts_at=$7::timestamptz,service_ends_at=$8::timestamptz,trial_ends_at=case when $2::varchar='TRIAL' then $8::timestamptz else null end,updated_at=clock_timestamp() where tenant_id=$1`, id, in.Plan, in.Status, in.Seats, in.Messages, in.AI, in.Starts, in.Ends); err != nil {
			a.logger.Error("save quota failed", "error", err)
			fail(w, 500, "保存套餐失败")
			return
		}
	} else {
		if !planFeatures(before.Plan)["ai"] && in.ExtraAI > 0 {
			fail(w, 400, "当前套餐不包含AI功能")
			return
		}
		if before.MessageBonus+in.ExtraMessages > 1000000000 || before.AIBonus+in.ExtraAI > 1000000000 {
			fail(w, 400, "累计追加额度超出允许范围")
			return
		}
		if _, err = tx.Exec(r.Context(), `insert into tenant_quota_bonus(tenant_id,month,messages,ai) values($1,date_trunc('month',now())::date,$2,$3) on conflict(tenant_id,month) do update set messages=tenant_quota_bonus.messages+excluded.messages,ai=tenant_quota_bonus.ai+excluded.ai`, id, in.ExtraMessages, in.ExtraAI); err != nil {
			fail(w, 500, "追加额度失败")
			return
		}
		if _, err = tx.Exec(r.Context(), `update tenant_subscription set updated_at=clock_timestamp() where tenant_id=$1`, id); err != nil {
			fail(w, 500, "追加额度失败")
			return
		}
	}
	after, err := readQuota(r.Context(), tx, id)
	if err != nil {
		fail(w, 500, "读取新额度失败")
		return
	}
	b, _ := json.Marshal(before)
	n, _ := json.Marshal(after)
	if _, err = tx.Exec(r.Context(), `insert into quota_adjustment(id,request_id,tenant_id,actor_id,mode,reason,before_value,after_value,request_value) values($1,$2,$3,$4,$5,$6,$7,$8,$9)`, uuid.New(), in.RequestID, id, p.PlatformAdminID, in.Mode, in.Reason, b, n, requestBody); err != nil {
		fail(w, 500, "记录调整失败，未保存")
		return
	}
	if _, err = tx.Exec(r.Context(), `insert into audit_log(id,tenant_id,actor_type,actor_id,action,target_type,target_id,detail) values($1,$2,'PLATFORM',$3,'quota.adjust','tenant',$2,$4)`, uuid.New(), id, p.PlatformAdminID, map[string]any{"mode": in.Mode, "reason": in.Reason, "before": before, "after": after}); err != nil {
		fail(w, 500, "记录审计失败，未保存")
		return
	}
	if tx.Commit(r.Context()) != nil {
		fail(w, 500, "保存失败")
		return
	}
	respond(w, 200, map[string]any{"status": "OK", "quota": after})
}
func (a *API) platformQuotaHistory(w http.ResponseWriter, r *http.Request, _ auth.Principal) {
	limit := queryInt(r, "limit", 50)
	if limit > 100 {
		limit = 100
	}
	offset := queryInt(r, "offset", 0)
	rows, err := a.db.Query(r.Context(), `select q.id,t.name,t.slug,p.display_name,q.mode,q.reason,q.before_value,q.after_value,q.created_at from quota_adjustment q join tenant t on t.id=q.tenant_id join platform_admin p on p.id=q.actor_id where $1='' or t.slug=$1 order by q.created_at desc limit $2 offset $3`, r.URL.Query().Get("tenant"), limit, offset)
	if err != nil {
		fail(w, 500, "读取操作记录失败")
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var id uuid.UUID
		var name, slug, actor, mode, reason string
		var before, after []byte
		var at time.Time
		if rows.Scan(&id, &name, &slug, &actor, &mode, &reason, &before, &after, &at) != nil {
			fail(w, 500, "读取操作记录失败")
			return
		}
		items = append(items, map[string]any{"id": id, "name": name, "slug": slug, "actor": actor, "mode": mode, "reason": reason, "before": json.RawMessage(before), "after": json.RawMessage(after), "createdAt": at})
	}
	if rows.Err() != nil {
		fail(w, 500, "读取操作记录失败")
		return
	}
	respond(w, 200, map[string]any{"items": items, "hasMore": len(items) == limit})
}

// A reservation is persisted before invoking the model so concurrent calls cannot
// exceed the quota. A failed/empty call is refunded without touching other usage.
func (a *API) reserveAIQuota(ctx context.Context, id uuid.UUID) (func(bool), error) {
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `select pg_advisory_xact_lock(hashtextextended($1,0))`, id.String()); err != nil {
		return nil, err
	}
	q, err := readQuota(ctx, tx, id)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	if !planFeatures(q.Plan)["ai"] {
		return nil, serviceError{"PLAN_FEATURE_REQUIRED", "当前套餐不包含AI功能"}
	}
	if q.TenantStatus != "ACTIVE" || q.Status != "ACTIVE" || (q.Starts != nil && now.Before(*q.Starts)) || (q.Ends != nil && !now.Before(*q.Ends)) {
		return nil, serviceError{"SUBSCRIPTION_INACTIVE", "服务未生效或已到期"}
	}
	if q.UsedAI >= int64(q.AILimit)+q.AIBonus {
		return nil, serviceError{"AI_LIMIT_REACHED", "本月AI额度已用完，请联系超级管理员"}
	}
	var month time.Time
	err = tx.QueryRow(ctx, `insert into tenant_ai_quota_usage(tenant_id,month,used) values($1,date_trunc('month',now())::date,1) on conflict(tenant_id,month) do update set used=tenant_ai_quota_usage.used+1 returning month`, id).Scan(&month)
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, err
	}
	return func(success bool) {
		if !success {
			refundCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_, e := a.db.Exec(refundCtx, `update tenant_ai_quota_usage set used=greatest(used-1,0) where tenant_id=$1 and month=$2`, id, month)
			if e != nil {
				a.logger.Error("refund AI quota failed", "error", e)
			}
		}
	}, nil
}
