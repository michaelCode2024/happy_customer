package server

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/relaydesk/relaydesk/internal/auth"
	"github.com/relaydesk/relaydesk/internal/realtime"
)

// registerPlatform is the RelayDesk operations API. It is the only API that may
// cross tenant boundaries: creating tenants, changing plans, suspending abuse
// and platform-wide reporting. Platform accounts use revocable password sessions.
func (a *API) registerPlatform(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/platform/login", a.limit(a.loginRate, a.platformLogin))
	mux.HandleFunc("POST /api/v1/platform/token", func(w http.ResponseWriter, r *http.Request) {
		failCode(w, 410, "PASSWORD_LOGIN_REQUIRED", "平台已改为账号密码登录，请使用 /api/v1/platform/login")
	})

	platform := a.requirePlatform
	mux.HandleFunc("GET /api/v1/platform/me", platform(a.platformMe))
	mux.HandleFunc("POST /api/v1/platform/logout", platform(a.platformLogout))
	mux.HandleFunc("POST /api/v1/platform/me/password", platform(a.platformPassword))
	mux.HandleFunc("GET /api/v1/platform/overview", platform(a.platformOverview))
	mux.HandleFunc("GET /api/v1/platform/tenants", platform(a.platformTenants))
	mux.HandleFunc("POST /api/v1/platform/tenants", platform(a.platformCreateTenant))
	mux.HandleFunc("GET /api/v1/platform/tenants/{id}", platform(a.platformTenant))
	mux.HandleFunc("POST /api/v1/platform/tenants/{id}/agents", platform(a.platformCreateAgent))
	mux.HandleFunc("PATCH /api/v1/platform/tenants/{id}", platform(a.platformUpdateTenant))
	mux.HandleFunc("POST /api/v1/platform/tenants/{id}/trial", platform(a.platformExtendTrial))
	mux.HandleFunc("POST /api/v1/platform/tenants/{id}/owner", platform(a.platformResetOwner))
	mux.HandleFunc("GET /api/v1/platform/ai-usage", platform(a.platformAIUsage))
	mux.HandleFunc("GET /api/v1/platform/release-notes", platform(a.platformMeta))
}

func (a *API) platformOverview(w http.ResponseWriter, r *http.Request, _ auth.Principal) {
	var tenants, activeTenants, agents, conversations, openConversations int
	var messagesToday int
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from tenant`).Scan(&tenants)
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from tenant where status='ACTIVE'`).Scan(&activeTenants)
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from agent where status='ACTIVE' and email <> 'bot@relaydesk.local'`).Scan(&agents)
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from conversation`).Scan(&conversations)
	_ = a.db.QueryRow(r.Context(), `select count(*)::int from conversation where status <> 'RESOLVED'`).Scan(&openConversations)
	_ = a.db.QueryRow(r.Context(), `select coalesce(sum(messages_in + messages_out),0)::int from tenant_daily_stat
		where stat_date = current_date`).Scan(&messagesToday)

	plans := make([]map[string]any, 0, 4)
	rows, err := a.db.Query(r.Context(), `
		select coalesce(s.plan,'NONE'), count(*)::int
		  from tenant t left join tenant_subscription s on s.tenant_id = t.id
		 group by coalesce(s.plan,'NONE') order by 2 desc`)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var plan string
			var count int
			if rows.Scan(&plan, &count) == nil {
				plans = append(plans, map[string]any{"plan": plan, "tenants": count})
			}
		}
	}

	top := make([]map[string]any, 0, 8)
	topRows, err := a.db.Query(r.Context(), `
		select t.id, t.name, t.slug, t.status,
		       (select count(*)::int from conversation c where c.tenant_id = t.id and c.created_at >= now() - interval '7 days'),
		       (select count(*)::int from agent ag where ag.tenant_id = t.id and ag.status='ACTIVE' and ag.email <> 'bot@relaydesk.local')
		  from tenant t
		 order by 5 desc, t.created_at desc limit 10`)
	if err == nil {
		defer topRows.Close()
		for topRows.Next() {
			var id uuid.UUID
			var name, slug, status string
			var weekConversations, seatCount int
			if topRows.Scan(&id, &name, &slug, &status, &weekConversations, &seatCount) == nil {
				top = append(top, map[string]any{"tenantId": id, "name": name, "slug": slug, "status": status,
					"conversations7d": weekConversations, "agents": seatCount})
			}
		}
	}

	respond(w, 200, map[string]any{
		"tenants": tenants, "activeTenants": activeTenants, "agents": agents,
		"conversations": conversations, "openConversations": openConversations,
		"messagesToday": messagesToday, "planDistribution": plans, "topTenants": top,
		"instance": a.bus.InstanceID(), "realtimeConnections": a.hub.Count(),
		"aiProvider": a.ai.ProviderName(), "serverTime": nowUTC(),
	})
}

