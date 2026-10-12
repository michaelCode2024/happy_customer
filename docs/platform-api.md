# 运营 API（平台侧）

运营 API 管理企业、套餐和平台报表。平台账号与企业客服账号独立。

## 认证

首次启动使用 `PLATFORM_ADMIN_EMAIL`、`PLATFORM_ADMIN_PASSWORD` 初始化管理员。已有账号不会被重启或环境变量重置。

```http
POST /api/v1/platform/login
Content-Type: application/json

{"email":"admin@example.com","password":"你的密码"}
```

登录返回 `token`、`expiresIn: 28800` 和管理员资料。后续请求使用 `Authorization: Bearer <token>`。

- `GET /api/v1/platform/me`：当前管理员资料。
- `POST /api/v1/platform/logout`：立即撤销本次登录。
- `POST /api/v1/platform/me/password`：`currentPassword`、`newPassword`（至少 8 位）；成功后撤销该账号全部会话并重新登录。
- 旧 `/platform/token` 返回 410；静态平台令牌不再接受。
- 登录错误返回 401；受保护接口会检查账号状态、会话有效期和撤销状态。
- `/me` 返回实时 `role`：`SUPER_ADMIN` 可管理企业及分配额度，`SUPERVISOR` 只读。每次写入均重新检查数据库中的角色；降权后旧令牌不能继续分配。迁移保留已有平台运营账号的超级管理员权限，新建数据库账号默认 `SUPERVISOR`，首次启动初始化账号为 `SUPER_ADMIN`。

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/api/v1/platform/overview` | 全局总览：企业数、活跃企业、坐席、会话、今日消息、套餐分布、活跃企业 Top、实例信息 |
| `GET` | `/api/v1/platform/tenants` | 企业列表，支持 `q` 搜索、`limit`/`offset` 分页，返回 `items`/`total` |
| `POST` | `/api/v1/platform/tenants` | 开通企业 |
| `GET` | `/api/v1/platform/tenants/{id}` | 企业详情：订阅、坐席、客服入口、近 30 天用量 |
| `POST` | `/api/v1/platform/tenants/{id}/agents` | 超级管理员直接建立成员账户，填写 email、displayName、password、role，可选 maxConcurrent 和 inboxIds；检查席位上限并记录平台审计 |
| `PATCH` | `/api/v1/platform/tenants/{id}` | 超级管理员改名、停用/恢复；套餐及额度字段返回 `400 QUOTA_ENDPOINT_REQUIRED` |
| `POST` | `/api/v1/platform/tenants/{id}/trial` | 已停用，改用额度接口调整有效期 |
| `GET` | `/api/v1/platform/quotas` | 企业额度列表，支持 `q`、`limit`、`offset` |
| `GET` | `/api/v1/platform/tenants/{id}/quota` | 当前基础额度、当月追加、实际用量、有效期及版本 |
| `POST` | `/api/v1/platform/tenants/{id}/quota` | 仅超级管理员设置或追加额度 |
| `GET` | `/api/v1/platform/quota-adjustments` | 操作记录：操作者、原因、调整前后快照，支持分页 |
| `POST` | `/api/v1/platform/tenants/{id}/owner` | 重置/替换企业管理员密码 |
| `GET` | `/api/v1/platform/ai-usage` | 平台级 AI 用量，按 provider 聚合，`days` 取值 1–90（默认 14） |
| `GET` | `/api/v1/platform/release-notes` | 实例信息：版本、模型、存储、限流、上传上限、产品能力清单 |

## 开通企业

```json
{
  "name": "示例企业",
  "slug": "example",
  "ownerEmail": "owner@example.com",
  "ownerName": "管理员",
  "inboxName": "示例企业 网站客服",
  "publicKey": "example-web",
  "plan": "TRIAL",
  "trialDays": 14
}
```

响应为 `201`：

```json
{
  "tenantId": "uuid",
  "slug": "example",
  "plan": "TRIAL",
  "ownerId": "uuid",
  "ownerEmail": "owner@example.com",
  "inboxId": "uuid",
  "publicKey": "example-web",
  "scriptUrl": "https://.../widget.js",
  "initialPassword": "一次性明文密码"
}
```

约定：

- `plan` 只能取 `TRIAL`、`STARTER`、`GROWTH`、`ENTERPRISE`，留空按 `TRIAL`。
  取值非法时返回 `400`，不会静默降级——否则运营会以为客户按所选套餐开通了。
- `trialDays` 留空为 14，取值必须在 1–90 之间。
- `slug` 重复返回 `409 SLUG_TAKEN`。邮箱的唯一性按企业划分
  （`uk_agent_email` 是 `(tenant_id, lower(email))`），同一邮箱可以开通多家企业。
- `initialPassword` 只在这一次响应中出现，必须立即转交客户。

## 手工分配额度（暂不接支付）

先读取 `/tenants/{id}/quota`，将响应中的 `version` 原样提交。设置基础额度：

```json
{
  "requestId": "每次操作生成新的UUID，重试沿用同一个UUID",
  "version": "读取结果的version",
  "mode": "SET",
  "reason": "年度服务额度调整",
  "plan": "GROWTH",
  "status": "ACTIVE",
  "seatLimit": 25,
  "monthlyMessageLimit": 123456,
  "monthlyAiLimit": 5000,
  "serviceStartsAt": "2026-10-12T00:00:00+08:00",
  "serviceEndsAt": null
}
```

- `SET` 必须提供完整基础额度，已使用数量和当月追加额度不清零。坐席上限不能低于当前活跃人工坐席数。
- `status` 为 `ACTIVE`、`PAST_DUE`、`CANCELED`；开始日期必填，截止日期为空表示长期有效。截止日期必须晚于开始日期。
- `ADD` 仅追加当前月消息/AI额度，不改变套餐、坐席和基础额度：提交 `requestId`、`version`、`mode: "ADD"`、`reason`、`extraMessages`、`extraAi`，至少一项大于零。
- 调整说明为2至200字。成功返回 `quota`，额度、审计记录和操作快照在同一事务内保存。
- 完全相同的提交标识与内容重复提交返回原成功结果；同一标识换内容返回409。版本已被其他操作修改返回 `409 QUOTA_CHANGED`，需重新读取后确认。
- 用量及追加按数据库时区自然月统计（默认UTC）。基础额度每月重复生效，一次性追加不结转。消息统计公开会话及群消息，不包含私密、系统、事件和评分消息。
- AI自动回复、助手及知识库回答测试统一计量。调用前原子预留，失败/空回复退款；流式助手产生内容后计一次，取消后也保留该次用量。进程中断未退款的预留会保留，避免并发超领。
- 企业管理员通过 `/api/v1/admin/subscription` 只读查看有效总额度、已用数量和服务有效期。套餐功能限制、到期限制、坐席限制及消息/AI额度均由服务端执行。

`status: "SUSPENDED"` 会同时注销该企业全部坐席的登录状态，并推送
`tenant.suspended` 事件。

## 重置客服主管

```json
{"email": "supervisor@example.com", "password": "可选，留空则生成随机密码"}
```

目标账号必须是该企业已存在的成员，否则返回404且不改变数据。成功后目标账号设为启用的客服主管，其旧登录被注销；其他主管的权限保持不变。新密码仅在响应中显示一次。

企业成员角色为 SUPERVISOR/AGENT。旧 OWNER/ADMIN 请求兼容映射为 SUPERVISOR。开通企业的初始账号为客服主管，旧 owner 重置接口路径保留兼容。
