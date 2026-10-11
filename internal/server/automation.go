package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/relaydesk/relaydesk/internal/auth"
)

type automationRule struct {
	ID        string   `json:"id"`
	Title     string   `json:"title"`
	Keywords  []string `json:"keywords"`
	MatchMode string   `json:"matchMode"`
	Reply     string   `json:"reply"`
	Enabled   bool     `json:"enabled"`
	Priority  int      `json:"priority"`
}
type channelItem struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Description string `json:"description"`
	ImageURL    string `json:"imageUrl"`
	Action      string `json:"action"`
	Value       string `json:"value"`
}
type automationConfig struct {
	Enabled         bool             `json:"enabled"`
	RespectAgent    bool             `json:"respectAgent"`
	CooldownSeconds int              `json:"cooldownSeconds"`
	KeywordRules    []automationRule `json:"keywordRules"`
	OpenReply       string           `json:"openReply"`
	ReceivedReply   string           `json:"receivedReply"`
	OfflineReply    string           `json:"offlineReply"`
	SystemReply     string           `json:"systemReply"`
	GuideText       string           `json:"guideText"`
	GuideQuestions  []string         `json:"guideQuestions"`
	DiversionLinks  []channelItem    `json:"diversionLinks"`
	MenuItems       []channelItem    `json:"menuItems"`
	HandoffKeywords []string         `json:"handoffKeywords"`
	HandoffMessage  string           `json:"handoffMessage"`
	ChannelTitle    string           `json:"channelTitle"`
	ChannelSubtitle string           `json:"channelSubtitle"`
	QuickLinks      []channelItem    `json:"quickLinks"`
	Cards           []channelItem    `json:"cards"`
}