func (a *API) platformTenants(w http.ResponseWriter, r *http.Request, _ auth.Principal) {
	search := strings.TrimSpace(r.URL.Query().Get("q"))
	limit := queryInt(r, "limit", 50)
	offset := queryInt(r, "offset", 0)
	if offset < 0 {
		offset = 0
	}
	if limit > 200 {
		limit = 200
	}
	rows, err := a.db.Query(r.Context(), `
		select t.id, t.name, t.slug, t.status, t.created_at,
		       coalesce(s.plan,'TRIAL'), coalesce(s.status,'ACTIVE'), coalesce(s.seat_limit,3),
		       coalesce(s.monthly_message_limit,5000), s.trial_ends_at,
		       (select count(*)::int from agent ag where ag.tenant_id = t.id and ag.status='ACTIVE' and ag.email <> 'bot@relaydesk.local'),
		       (select count(*)::int from inbox i where i.tenant_id = t.id),
		       (select count(*)::int from conversation c where c.tenant_id = t.id),
		       (select count(*)::int from conversation c where c.tenant_id = t.id and c.status <> 'RESOLVED')
		  from tenant t left join tenant_subscription s on s.tenant_id = t.id
		 where ($1 = '' or t.name ilike '%' || $1 || '%' or t.slug ilike '%' || $1 || '%')
		 order by t.created_at desc, t.id desc limit $2 offset $3`, search, limit, offset)
	if err != nil {
		fail(w, 500, "查询租户失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, limit)
	for rows.Next() {
		var id uuid.UUID
		var name, slug, status, plan, planStatus string
		var createdAt time.Time
		var seatLimit, messageLimit, agents, inboxes, conversations, openConversations int
		var trialEnds *time.Time
		if err := rows.Scan(&id, &name, &slug, &status, &createdAt, &plan, &planStatus, &seatLimit, &messageLimit,
			&trialEnds, &agents, &inboxes, &conversations, &openConversations); err != nil {
			fail(w, 500, "查询租户失败")
			return
		}
		items = append(items, map[string]any{
			"id": id, "name": name, "slug": slug, "status": status, "createdAt": createdAt,
			"plan": plan, "planStatus": planStatus, "seatLimit": seatLimit, "monthlyMessageLimit": messageLimit,
			"trialEndsAt": trialEnds, "agents": agents, "inboxes": inboxes,
			"conversations": conversations, "openConversations": openConversations,
		})
	}
	respond(w, 200, map[string]any{"items": items})
}

// platformCreateTenant provisions a tenant end to end: tenant, owner agent,
// default inbox, welcome message, AI settings and a trial subscription. Doing it
// in one transaction means a half-created customer can never exist.
func (a *API) platformCreateTenant(w http.ResponseWriter, r *http.Request, _ auth.Principal) {
	var in struct {
		Name          string `json:"name"`
		Slug          string `json:"slug"`
		OwnerEmail    string `json:"ownerEmail"`
		OwnerName     string `json:"ownerName"`
		OwnerPassword string `json:"ownerPassword"`
		InboxName     string `json:"inboxName"`
		PublicKey     string `json:"publicKey"`
		Plan          string `json:"plan"`
		TrialDays     int    `json:"trialDays"`
	}
	if !decode(w, r, &in) {
		return
	}
	name := strings.TrimSpace(in.Name)
	if name == "" {
		fail(w, 400, "企业名称不能为空")
		return
	}
	slug := slugify(in.Slug)
	if slug == "" {
		slug = slugify(name)
	}
	if slug == "" {
		slug = "t" + strings.ReplaceAll(uuid.NewString(), "-", "")[:10]
	}
	email := strings.ToLower(strings.TrimSpace(in.OwnerEmail))
	if email == "" {
		fail(w, 400, "所有者用户名格式不正确")
		return
	}
	password := in.OwnerPassword
	generated := false
	if password == "" {
		token, _, err := auth.NewOpaqueToken()
		if err != nil {
			fail(w, 500, "生成初始密码失败")
			return
		}
		password = token[:16]
		generated = true
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		fail(w, 400, err.Error())
		return
	}
	plan := strings.ToUpper(strings.TrimSpace(in.Plan))
	if plan == "" {
		plan = "TRIAL"
	}
	switch plan {
	case "TRIAL", "STARTER", "GROWTH", "ENTERPRISE":
	default:
		// Refusing beats quietly provisioning a trial: the operator would walk
		// away believing the customer is on the plan they asked for.
		fail(w, 400, "plan 只能是 TRIAL、STARTER、GROWTH 或 ENTERPRISE")
		return
	}
	trialDays := in.TrialDays
	if trialDays == 0 {
		trialDays = 14
	}
	if trialDays < 1 || trialDays > 90 {
		fail(w, 400, "trialDays 必须在 1 到 90 之间")
		return
	}
	seatLimit, messageLimit := planLimits(plan)
	inboxName := strings.TrimSpace(in.InboxName)
	if inboxName == "" {
		inboxName = name + " 网站客服"
	}
	publicKey := strings.TrimSpace(in.PublicKey)
	if publicKey == "" {
		publicKey = slug + "-web"
	}
	ownerName := strings.TrimSpace(in.OwnerName)
	if ownerName == "" {
		ownerName = "管理员"
	}

	tenantID, ownerID, inboxID := uuid.New(), uuid.New(), uuid.New()
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "创建租户失败")
		return
	}
	defer tx.Rollback(r.Context()) //nolint:errcheck

	if _, err := tx.Exec(r.Context(), `insert into tenant(id, name, slug, status)
		values($1,$2,$3,'ACTIVE')`, tenantID, name, slug); err != nil {
		if isUniqueViolation(err) {
			failCode(w, 409, "SLUG_TAKEN", "该企业标识已被占用")
			return
		}
		fail(w, 500, "创建租户失败")
		return
	}
	// The plan is bound twice ($2 as the column, $5 in the trial predicate) and
	// so is trialDays' text form. One placeholder used in two type contexts
	// makes Postgres deduce two types for it and reject the statement outright
	// (SQLSTATE 42P08), which is how tenant provisioning broke.
	if _, err := tx.Exec(r.Context(), `insert into tenant_subscription(tenant_id, plan, status, seat_limit, monthly_message_limit, trial_ends_at)
		values($1,$2,'ACTIVE',$3,$4, case when $5::text = 'TRIAL' then now() + ($6 || ' days')::interval else null end)`,
		tenantID, plan, seatLimit, messageLimit, plan, itoa(trialDays)); err != nil {
		a.logger.Error("create subscription failed", "error", err, "tenant", tenantID, "plan", plan)
		fail(w, 500, "创建套餐失败")
		return
	}
	if _, err := tx.Exec(r.Context(), `insert into agent(id, tenant_id, email, display_name, password_hash, role, status, max_concurrent)
		values($1,$2,$3,$4,$5,'OWNER','ACTIVE',0)`, ownerID, tenantID, email, ownerName, hash); err != nil {
		if isUniqueViolation(err) {
			failCode(w, 409, "EMAIL_TAKEN", "该用户名已被使用")
			return
		}
		fail(w, 500, "创建所有者账号失败")
		return
	}
	if _, err := tx.Exec(r.Context(), `insert into inbox(id, tenant_id, name, public_key, status, auto_assign, welcome_message)
		values($1,$2,$3,$4,'ACTIVE',true,$5)`, inboxID, tenantID, inboxName, publicKey,
		"你好，欢迎咨询，请直接描述你的问题。"); err != nil {
		if isUniqueViolation(err) {
			failCode(w, 409, "PUBLIC_KEY_TAKEN", "该 publicKey 已被占用")
			return
		}
		fail(w, 500, "创建客服入口失败")
		return
	}
	if _, err := tx.Exec(r.Context(), `insert into agent_inbox(agent_id, inbox_id) values($1,$2)`, ownerID, inboxID); err != nil {
		fail(w, 500, "分配客服入口失败")
		return
	}
	if _, err := tx.Exec(r.Context(), `insert into ai_setting(inbox_id, tenant_id, enabled, handoff_message)
		values($1,$2,false,'正在为你转接人工客服，请稍候。')`, inboxID, tenantID); err != nil {
		fail(w, 500, "初始化 AI 设置失败")
		return
	}
	if _, err := tx.Exec(r.Context(), `insert into routing_rule(id, tenant_id, inbox_id, strategy, max_concurrent, enabled)
		values($1,$2,$3,'LOAD_BALANCED',5,true)`, uuid.New(), tenantID, inboxID); err != nil {
		fail(w, 500, "初始化分配规则失败")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		fail(w, 500, "创建租户失败")
		return
	}
	a.recordAudit(r.Context(), tenantID, "PLATFORM", uuid.Nil, "tenant.create", "tenant", tenantID,
		map[string]any{"plan": plan, "slug": slug})

	response := map[string]any{
		"tenantId": tenantID, "slug": slug, "plan": plan,
		"ownerId": ownerID, "ownerEmail": email,
		"inboxId": inboxID, "publicKey": publicKey,
		"scriptUrl": a.cfg.PublicBaseURL + "/widget.js",
	}
	if generated {
		response["initialPassword"] = password
	}
	respond(w, 201, response)
}

