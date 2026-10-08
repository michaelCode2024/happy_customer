# 运营 API（平台侧）

运营 API 是唯一允许跨企业边界的接口：开通企业、调整套餐、停用滥用账号、平台级报表。
它以静态令牌 `PLATFORM_ADMIN_TOKEN`（部署时配置）保护，只应由运营后台和部署脚本使用。

## 认证

两种用法都合法：

1. 直接作为 Bearer 使用（部署脚本、紧急排障）：

   ```
   Authorization: Bearer <PLATFORM_ADMIN_TOKEN>
   ```

   也可以写成 `X-RelayDesk-Key: <PLATFORM_ADMIN_TOKEN>`。

2. 先换取 24 小时有效的 Bearer 令牌（运营后台登录页走这条路，避免把静态密钥
   长期留在客户端）：

   ```
   POST /api/v1/platform/token
   {"token": "<PLATFORM_ADMIN_TOKEN>", "label": "platform-console"}

   -> {"token": "<bearer>", "expiresIn": 86400, "label": "platform-console"}
   ```

令牌无效或缺失时返回 `401 PLATFORM_TOKEN_INVALID`。`DEMO_ENABLED=false` 时
`PLATFORM_ADMIN_TOKEN` 必须配置，否则服务拒绝启动。

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/api/v1/platform/overview` | 全局总览：企业数、活跃企业、坐席、会话、今日消息、套餐分布、活跃企业 Top、实例信息 |
| `GET` | `/api/v1/platform/tenants` | 企业列表，支持 `q` 搜索、`limit`/`offset` 分页，返回 `items`/`total` |
| `POST` | `/api/v1/platform/tenants` | 开通企业 |
| `GET` | `/api/v1/platform/tenants/{id}` | 企业详情：订阅、坐席、客服入口、近 30 天用量 |
| `PATCH` | `/api/v1/platform/tenants/{id}` | 改名、停用/恢复、调整套餐与上限、标记账期状态 |
| `POST` | `/api/v1/platform/tenants/{id}/trial` | 顺延试用期，`days` 取值 1–90 |
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

## 调整套餐

```json
{"plan": "GROWTH", "seatLimit": 25, "monthlyMessageLimit": 123456}
```

- 只给 `plan`：坐席与消息上限按该套餐默认值重算。
- 只给 `seatLimit`/`monthlyMessageLimit`：只改上限，不动套餐。
- 两者同时给：显式上限优先，其余按套餐默认值。
- `seatLimit`、`monthlyMessageLimit` 必须为正整数，`0` 或负数返回 `400`。
- `planStatus` 只能取 `ACTIVE`、`PAST_DUE`、`CANCELED`。

`status: "SUSPENDED"` 会同时注销该企业全部坐席的登录状态，并推送
`tenant.suspended` 事件。

## 重置管理员

```json
{"email": "owner@example.com", "password": "可选，留空则生成随机密码"}
```

目标邮箱必须是该企业**已存在**的坐席，否则返回 `404 AGENT_NOT_FOUND`，且不会
改动任何数据。原所有者会被降级为 `ADMIN`（保留其历史消息的作者身份），目标坐席
升级为 `OWNER` 且其全部登录状态被注销。降级与升级在同一个事务内完成，任何一步
失败都不会让企业处于"没有所有者"的状态。响应中的 `password` 是唯一一次可见的
明文。