func defaultAutomation() automationConfig {
	return automationConfig{RespectAgent: true, CooldownSeconds: 10, HandoffMessage: "正在为你联系人工客服，请稍候。", HandoffKeywords: []string{"转人工", "人工客服"}, KeywordRules: []automationRule{}, GuideQuestions: []string{}, DiversionLinks: []channelItem{}, MenuItems: []channelItem{}, QuickLinks: []channelItem{}, Cards: []channelItem{}}
}
func (a *API) loadAutomation(ctx context.Context, inboxID uuid.UUID) (automationConfig, int64) {
	c := defaultAutomation()
	var raw []byte
	var revision int64
	if a.db.QueryRow(ctx, `select config,revision from inbox_automation where inbox_id=$1`, inboxID).Scan(&raw, &revision) == nil {
		_ = json.Unmarshal(raw, &c)
	}
	return c, revision
}
func safeChannelURL(s string) bool {
	u, err := url.Parse(s)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != "" && u.User == nil
}
func validateAutomation(c automationConfig) error {
	if c.CooldownSeconds < 0 || c.CooldownSeconds > 3600 {
		return fmt.Errorf("回复间隔应为 0 至 3600 秒")
	}
	if len(c.KeywordRules) > 100 || len(c.GuideQuestions) > 12 || len(c.HandoffKeywords) > 20 {
		return fmt.Errorf("规则或问题数量超过限制")
	}
	for _, s := range []string{c.OpenReply, c.ReceivedReply, c.OfflineReply, c.SystemReply, c.GuideText, c.HandoffMessage, c.ChannelTitle, c.ChannelSubtitle} {
		if utf8.RuneCountInString(s) > 2000 {
			return fmt.Errorf("文案最多 2000 个字符")
		}
	}
	ids := map[string]bool{}
	for _, rule := range c.KeywordRules {
		if rule.ID == "" || len(rule.ID) > 80 || ids[rule.ID] || len(rule.Keywords) == 0 || len(rule.Keywords) > 20 || strings.TrimSpace(rule.Reply) == "" || utf8.RuneCountInString(rule.Reply) > 2000 || (rule.MatchMode != "EXACT" && rule.MatchMode != "CONTAINS") {
			return fmt.Errorf("关键词规则缺少唯一 ID、关键词、匹配方式或回复内容")
		}
		ids[rule.ID] = true
		for _, k := range rule.Keywords {
			if strings.TrimSpace(k) == "" || utf8.RuneCountInString(k) > 100 {
				return fmt.Errorf("关键词不能为空，且最多 100 字")
			}
		}
	}
	ids = map[string]bool{}
	for _, items := range [][]channelItem{c.DiversionLinks, c.MenuItems, c.QuickLinks, c.Cards} {
		if len(items) > 12 {
			return fmt.Errorf("每组最多 12 项")
		}
		for _, i := range items {
			if i.ID == "" || len(i.ID) > 80 || ids[i.ID] || strings.TrimSpace(i.Title) == "" || utf8.RuneCountInString(i.Title) > 80 || utf8.RuneCountInString(i.Description) > 500 || utf8.RuneCountInString(i.Value) > 2000 {
				return fmt.Errorf("菜单需要唯一 ID 和标题，内容超出长度限制")
			}
			ids[i.ID] = true
			if i.ImageURL != "" && !safeChannelURL(i.ImageURL) {
				return fmt.Errorf("图片地址仅支持 http/https")
			}
			switch i.Action {
			case "LINK":
				if !safeChannelURL(i.Value) {
					return fmt.Errorf("跳转地址仅支持 http/https")
				}
			case "REPLY":
				if strings.TrimSpace(i.Value) == "" {
					return fmt.Errorf("回复内容不能为空")
				}
			case "HANDOFF":
			default:
				return fmt.Errorf("菜单动作必须为回复、跳转或转人工")
			}
		}
	}
	return nil
}
func (a *API) adminAutomation(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.tenantInbox(w, r, p)
	if !ok {
		return
	}
	if r.Method == "GET" {
		c, rev := a.loadAutomation(r.Context(), id)
		respond(w, 200, map[string]any{"config": c, "revision": rev})
		return
	}
	var req struct {
		Config   automationConfig `json:"config"`
		Revision int64            `json:"revision"`
	}
	if !decode(w, r, &req) {
		return
	}
	if err := validateAutomation(req.Config); err != nil {
		fail(w, 400, err.Error())
		return
	}
	raw, _ := json.Marshal(req.Config)
	var rev int64
	err := a.db.QueryRow(r.Context(), `insert into inbox_automation(inbox_id,tenant_id,config,revision) select $1,$2,$3,1 where $4::bigint=0
 on conflict(inbox_id) do nothing returning revision`, id, p.TenantID, raw, req.Revision).Scan(&rev)
	if errors.Is(err, pgx.ErrNoRows) {
		err = a.db.QueryRow(r.Context(), `update inbox_automation set config=$3,revision=revision+1,updated_at=now() where inbox_id=$1 and tenant_id=$2 and revision=$4 returning revision`, id, p.TenantID, raw, req.Revision).Scan(&rev)
	}
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			fail(w, 500, "保存配置失败")
			return
		}
		fail(w, 409, "配置已经被其他人修改，请刷新后再保存")
		return
	}
	a.recordAudit(r.Context(), p.TenantID, "AGENT", p.AgentID, "inbox.automation.update", "inbox", id, map[string]any{"revision": rev})
	respond(w, 200, map[string]any{"config": req.Config, "revision": rev})
}