func (a *API) platformTenant(w http.ResponseWriter, r *http.Request, _ auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "租户 ID 不合法")
		return
	}
	var name, slug, status string
	var createdAt, updatedAt time.Time
	var settings []byte
	err = a.db.QueryRow(r.Context(), `select name, slug, status, coalesce(settings,'{}'::jsonb), created_at, updated_at
		from tenant where id=$1`, id).Scan(&name, &slug, &status, &settings, &createdAt, &updatedAt)
	if err != nil {
		fail(w, 404, "租户不存在")
		return
	}
	agents := make([]map[string]any, 0, 8)
	agentRows, err := a.db.Query(r.Context(), `select id, email, display_name, role, status,
			coalesce((select status from agent_presence ap where ap.agent_id = a.id), 'OFFLINE')
		from agent a where tenant_id=$1 order by created_at`, id)
	if err == nil {
		defer agentRows.Close()
		for agentRows.Next() {
			var agentID uuid.UUID
			var email, displayName, role, agentStatus, presence string
			if agentRows.Scan(&agentID, &email, &displayName, &role, &agentStatus, &presence) == nil {
				agents = append(agents, map[string]any{"id": agentID, "email": email, "displayName": displayName,
					"role": role, "status": agentStatus, "presence": presence})
			}
		}
	}
	inboxes := make([]map[string]any, 0, 4)
	inboxRows, err := a.db.Query(r.Context(), `select id, name, public_key, status from inbox where tenant_id=$1 order by created_at`, id)
	if err == nil {
		defer inboxRows.Close()
		for inboxRows.Next() {
			var inboxID uuid.UUID
			var inboxName, publicKey, inboxStatus string
			if inboxRows.Scan(&inboxID, &inboxName, &publicKey, &inboxStatus) == nil {
				inboxes = append(inboxes, map[string]any{"id": inboxID, "name": inboxName,
					"publicKey": publicKey, "status": inboxStatus})
			}
		}
	}

	var plan, planStatus string
	var seatLimit, messageLimit int
	var trialEnds *time.Time
	_ = a.db.QueryRow(r.Context(), `select plan, status, seat_limit, monthly_message_limit, trial_ends_at
		from tenant_subscription where tenant_id=$1`, id).
		Scan(&plan, &planStatus, &seatLimit, &messageLimit, &trialEnds)

	usage := make([]map[string]any, 0, 30)
	usageRows, err := a.db.Query(r.Context(), `select stat_date, conversations_started, messages_in, messages_out, ai_answered, ai_handoff
		from tenant_daily_stat where tenant_id=$1 order by stat_date desc limit 30`, id)
	if err == nil {
		defer usageRows.Close()
		for usageRows.Next() {
			var statDate time.Time
			var started, in, out, aiAnswered, aiHandoff int
			if usageRows.Scan(&statDate, &started, &in, &out, &aiAnswered, &aiHandoff) == nil {
				usage = append(usage, map[string]any{"date": statDate.Format("2006-01-02"),
					"conversationsStarted": started, "messagesIn": in, "messagesOut": out,
					"aiAnswered": aiAnswered, "aiHandoff": aiHandoff})
			}
		}
	}

	respond(w, 200, map[string]any{
		"id": id, "name": name, "slug": slug, "status": status, "settings": rawJSON(settings),
		"createdAt": createdAt, "updatedAt": updatedAt,
		"subscription": map[string]any{"plan": plan, "status": planStatus, "seatLimit": seatLimit,
			"monthlyMessageLimit": messageLimit, "trialEndsAt": trialEnds},
		"agents": agents, "inboxes": inboxes, "usage": usage,
	})
}

