package database

import (
	"context"

	"fmt"

	"github.com/google/uuid"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/tongyu/tongyu/internal/auth"
)

// demoNamespace makes every seeded identifier deterministic. Re-running the

// seeder on an existing database therefore updates the same rows instead of

// creating duplicates, and a developer can hard-code the inbox key in a test

// page without reading it back from the database.

var demoNamespace = uuid.MustParse("6f1b7c2e-8d3a-4f5b-9c0d-1a2b3c4d5e6f")

const (
	DemoTenantSlug = "demo"

	DemoOwnerEmail = "owner@tongyu.local"

	DemoAgentEmail = "agent@tongyu.local"

	DemoAgentPassword = "TongYu@2026"
)

func demoID(name string) uuid.UUID { return uuid.NewSHA1(demoNamespace, []byte(name)) }

func DemoTenantID() uuid.UUID { return demoID("tenant") }

// EnsureDemoData creates a complete, self-contained demo tenant: an inbox with a

// published public key, three seats covering every role, canned responses, tags,

// knowledge entries and a routing rule. It exists so a fresh checkout can be

// exercised end to end (widget, console, admin, AI) without any manual setup.

//

// Demo accounts share one password and are clearly marked as demo data. Never

// enable DEMO_ENABLED in production.

func EnsureDemoData(ctx context.Context, pool *pgxpool.Pool) error {

	tenantID := demoID("tenant")

	if _, err := pool.Exec(ctx, `

		insert into tenant(id, name, slug, status, settings)

		values($1, '通语客服演示企业', 'demo', 'ACTIVE', $2::jsonb)

		on conflict (slug) do update set name = excluded.name, settings = excluded.settings, updated_at = now()`,

		tenantID, map[string]any{

			"brandColor": "#2f6bff",

			"locale": "zh-CN",

			"timezone": "Asia/Shanghai",

			"industry": "SaaS",

			"demo": true,

			"supportMail": "support@tongyu.local",
		}); err != nil {

		return fmt.Errorf("seed tenant: %w", err)

	}

	if err := pool.QueryRow(ctx, `select id from tenant where slug='demo'`).Scan(&tenantID); err != nil {

		return fmt.Errorf("read demo tenant: %w", err)

	}

	// Two inboxes so routing, per-inbox AI settings and agent assignment are all

	// exercisable in the demo.

	inboxes := []struct {
		key string

		name string

		welcome string

		offline string

		domains []string

		aiOn bool

		greeting string
	}{

		{

			key: "demo-web", name: "官网在线客服",

			welcome: "你好，这里是通语客服，请问有什么可以帮到你？",

			offline: "客服当前不在线，请留言，我们会尽快回复你。",

			domains: []string{}, aiOn: true,

			greeting: "我是通语的智能助手，可以先为你解答常见问题。",
		},

		{

			key: "demo-app", name: "App 内客服",

			welcome: "欢迎使用 App 在线客服。",

			offline: "客服已下班，留言后我们会在工作时间联系你。",

			domains: []string{"app.example.com"}, aiOn: false,
		},
	}

	inboxIDs := make(map[string]uuid.UUID, len(inboxes))

	for _, item := range inboxes {

		// The public key is the business key, so the row is upserted on it and the

		// real identifier is read back. An inbox created by an earlier version of

		// this seeder already exists under a different id, and reusing that id

		// instead of the deterministic one keeps its conversations attached.

		if _, err := pool.Exec(ctx, `

			insert into inbox(id, tenant_id, name, public_key, status, auto_assign,

			                  welcome_message, offline_message, allowed_domains)

			values($1,$2,$3,$4,'ACTIVE',true,$5,$6,$7)

			on conflict (public_key) do update set

			    name = excluded.name, welcome_message = excluded.welcome_message,

			    offline_message = excluded.offline_message, allowed_domains = excluded.allowed_domains,

			    updated_at = now()`,

			demoID("inbox/"+item.key), tenantID, item.name, item.key, item.welcome, item.offline, item.domains); err != nil {

			return fmt.Errorf("seed inbox %s: %w", item.key, err)

		}

		var id uuid.UUID

		if err := pool.QueryRow(ctx, `select id from inbox where public_key=$1`, item.key).Scan(&id); err != nil {

			return fmt.Errorf("read inbox %s: %w", item.key, err)

		}

		inboxIDs[item.key] = id

		if _, err := pool.Exec(ctx, `

			insert into ai_setting(inbox_id, tenant_id, enabled, greeting, handoff_message, confidence_threshold)

			values($1,$2,$3,$4,'正在为你转接人工客服，请稍候。',0.35)

			on conflict (inbox_id) do update set

			    enabled = excluded.enabled, greeting = excluded.greeting,

			    handoff_message = excluded.handoff_message, updated_at = now()`,

			id, tenantID, item.aiOn, nullableText(item.greeting)); err != nil {

			return fmt.Errorf("seed ai setting %s: %w", item.key, err)

		}

		// One routing rule per inbox: the seeded rule is replaced rather than

		// added to, so re-running never leaves two competing strategies behind.

		if _, err := pool.Exec(ctx, `delete from routing_rule where tenant_id=$1 and inbox_id=$2`, tenantID, id); err != nil {

			return fmt.Errorf("reset routing %s: %w", item.key, err)

		}

		if _, err := pool.Exec(ctx, `

			insert into routing_rule(id, tenant_id, inbox_id, strategy, working_hours, max_concurrent, enabled)

			values($1,$2,$3,'ROUND_ROBIN',$4::jsonb,5,true)`, demoID("routing/"+item.key),

			tenantID, id, map[string]any{

				"monday": []string{"09:00-18:00"},

				"tuesday": []string{"09:00-18:00"},

				"wednesday": []string{"09:00-18:00"},

				"thursday": []string{"09:00-18:00"},

				"friday": []string{"09:00-18:00"},

				"saturday": []string{"10:00-16:00"},

				"sunday": []string{},
			}); err != nil {

			return fmt.Errorf("seed routing %s: %w", item.key, err)

		}

	}

	// Three seats, one per role, all sharing the demo password. The password is

	// hashed with the same Argon2id parameters the login endpoint verifies.

	password, err := auth.HashPassword(DemoAgentPassword)

	if err != nil {

		return fmt.Errorf("hash demo password: %w", err)

	}

	seats := []struct {
		email, name, role string

		inboxKeys []string
	}{

		{DemoOwnerEmail, "演示企业主", auth.RoleSupervisor, []string{"demo-web", "demo-app"}},

		{"supervisor@tongyu.local", "客服主管", auth.RoleSupervisor, []string{"demo-web", "demo-app"}},

		{DemoAgentEmail, "客服小林", auth.RoleAgent, []string{"demo-web"}},
	}

	for _, seat := range seats {

		agentID := demoID("agent/" + seat.email)

		if _, err := pool.Exec(ctx, `

			insert into agent(id, tenant_id, email, display_name, password_hash, role, status, max_concurrent, signature)

			values($1,$2,$3,$4,$5,$6,'ACTIVE',5,$7)

			on conflict (tenant_id, lower(email)) do update set

			    display_name = excluded.display_name, role = excluded.role,

			    password_hash = excluded.password_hash, signature = excluded.signature, updated_at = now()`,

			agentID, tenantID, seat.email, seat.name, password, seat.role,

			"通语客服 · 用心回复每一条消息"); err != nil {

			return fmt.Errorf("seed agent %s: %w", seat.email, err)

		}

		// Read the id back for the same reason as the inbox: the seat may already

		// exist under a different identifier, and its conversations reference it.

		if err := pool.QueryRow(ctx, `select id from agent where tenant_id=$1 and lower(email)=lower($2)`,

			tenantID, seat.email).Scan(&agentID); err != nil {

			return fmt.Errorf("read agent %s: %w", seat.email, err)

		}

		for _, key := range seat.inboxKeys {

			if _, err := pool.Exec(ctx, `insert into agent_inbox(agent_id, inbox_id) values($1,$2)

				on conflict do nothing`, agentID, inboxIDs[key]); err != nil {

				return fmt.Errorf("link agent %s to %s: %w", seat.email, key, err)

			}

		}

	}

	canned := []struct{ title, content string }{

		{"问候语", "你好，我是通语客服，很高兴为你服务。"},

		{"稍等回复", "你的问题我已经记录，请稍等片刻，我马上为你处理。"},

		{"需要更多信息", "为了更快定位问题，麻烦你提供一下账号、订单号和出现问题的截图，谢谢。"},

		{"结束语", "如果还有其他问题，随时找我。感谢你的耐心，祝你愉快！"},
	}

	for _, item := range canned {

		// Canned responses are matched by title, not by id, because the id carries

		// no meaning to a tenant and an older seeded row must be updated in place.

		if _, err := pool.Exec(ctx, `delete from canned_response

			where tenant_id=$1 and inbox_id=$2 and title=$3`, tenantID, inboxIDs["demo-web"], item.title); err != nil {

			return fmt.Errorf("reset canned response %s: %w", item.title, err)

		}

		if _, err := pool.Exec(ctx, `

			insert into canned_response(id, tenant_id, inbox_id, title, content)

			values($1,$2,$3,$4,$5)`,

			demoID("canned/"+item.title), tenantID, inboxIDs["demo-web"], item.title, item.content); err != nil {

			return fmt.Errorf("seed canned response %s: %w", item.title, err)

		}

	}

	tags := []struct{ name, color string }{

		{"售前咨询", "#356ae6"}, {"售后问题", "#e6642f"},

		{"已解决", "#2fa76a"}, {"需要跟进", "#c9a227"}, {"投诉", "#d43f4c"},
	}

	for _, item := range tags {

		if _, err := pool.Exec(ctx, `

			insert into tag(id, tenant_id, name, color) values($1,$2,$3,$4)

			on conflict (tenant_id, lower(name)) do update set color = excluded.color`,

			demoID("tag/"+item.name), tenantID, item.name, item.color); err != nil {

			return fmt.Errorf("seed tag %s: %w", item.name, err)

		}

	}

	if err := seedDemoKnowledge(ctx, pool, tenantID); err != nil {

		return err

	}

	_, err = pool.Exec(ctx, `

		insert into tenant_subscription(tenant_id, plan, status, seat_limit, monthly_message_limit, trial_ends_at)

		values($1, 'ENTERPRISE', 'ACTIVE', 100, 1000000, null)

		on conflict (tenant_id) do update set plan = excluded.plan, seat_limit = excluded.seat_limit,

		    monthly_message_limit = excluded.monthly_message_limit, updated_at = now()`, tenantID)

	if err != nil {

		return fmt.Errorf("seed subscription: %w", err)

	}

	return nil

}