// 客户端只获得展示内容；关键词与内部回复策略不对外暴露。
func (a *API) publicAutomation(ctx context.Context, id uuid.UUID) map[string]any {
	var tenantID uuid.UUID
	if a.db.QueryRow(ctx, "select tenant_id from inbox where id=$1", id).Scan(&tenantID) != nil || !a.tenantHasFeature(ctx, tenantID, "channels") {
		return map[string]any{}
	}
	c, _ := a.loadAutomation(ctx, id)
	out := map[string]any{"channelTitle": c.ChannelTitle, "channelSubtitle": c.ChannelSubtitle, "quickLinks": c.QuickLinks, "cards": c.Cards, "menuItems": c.MenuItems}
	if c.Enabled {
		out["openReply"] = c.OpenReply
		out["guideText"] = c.GuideText
		out["guideQuestions"] = c.GuideQuestions
		out["diversionLinks"] = c.DiversionLinks
	}
	return out
}
func keywordMatch(content string, keywords []string, mode string) bool {
	content = strings.ToLower(strings.TrimSpace(content))
	for _, k := range keywords {
		k = strings.ToLower(strings.TrimSpace(k))
		if k != "" && ((mode == "EXACT" && content == k) || (mode == "CONTAINS" && strings.Contains(content, k))) {
			return true
		}
	}
	return false
}
func automationAnswer(c automationConfig, q messageView, assigned, paused, online bool) (string, string, bool) {
	var meta struct {
		MenuID string `json:"menuId"`
	}
	_ = json.Unmarshal(q.Metadata, &meta)
	if meta.MenuID != "" {
		for _, items := range [][]channelItem{c.MenuItems, c.QuickLinks, c.Cards, c.DiversionLinks} {
			for _, i := range items {
				if i.ID == meta.MenuID && q.Content == i.Title {
					if i.Action == "HANDOFF" {
						return c.HandoffMessage, "handoff", true
					}
					if i.Action == "REPLY" {
						return i.Value, "menu:" + i.ID, false
					}
				}
			}
		}
	}
	if c.Enabled && keywordMatch(q.Content, c.HandoffKeywords, "CONTAINS") {
		return c.HandoffMessage, "handoff", true
	}
	if !c.Enabled || paused || (c.RespectAgent && assigned) || q.MessageType != "TEXT" {
		return "", "", false
	}
	rules := append([]automationRule(nil), c.KeywordRules...)
	sort.SliceStable(rules, func(i, j int) bool { return rules[i].Priority > rules[j].Priority })
	for _, rule := range rules {
		if rule.Enabled && keywordMatch(q.Content, rule.Keywords, rule.MatchMode) {
			return rule.Reply, "keyword:" + rule.ID, false
		}
	}
	if !online && c.OfflineReply != "" {
		return c.OfflineReply, "offline", false
	}
	if c.ReceivedReply != "" {
		return c.ReceivedReply, "received", false
	}
	if c.SystemReply != "" {
		return c.SystemReply, "system", false
	}
	return "", "", false
}
func (a *API) maybeAutomationReply(ctx context.Context, tenantID, conversationID uuid.UUID, q messageView) bool {
	if !a.tenantHasFeature(ctx, tenantID, "automation") {
		return false
	}
	var inboxID uuid.UUID
	var assigned, paused, online bool
	var status string
	if a.db.QueryRow(ctx, `select c.inbox_id,c.assignee_id is not null,c.bot_paused,c.status,exists(select 1 from agent_inbox ai join agent_presence ap on ap.agent_id=ai.agent_id where ai.inbox_id=c.inbox_id and ap.status='ONLINE') from conversation c where c.id=$1 and c.tenant_id=$2`, conversationID, tenantID).Scan(&inboxID, &assigned, &paused, &status, &online) != nil || status == "RESOLVED" {
		return true
	}
	c, _ := a.loadAutomation(ctx, inboxID)
	answer, rule, handoff := automationAnswer(c, q, assigned, paused, online)
	if answer == "" && !handoff {
		return paused
	}
	if handoff && paused {
		return true
	}
	// 原子领取发送资格，重试同一条消息不重复回复；人工接管不受普通回复冷却限制。
	interval := c.CooldownSeconds
	if handoff || strings.HasPrefix(rule, "menu:") {
		interval = 0
	}
	result, err := a.db.Exec(ctx, `insert into automation_delivery(conversation_id,question_id) values($1,$2) on conflict(conversation_id) do update set question_id=$2,replied_at=now() where automation_delivery.question_id<>$2 and automation_delivery.replied_at <= now()-make_interval(secs=>$3)`, conversationID, q.ID, interval)
	if err != nil || result.RowsAffected() == 0 {
		return true
	}
	if handoff {
		tx, beginErr := a.db.Begin(ctx)
		if beginErr != nil {
			return true
		}
		var current *uuid.UUID
		err = tx.QueryRow(ctx, `update conversation set bot_paused=true,updated_at=now() where id=$1 and tenant_id=$2 and not bot_paused returning assignee_id`, conversationID, tenantID).Scan(&current)
		if err == nil {
			_, err = a.autoAssign(ctx, tx, tenantID, conversationID, current, "VISITOR")
		}
		if err != nil {
			_ = tx.Rollback(ctx)
			return true
		}
		if tx.Commit(ctx) != nil {
			return true
		}
		if answer == "" {
			answer = "正在为你联系人工客服，请稍候。"
		}
	}

	_, err = a.appendMessage(ctx, tenantID, conversationID, messageInput{AutomationOnly: !handoff && !strings.HasPrefix(rule, "menu:"), AutomationRespectAgent: c.RespectAgent, SenderType: "SYSTEM", MessageType: "TEXT", Content: answer, ClientMessageID: "auto:" + q.ID.String(), Metadata: map[string]any{"automation": true, "rule": rule, "handoff": handoff, "senderName": "通语助手"}})
	if err != nil {
		_, _ = a.db.Exec(ctx, `delete from automation_delivery where conversation_id=$1 and question_id=$2`, conversationID, q.ID)
	}
	return true
}