func (a *API) platformUpdateTenant(w http.ResponseWriter, r *http.Request, _ auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "租户 ID 不合法")
		return
	}
	var in struct {
		Name         string `json:"name"`
		Status       string `json:"status"`
		Plan         string `json:"plan"`
		PlanStatus   string `json:"planStatus"`
		SeatLimit    *int   `json:"seatLimit"`
		MessageLimit *int   `json:"monthlyMessageLimit"`
		TrialDays    *int   `json:"trialDays"`
	}
	if !decode(w, r, &in) {
		return
	}
	status := strings.ToUpper(strings.TrimSpace(in.Status))
	if status != "" && status != "ACTIVE" && status != "SUSPENDED" {
		fail(w, 400, "status 只能是 ACTIVE 或 SUSPENDED")
		return
	}
	if in.Name != "" {
		if _, err := a.db.Exec(r.Context(), `update tenant set name=$2, updated_at=now() where id=$1`, id, in.Name); err != nil {
			fail(w, 500, "更新租户失败")
			return
		}
	}
	if status != "" {
		if _, err := a.db.Exec(r.Context(), `update tenant set status=$2, updated_at=now() where id=$1`, id, status); err != nil {
			fail(w, 500, "更新租户状态失败")
			return
		}
		if status == "SUSPENDED" {
			// Suspending a tenant must also cut its live sessions.
			_, _ = a.db.Exec(r.Context(), `delete from agent_session where agent_id in (select id from agent where tenant_id=$1)`, id)
			a.publish(r.Context(), []string{realtime.TenantChannel(id.String())}, realtimeEvent("tenant.suspended", id, nil))
		}
	}
	plan := strings.ToUpper(strings.TrimSpace(in.Plan))
	if plan != "" {
		switch plan {
		case "TRIAL", "STARTER", "GROWTH", "ENTERPRISE":
		default:
			fail(w, 400, "plan 只能是 TRIAL、STARTER、GROWTH 或 ENTERPRISE")
			return
		}
	}
	planStatus := strings.ToUpper(strings.TrimSpace(in.PlanStatus))
	if planStatus != "" && planStatus != "ACTIVE" && planStatus != "PAST_DUE" && planStatus != "CANCELED" {
		fail(w, 400, "planStatus 只能是 ACTIVE、PAST_DUE 或 CANCELED")
		return
	}
	// Limits may arrive on their own: an account manager topping up one customer
	// without touching the plan. The current subscription is therefore loaded and
	// only the named fields are replaced, so a limits-only PATCH is not a no-op
	// and a plan-only PATCH still recomputes the plan's default limits.
	if plan != "" || planStatus != "" || in.SeatLimit != nil || in.MessageLimit != nil {
		var curPlan, curStatus string
		var curSeat, curMessage int
		hasSubscription := true
		if err := a.db.QueryRow(r.Context(), `select plan, status, seat_limit, monthly_message_limit
			from tenant_subscription where tenant_id=$1`, id).
			Scan(&curPlan, &curStatus, &curSeat, &curMessage); err != nil {
			if !errors.Is(err, pgx.ErrNoRows) {
				a.logger.Error("read subscription failed", "error", err, "tenant", id)
				fail(w, 500, "读取套餐失败")
				return
			}
			hasSubscription = false
			curPlan, curStatus = "TRIAL", "ACTIVE"
			curSeat, curMessage = planLimits(curPlan)
		}
		nextPlan := curPlan
		if plan != "" {
			nextPlan = plan
		}
		// A new plan carries its own limits unless the caller overrides them.
		seatLimit, messageLimit := curSeat, curMessage
		if plan != "" {
			seatLimit, messageLimit = planLimits(nextPlan)
		}
		if in.SeatLimit != nil {
			if *in.SeatLimit <= 0 {
				fail(w, 400, "seatLimit 必须大于 0")
				return
			}
			seatLimit = *in.SeatLimit
		}
		if in.MessageLimit != nil {
			if *in.MessageLimit <= 0 {
				fail(w, 400, "monthlyMessageLimit 必须大于 0")
				return
			}
			messageLimit = *in.MessageLimit
		}
		nextStatus := curStatus
		if planStatus != "" {
			nextStatus = planStatus
		}
		if !hasSubscription {
			if _, err := a.db.Exec(r.Context(), `insert into tenant_subscription(tenant_id, plan, status, seat_limit, monthly_message_limit)
				values($1,$2,$3,$4,$5)`, id, nextPlan, nextStatus, seatLimit, messageLimit); err != nil {
				a.logger.Error("create subscription failed", "error", err, "tenant", id)
				fail(w, 500, "更新套餐失败")
				return
			}
		} else if _, err := a.db.Exec(r.Context(), `update tenant_subscription
			set plan=$2, status=$3, seat_limit=$4, monthly_message_limit=$5,
			trial_ends_at=case when $2::varchar='TRIAL' then coalesce(trial_ends_at,now()+interval '14 days') else null end, updated_at=now()
			where tenant_id=$1`, id, nextPlan, nextStatus, seatLimit, messageLimit); err != nil {
			a.logger.Error("update subscription failed", "error", err, "tenant", id, "plan", nextPlan)
			fail(w, 500, "更新套餐失败")
			return
		}
	}
	if in.TrialDays != nil && *in.TrialDays > 0 && *in.TrialDays <= 90 {
		if _, err := a.db.Exec(r.Context(), `update tenant_subscription
			set trial_ends_at = now() + ($2 || ' days')::interval, updated_at = now() where tenant_id=$1`,
			id, itoa(*in.TrialDays)); err != nil {
			fail(w, 500, "更新试用期失败")
			return
		}
	}
	a.recordAudit(r.Context(), id, "PLATFORM", uuid.Nil, "tenant.update", "tenant", id,
		map[string]any{"status": status, "plan": plan})
	respond(w, 200, map[string]any{"status": "OK"})
}