// seedDemoKnowledge fills the knowledge base the AI answers from. The entries

// are written the way a real tenant would write them — short titles, concrete

// answers — because retrieval quality depends on that shape.

func seedDemoKnowledge(ctx context.Context, pool *pgxpool.Pool, tenantID uuid.UUID) error {

	categories := []struct {
		name string

		order int
	}{

		{"产品与功能", 1}, {"价格与套餐", 2}, {"接入与部署", 3}, {"常见故障", 4},
	}

	categoryIDs := make(map[string]uuid.UUID, len(categories))

	for _, item := range categories {

		if _, err := pool.Exec(ctx, `

			insert into knowledge_category(id, tenant_id, name, sort_order) values($1,$2,$3,$4)

			on conflict (tenant_id, lower(name)) do update set sort_order = excluded.sort_order`,

			demoID("knowledge-category/"+item.name), tenantID, item.name, item.order); err != nil {

			return fmt.Errorf("seed knowledge category %s: %w", item.name, err)

		}

		var id uuid.UUID

		if err := pool.QueryRow(ctx, `select id from knowledge_category

			where tenant_id=$1 and lower(name)=lower($2)`, tenantID, item.name).Scan(&id); err != nil {

			return fmt.Errorf("read knowledge category %s: %w", item.name, err)

		}

		categoryIDs[item.name] = id

	}

	entries := []struct {
		category, title, content, examples string
	}{

		{"接入与部署", "如何在网站接入在线客服",

			"在企业工作台创建客服入口后，可使用入口提供的组件脚本或 /h5/{inboxKey} 页面接入。入口 inboxKey 是公开标识，不是服务端密钥。" +

				"网页可通过 Web Component 接入。生产登录身份应由宿主后端验证后签发短期身份票据；不要把 API Key 写入网页。请按当前产品接入指南确认地址和来源配置。",

			"怎么接入网站；嵌入代码在哪里；public key 是什么"},

		{"接入与部署", "是否支持 App 和 H5",

			"支持网站、H5 和 App WebView 加载客服页面。App 的权限、返回按钮和身份消息桥需要宿主按实际 WebView 插件适配并在目标设备验收；当前不随平台提供原生 SDK。" +

				"访客只有在业务后端正确关联同一稳定 externalId 与身份票据时才会映射到同一客户，不应假设匿名记录自动合并。",

			"支持 App 吗；H5 能用吗；小程序可以吗"},

		{"产品与功能", "AI 自动回复是怎么工作的",

			"AI 自动回复需要平台为当前企业配置受支持的模型服务并开通套餐额度。知识库检索、低置信度策略和人工转接按企业实际配置生效；不保证模型不会产生不准确内容。" +

				"上线前应检查模型供应商、知识范围、人工接管方式，并用代表性问题实测回答；未配置模型时知识库检索不等于 AI 自动回复。",

			"AI 客服怎么配置；机器人会不会乱回答；知识库怎么用"},

		{"产品与功能", "支持多少坐席同时在线",

			"当前系统方案限制：体验版 2 个坐席、每月 1,000 条消息；专业版 1 个坐席、每月 5,000 条；旗舰版 3 个坐席、每月 50,000 条；企业版 10 个坐席、每月 1,000,000 条。" +

				"实际额度由平台管理员按服务协议配置，超出席位或额度需由平台管理员调整；套餐价格和额外用量以正式报价为准。",

			"能加坐席吗；坐席数量上限；一个账号能几个人用"},

		{"价格与套餐", "各套餐有什么区别",

			"套餐按坐席上限、月消息额度与服务端功能授权区分：专业版开放群聊和应用接入；旗舰版增加自动回复、渠道管理和 AI 能力；企业版增加服务端访客身份票据。" +

				"额度由平台管理员手工分配，当前不包含在线购买、付款或自动续费。独立部署和客户自营 SaaS 授权须另行书面确认，普通套餐不包含。",

			"多少钱；套餐价格；怎么收费"},

		{"价格与套餐", "可以先试用吗",

			"体验服务由平台管理员开通，默认 14 天；可用坐席、消息额度和功能以实际分配的 TRIAL 权限为准。" +

				"目前没有线上自助注册、支付或自动续费流程。到期后须由平台管理员调整服务状态和期限；历史数据不会因试用到期而自动删除。",

			"有没有试用；免费试用多久；试用到期怎么办"},

		{"常见故障", "访客收不到客服的消息",

			"先确认客服是否已把会话状态改为「进行中」并且没有结束会话；然后检查访客的网络是否正常，" +

				"访客端会在网络恢复后自动补齐这段时间的消息，不会丢消息。如果仍然收不到，请在「会话详情 - 消息记录」里导出该会话，发给技术支持排查。",

			"消息发不出去；访客看不到回复；消息丢了吗"},

		{"常见故障", "忘记登录密码怎么办",

			"在登录页点击「忘记密码」，输入注册邮箱即可收到重置邮件。企业管理员也可以在「团队管理」里直接为成员重置密码，" +

				"重置后该成员在所有设备上的登录会立即失效，需要重新登录。",

			"密码忘了；怎么重置密码；登录不上"},

		{"常见故障", "数据安全与消息留存",

			"所有业务数据按企业隔离，每条记录都带企业标识，接口层会再次校验归属。消息与附件的留存时间由企业自行配置，" +

				"到期后自动清理；需要长期归档可以开启 Webhook 把消息实时同步到企业自己的系统。",

			"数据安全吗；消息会保存多久；能不能导出记录"},
	}

	for _, item := range entries {

		if _, err := pool.Exec(ctx, `

			insert into knowledge_entry(id, tenant_id, category_id, title, content, question_examples, status)

			values($1,$2,$3,$4,$5,$6,'ACTIVE')

			on conflict (id) do update set

			    title = excluded.title, content = excluded.content,

			    question_examples = excluded.question_examples, updated_at = now()`,

			demoID("knowledge/"+item.title), tenantID, categoryIDs[item.category],

			item.title, item.content, item.examples); err != nil {

			return fmt.Errorf("seed knowledge entry %s: %w", item.title, err)

		}

	}

	return nil

}

// nullableText keeps empty demo values out of the database so the AI setting

// falls back to its column default instead of storing an empty string.

func nullableText(value string) any {

	if value == "" {

		return nil

	}

	return value

}