func (a *API) adminChannelConversations(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	id, ok := a.tenantInbox(w, r, p)
	if !ok {
		return
	}
	rows, err := a.db.Query(r.Context(), `select c.id,coalesce(v.display_name,''),c.source,c.status,coalesce(ag.display_name,''),coalesce(c.last_message_preview,''),c.updated_at from conversation c join visitor v on v.id=c.visitor_id left join agent ag on ag.id=c.assignee_id where c.tenant_id=$1 and c.inbox_id=$2 order by c.updated_at desc limit 100`, p.TenantID, id)
	if err != nil {
		fail(w, 500, "查询渠道会话失败")
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var cid uuid.UUID
		var name, source, status, agent, preview string
		var updated any
		if rows.Scan(&cid, &name, &source, &status, &agent, &preview, &updated) != nil {
			fail(w, 500, "读取会话失败")
			return
		}
		items = append(items, map[string]any{"id": cid, "visitorName": name, "source": source, "status": status, "assigneeName": agent, "lastMessagePreview": preview, "updatedAt": updated})
	}
	if rows.Err() != nil {
		fail(w, 500, "查询会话失败")
		return
	}
	respond(w, 200, map[string]any{"items": items})
}

func (a *API) adminChannelMessages(w http.ResponseWriter, r *http.Request, p auth.Principal) {
	inboxID, ok := a.tenantInbox(w, r, p)
	if !ok {
		return
	}
	conversationID, err := uuid.Parse(r.PathValue("conversationId"))
	if err != nil {
		fail(w, 400, "会话 ID 不合法")
		return
	}
	var exists bool
	if a.db.QueryRow(r.Context(), `select exists(select 1 from conversation where id=$1 and inbox_id=$2 and tenant_id=$3)`, conversationID, inboxID, p.TenantID).Scan(&exists) != nil || !exists {
		fail(w, 404, "会话不存在")
		return
	}
	after := queryInt(r, "after", 0)
	if after < 0 {
		fail(w, 400, "消息游标不合法")
		return
	}
	page, err := a.pageMessages(r.Context(), conversationID, int64(after), 0, 100, agentVisibility)
	if err != nil {
		fail(w, 500, "读取渠道消息失败")
		return
	}
	respond(w, 200, page)
}