func (a *API) platformExtendTrial(w http.ResponseWriter, r *http.Request, _ auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "租户 ID 不合法")
		return
	}
	var in struct {
		Days int `json:"days"`
	}
	if !decode(w, r, &in) {
		return
	}
	if in.Days <= 0 || in.Days > 90 {
		fail(w, 400, "days 必须在 1 到 90 之间")
		return
	}
	result, err := a.db.Exec(r.Context(), `update tenant_subscription
		set status='ACTIVE', trial_ends_at = greatest(coalesce(trial_ends_at, now()), now()) + ($2 || ' days')::interval,
		    updated_at = now()
		where tenant_id=$1 and plan='TRIAL'`, id, itoa(in.Days))
	if err != nil {
		fail(w, 500, "延长试用期失败")
		return
	}
	if result.RowsAffected() == 0 {
		fail(w, 400, "仅试用版企业可以延长试用期")
		return
	}
	a.recordAudit(r.Context(), id, "PLATFORM", uuid.Nil, "tenant.trial.extend", "tenant", id, map[string]any{"days": in.Days})
	respond(w, 200, map[string]any{"status": "OK", "days": in.Days})
}

// platformResetOwner is the break-glass path for a locked-out customer: it
// replaces the owner password without needing the tenant's own credentials.
func (a *API) platformResetOwner(w http.ResponseWriter, r *http.Request, _ auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "租户 ID 不合法")
		return
	}
	var in struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if !decode(w, r, &in) {
		return
	}
	email := strings.ToLower(strings.TrimSpace(in.Email))
	if email == "" {
		fail(w, 400, "用户名格式不正确")
		return
	}
	password := in.Password
	if password == "" {
		token, _, err := auth.NewOpaqueToken()
		if err != nil {
			fail(w, 500, "生成密码失败")
			return
		}
		password = token[:16]
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		fail(w, 400, err.Error())
		return
	}
	// Demote-and-promote in one transaction. Demoting first and discovering the
	// new address does not exist afterwards would leave the company with no owner
	// at all — nobody able to manage billing, seats or SSO.
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		fail(w, 500, "重置所有者失败")
		return
	}
	defer tx.Rollback(r.Context()) //nolint:errcheck

	var ownerID uuid.UUID
	if err := tx.QueryRow(r.Context(), `select id from agent
		where tenant_id=$1 and lower(email)=$2 for update`, id, email).Scan(&ownerID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			failCode(w, 404, "AGENT_NOT_FOUND", "该企业下没有这个用户名的坐席")
			return
		}
		a.logger.Error("reset owner lookup failed", "error", err, "tenant", id)
		fail(w, 500, "重置所有者失败")
		return
	}
	// The previous owner is demoted rather than deleted, so transcripts keep their
	// author and the person keeps working as an admin.
	if _, err := tx.Exec(r.Context(), `update agent set role='ADMIN', updated_at=now()
		where tenant_id=$1 and role='OWNER' and id <> $2`, id, ownerID); err != nil {
		a.logger.Error("demote owner failed", "error", err, "tenant", id)
		fail(w, 500, "重置所有者失败")
		return
	}
	if _, err := tx.Exec(r.Context(), `update agent
		set password_hash=$3, role='OWNER', status='ACTIVE', updated_at=now()
		where tenant_id=$1 and id=$2`, id, ownerID, hash); err != nil {
		a.logger.Error("reset owner failed", "error", err, "tenant", id, "agent", ownerID)
		fail(w, 500, "重置所有者失败")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		a.logger.Error("reset owner commit failed", "error", err, "tenant", id)
		fail(w, 500, "重置所有者失败")
		return
	}
	_ = a.authn.RevokeAllSessions(r.Context(), ownerID)
	a.recordAudit(r.Context(), id, "PLATFORM", uuid.Nil, "tenant.owner_reset", "agent", ownerID, map[string]any{"email": email})
	respond(w, 200, map[string]any{"status": "OK", "agentId": ownerID, "password": password})
}

func (a *API) platformAIUsage(w http.ResponseWriter, r *http.Request, _ auth.Principal) {
	days := queryInt(r, "days", 14)
	if days < 1 || days > 90 {
		days = 14
	}
	rows, err := a.db.Query(r.Context(), `
		select i.provider,
		       count(*)::int,
		       count(*) filter (where i.answered)::int,
		       coalesce(avg(i.latency_ms)::int, 0),
		       coalesce(avg(i.score)::float8, 0),
		       coalesce(sum(case when i.answered then 1 else 0 end)::float8 / greatest(count(*),1), 0)
		  from ai_interaction i
		 where i.created_at >= now() - ($1 || ' days')::interval
		 group by i.provider order by 2 desc`, itoa(days))
	if err != nil {
		fail(w, 500, "查询 AI 使用情况失败")
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, 8)
	reasons := make(map[string]int)
	for rows.Next() {
		var provider string
		var total, answered, latency int
		var score, deflection float64
		if err := rows.Scan(&provider, &total, &answered, &latency, &score, &deflection); err != nil {
			fail(w, 500, "查询 AI 使用情况失败")
			return
		}
		items = append(items, map[string]any{"provider": provider, "interactions": total,
			"answered": answered, "avgLatencyMs": latency, "avgScore": score, "deflectionRate": deflection})
	}
	reasonRows, err := a.db.Query(r.Context(), `select coalesce(reason,'ANSWERED'), count(*)::int
		from ai_interaction where created_at >= now() - ($1 || ' days')::interval group by 1 order by 2 desc`, itoa(days))
	if err == nil {
		defer reasonRows.Close()
		for reasonRows.Next() {
			var reason string
			var count int
			if reasonRows.Scan(&reason, &count) == nil {
				reasons[reason] = count
			}
		}
	}
	respond(w, 200, map[string]any{"days": days, "providers": items, "reasons": reasons, "available": a.ai.Available()})
}

func (a *API) platformMeta(w http.ResponseWriter, r *http.Request, _ auth.Principal) {
	// model 必须反映当前实例真实 AI 配置，不能写死开发期模型名误导运营。
	model := strings.TrimSpace(a.cfg.AI.Model)
	if model == "" {
		model = "未配置"
	}
	respond(w, 200, map[string]any{
		"product": "聊桥客服", "version": version,
		"model":            model,
		"aiProvider":       a.ai.ProviderName(),
		"aiAvailable":      a.ai.Available(),
		"storage":          a.cfg.Storage.Describe(),
		"rateLimits":       map[string]int{"widgetPerMinute": a.cfg.RateLimit.WidgetPerMinute, "loginPerMinute": a.cfg.RateLimit.LoginPerMinute},
		"uploadMaxMB":      a.cfg.Upload.MaxBytes >> 20,
		"webhookAttempts":  a.cfg.Webhook.MaxAttempts,
		"platformFeatures": []string{"多企业隔离", "AI 自动回复", "知识库", "工单路由", "Webhook", "开放 API", "多端接入"},
	})
}

// planLimits is the single source of truth for what each plan includes.
func planLimits(plan string) (int, int) {
	switch plan {
	case "STARTER":
		return 3, 5000
	case "GROWTH":
		return 10, 50000
	case "ENTERPRISE":
		return 100, 1_000_000
	default:
		return 2, 1000
	}
}

func slugify(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	var builder strings.Builder
	lastDash := false
	for _, r := range value {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			builder.WriteRune(r)
			lastDash = false
		case r > 127:
			// Non-latin names (Chinese) get a stable hash-ish suffix instead of
			// lossy transliteration.
			builder.WriteString("-" + strings.ToLower(uuid.NewString()[:4]))
			lastDash = true
		default:
			if !lastDash && builder.Len() > 0 {
				builder.WriteByte('-')
				lastDash = true
			}
		}
		if builder.Len() > 60 {
			break
		}
	}
	return strings.Trim(builder.String(), "-")
}

// 目标企业由平台路径确定，不接收客户端自行指定的租户身份。
func (a *API) platformCreateAgent(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		fail(w, 400, "企业 ID 不合法")
		return
	}
	var status string
	err = a.db.QueryRow(r.Context(), `select status from tenant where id=$1`, id).Scan(&status)
	if errors.Is(err, pgx.ErrNoRows) {
		fail(w, 404, "企业不存在")
		return
	}
	if err != nil {
		fail(w, 500, "读取企业失败")
		return
	}
	if status != "ACTIVE" && status != "TRIAL" {
		fail(w, 409, "企业已停用，不能建立账户")
		return
	}
	p.TenantID = id
	a.createPlatformAgent(w, r, p)
}
