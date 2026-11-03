# 通语开放接口文档

版本 **v1** · 更新日期 **2026-11-02** · 适用服务端 **TongYu 主线**

本文是业务系统（CRM、订单系统、自建客服页、BI）对接通语的服务端接口说明。所有接口均由**你的后端**调用，密钥不得出现在浏览器、App 安装包或聊天页面中。

## 文档说明

### 阅读顺序

1. 第一次接入先读 `quickstart.md`，六步走完能拿到第一次成功的接口返回。
2. 再读「认证与鉴权」「通用约定」「错误码」三章，它们是全部接口的公共规则。
3. 之后按分类查「接口目录」中的具体接口，每个接口都给出请求参数表、请求示例、响应参数表、响应示例和可能返回的错误码。
4. 需要实时提醒时读「Webhook 回调」；需要未读角标时读「未读与已读」；接口有变更时看 `changelog.md`。

### 配套文档

| 文档 | 内容 | 说明 |
| --- | --- | --- |
| `open-api.md` | 本文，服务端开放接口 | 由服务在 `/docs` 提供在线版与 Markdown 下载 |
| `quickstart.md` | 六步完成首次对接 | 第一次接入看这份 |
| `sdk.md` | 用 OpenAPI 生成客户端、手写 Go 客户端 | 要写代码看这份 |
| `webhook.md` | 回调地址配置、事件正文、签名与重试 | 与本文同目录交付 |
| `integrations.md` | iframe 嵌入、脚本嵌入、商城接口 | 前端嵌入看这份 |
| `groups-api.md` | 群聊前端接口与通话 | 群页面实现看这份 |
| `api.md` | 访客端（浏览器）接口 | 自建 H5 页面看这份 |
| `saas-onboarding.md` | 开通、密钥申请、入口 Key | 首次接入看这份 |
| `platform-api.md` | 运营侧管理接口 | 平台方运维看这份 |
| `changelog.md` | 版本变更与弃用节奏 | 升级前看这份 |

配套的 OpenAPI 3.1 规范在 `/docs/openapi.json`，可直接导入 Postman、Apifox、Insomnia，也可用于生成客户端 SDK。

### 术语

| 术语 | 含义 |
| --- | --- |
| 企业 / 租户 | 使用通语客服业务的客户主体，密钥与数据都以企业为边界 |
| 客服入口 / inbox | 一个聊天渠道，前端嵌入用 `inboxKey`（公开 Key）标识 |
| 访客 / visitor | 咨询者。可以是匿名，也可以绑定业务系统的 `externalId` |
| 坐席 / agent | 企业侧客服人员 |
| 会话 / conversation | 一轮咨询，`status` 为 `OPEN`、`PENDING` 或 `RESOLVED` |
| 消息序号 / sequence | 会话内递增整数，是增量拉取、已读与送达游标的唯一依据 |

## 认证与鉴权

### 服务端密钥

密钥由企业管理员在控制台「应用接入 → 服务端密钥」创建，创建响应中的 `key` **只出现一次**，列表只回显前 12 位 `keyPrefix`，无法找回，只能重新创建。复制时注意数字 `0` 与字母 `O` 不是同一字符。

请求头二选一，两者等价：

```http
X-TongYu-Key: <服务端密钥>
```

```http
Authorization: Bearer <服务端密钥>
```

无论用哪种，`Content-Type: application/json` 在有请求体时必须携带。

### 权限范围（scope）

创建密钥时勾选 `read` 或 `write`，接口表中的「权限」列即所需 scope。

| scope | 说明 |
| --- | --- |
| `read` | 只读接口 |
| `write` | 写接口。签发身份、发消息、上报游标、建群、改群 |
| `admin` / `*` | 通配，等价于全部权限，不建议交付给客户使用 |

缺少所需权限时返回 `403 SCOPE_REQUIRED`。历史遗留的空 scope 列表按全部权限处理，新创建的密钥务必显式勾选。

### 套餐能力门槛

接口按企业当前套餐的能力放行，能力不足返回 `403 PLAN_FEATURE_REQUIRED`：

| 能力 | 覆盖范围 |
| --- | --- |
| `integrations` | `/api/v1/open/` 下除群聊与身份票据外的全部接口 |
| `groups` | `/api/v1/open/groups*` |
| `identity` | `POST /api/v1/open/visitor-identity` |

能力读取失败时返回 `503`，属于服务端临时故障，按可重试错误处理。

### 租户隔离

企业标识取自密钥本身，路径、查询参数与请求体都不能指定其他企业。跨企业资源一律按不存在处理，返回 `404`，不返回 `403`，避免泄露资源是否存在。

### 密钥生命周期

| 状态 | 返回 |
| --- | --- |
| 密钥已撤销 | `401 API_KEY_REVOKED` |
| 密钥已过期 | `401 API_KEY_EXPIRED` |
| 企业已停用 | `403 TENANT_SUSPENDED` |

密钥建议按环境分离（测试一把、生产一把），并设置到期时间以便轮换。

### 与服务端密钥不同的两套凭证

| 凭证 | 用途 | 出现位置 |
| --- | --- | --- |
| 服务端密钥 | 你的后端调用开放接口 | 请求头 `X-TongYu-Key` |
| 回调签名密钥 | 你验证通语推送的签名 | 回调请求头 `X-TongYu-Signature` 的计算密钥 |

两者不可混用，回调签名密钥属于每个回调地址自己，详见 `webhook.md`。

## 通用约定

### 基础地址

| 项 | 值 |
| --- | --- |
| 开放接口 Base | `{服务地址}/api/v1/open` |
| 访客端 Base | `{服务地址}/api/v1/widget` |
| 官方聊天页 | `{服务地址}/h5/{inboxKey}` |
| 嵌入脚本 | `{服务地址}/widget.js` |

`{服务地址}` 以开通资料为准，生产环境必须使用 HTTPS。

### 请求与响应

* 请求体与响应体均为 UTF-8 JSON，字段名使用小驼峰。
* 请求体中的未知字段会被拒绝并返回 `400`，请严格按下文参数表发送。
* 时间字段为 RFC3339 UTC，例如 `2026-11-02T08:00:00Z`。
* 所有 ID 为 UUID 文本，`externalId` 为你自己的用户标识，长度 1～200 字符。
* 签发令牌类响应携带 `Cache-Control: no-store`，不要缓存。

### 分页

| 参数 | 规则 |
| --- | --- |
| `limit` | 默认 50，上限 200（群列表上限 100），传 0 或负数按默认值处理 |
| `offset` | 默认 0 |
| 响应 | 列表接口返回 `items`，多数同时返回 `total`、`limit`、`offset` |

消息列表不用 offset，用序号游标 `after` / `before`，见「消息列表」。

### 限流

| 项 | 值 |
| --- | --- |
| 开放接口默认额度 | 600 次 / 分钟 / 密钥 |
| 突发桶 | 与分钟额度相同 |
| 超限响应 | `429 RATE_LIMITED`，响应头 `Retry-After: 60` |
| 配置项 | `RATE_LIMIT_OPEN_API_PER_MINUTE`（服务端环境变量） |

计数维度：带密钥的请求按密钥计数，不带密钥的请求按来源 IP 计数。收到 `429` 请退避重试，不要紧密轮询。

### 幂等

| 场景 | 幂等键 |
| --- | --- |
| 代发消息 | `clientMessageId`，同一会话内唯一 |
| 上报已读 / 送达 | 游标只前进，重复提交与提交更小值都安全 |
| 按 `externalId` 加群成员 | 已是成员时只刷新群昵称 |
| 建群 | `externalGroupId`，重复且群主一致时返回既有群 |

## 错误码

失败响应统一为 JSON：

```json
{
  "status": 403,
  "code": "PLAN_FEATURE_REQUIRED",
  "message": "当前套餐未包含此功能，请联系平台管理员调整套餐",
  "timestamp": "2026-11-02T08:00:00Z"
}
```

> `code` 只在鉴权、限流、套餐和业务冲突类错误中出现。参数校验、资源不存在等错误只返回 `status`、`message`、`timestamp`，程序判断请同时兼容这两种结构。

### 状态码

| HTTP | 含义 | 处理建议 |
| --- | --- | --- |
| 200 | 成功 | — |
| 201 | 已创建（消息、会话、群） | — |
| 400 | 字段不合法、缺必填、长度超限 | 修正请求，不要原样重试 |
| 401 | 密钥或身份票据缺失、无效、被撤销、过期 | 检查凭证与时间同步 |
| 403 | 权限、套餐、业务规则拒绝 | 按 `code` 判断 |
| 404 | 资源不存在，或属于其他企业 | 核对 ID 与密钥所属环境 |
| 409 | 状态冲突（群已解散、容量小于成员数、容量调整冲突） | 先查询最新状态 |
| 429 | 超过限流额度 | 按 `Retry-After` 退避 |
| 500 | 服务端错误 | 可重试，保留本地状态 |
| 503 | 套餐能力读取失败 | 延迟重试 |

### 业务错误码

| `code` | HTTP | 含义 |
| --- | --- | --- |
| `API_KEY_REQUIRED` | 401 | 缺少 `X-TongYu-Key` 请求头 |
| `API_KEY_INVALID` | 401 | 密钥不存在 |
| `API_KEY_REVOKED` | 401 | 密钥已被撤销 |
| `API_KEY_EXPIRED` | 401 | 密钥已过期 |
| `IDENTITY_TOKEN_INVALID` | 401 | 身份票据无效、过期或不属于当前客服入口 |
| `IDENTITY_TOKEN_REQUIRED` | 401 | 传了 `externalId` 但没有身份票据 |
| `TENANT_SUSPENDED` | 403 | 企业已停用 |
| `SCOPE_REQUIRED` | 403 | 密钥缺少所需权限 |
| `PLAN_FEATURE_REQUIRED` | 403 | 当前套餐未包含该能力 |
| `RATE_LIMITED` | 429 | 请求过于频繁 |
| `CONVERSATION_CLOSED` | 403 | 会话已结束，不能在原会话继续回复 |
| `RECEPTION_REQUIRED` | 403 | 需要先领取或确认接单 |
| `NOT_ASSIGNEE` | 403 | 会话由其他客服接待中 |
| `MESSAGE_ID_CONFLICT` | 403 | `clientMessageId` 已被其他内容占用 |

> 开放接口的代发消息不受 `RECEPTION_REQUIRED` 与 `NOT_ASSIGNEE` 限制，因为它由系统代发且不占用接待；但会话已结束时同样返回 `CONVERSATION_CLOSED`。

## 接口目录

### 服务端开放接口

| 分类 | 方法 | 路径 | 权限 | 能力 |
| --- | --- | --- | --- | --- |
| 鉴权 | GET | `/me` | read | integrations |
| 身份 | POST | `/visitor-identity` | write | identity |
| 会话 | GET | `/conversations` | read | integrations |
| 会话 | GET | `/conversations/{id}` | read | integrations |
| 会话 | PATCH | `/conversations/{id}` | write | integrations |
| 消息 | GET | `/conversations/{id}/messages` | read | integrations |
| 消息 | POST | `/conversations/{id}/messages` | write | integrations |
| 访客 | GET | `/visitors` | read | integrations |
| 访客 | GET | `/visitors/{id}` | read | integrations |
| 访客 | POST | `/visitors/{id}/conversations` | write | integrations |
| 坐席 | GET | `/agents` | read | integrations |
| 统计 | GET | `/stats` | read | integrations |
| 未读 | GET | `/unread` | read | integrations |
| 回执 | GET | `/conversations/{id}/receipts` | read | integrations |
| 回执 | POST | `/conversations/{id}/read` | write | integrations |
| 回执 | POST | `/conversations/{id}/delivered` | write | integrations |

### 群聊接口

| 方法 | 路径 | 权限 | 说明 |
| --- | --- | --- | --- |
| POST | `/groups` | write | 建群并指定群主与初始成员 |
| GET | `/groups` | read | 按 `externalId` 查该用户可见的群 |
| GET | `/groups/{id}` | read | 群详情与成员 |
| PATCH | `/groups/{id}` | write | 改群名、群公告 |
| PUT | `/groups/{id}/owner` | write | 转让群主 |
| PUT | `/groups/{id}/manager` | write | 设置或取消群管理员 |
| PATCH | `/groups/{id}/policy` | write | 设置发言模式、容量、实名要求 |
| POST | `/groups/{id}/invite` | write | 生成入群邀请链接 |
| POST | `/groups/{id}/members` | write | 按 `externalId` 批量加人 |
| DELETE | `/groups/{id}/members/{externalId}` | write | 移除成员或本人退群 |
| POST | `/groups/{id}/dissolve` | write | 解散群 |
| POST | `/groups/{id}/member-token` | write | 为已入群用户签发群会话令牌 |

### 访客端接口

前端持有访客令牌调用，令牌由 `identityToken` 或群 `member-token` 换取。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/v1/widget/bootstrap` | 用身份票据换取访客令牌 |
| GET | `/api/v1/widget/conversations` | 该用户在该入口下的会话，含 `visitorUnread` |
| POST | `/api/v1/widget/conversations` | 创建会话 |
| GET | `/api/v1/widget/conversations/{id}` | 会话详情 |
| GET | `/api/v1/widget/conversations/{id}/messages` | 增量拉取消息 |
| POST | `/api/v1/widget/conversations/{id}/messages` | 访客发送消息 |
| GET | `/api/v1/widget/conversations/{id}/search` | 会话内消息搜索 |
| POST | `/api/v1/widget/conversations/{id}/read` | 上报已读游标 |
| POST | `/api/v1/widget/conversations/{id}/delivered` | 上报送达游标 |
| GET | `/ws/widget?token=<访客令牌>` | 实时消息通道 |

> 请求头使用 `Authorization: Bearer <访客令牌>`，不要使用服务端密钥。服务端密钥只能留在你的后端。

## 鉴权接口

### 查询当前密钥与企业

| 项 | 值 |
| --- | --- |
| 方法 | GET |
| 路径 | `/api/v1/open/me` |
| 权限 | read |

**请求参数**

无。

**请求示例**

```http
GET /api/v1/open/me HTTP/1.1
Host: chat.example.com
X-TongYu-Key: <服务端密钥>
```

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `tenantId` | string | 企业 ID |
| `tenant` | string | 企业名称 |
| `keyName` | string | 当前密钥名称 |
| `scopes` | string[] | 当前密钥权限 |
| `inboxes` | int | 企业客服入口数 |
| `agents` | int | 生效坐席数 |
| `openConversations` | int | 未结束会话数 |

**响应示例**

```json
{
  "tenantId": "6f1c2b9e-0b3d-4e2a-9a71-2c5d1f0a7b33",
  "tenant": "示例科技",
  "keyName": "CRM 同步",
  "scopes": ["read", "write"],
  "inboxes": 2,
  "agents": 8,
  "openConversations": 26
}
```

用途：接入联调时先调本接口确认密钥、环境与权限是否正确，再排查业务接口报错。

## 身份接口

### 签发访客身份票据

为已登录的业务用户签发短期票据，票据随后用于换取访客令牌。票据有效期 300 秒，一次性使用，不落库。

| 项 | 值 |
| --- | --- |
| 方法 | POST |
| 路径 | `/api/v1/open/visitor-identity` |
| 权限 | write |
| 能力 | identity |

**请求参数**

| 字段 | 类型 | 必填 | 约束 | 说明 |
| --- | --- | --- | --- | --- |
| `inboxKey` | string | 是 | — | 客服入口公开 Key |
| `externalId` | string | 是 | 1～200 字符 | 你系统内的用户 ID |
| `displayName` | string | 否 | — | 展示昵称 |

**请求示例**

```http
POST /api/v1/open/visitor-identity HTTP/1.1
Host: chat.example.com
X-TongYu-Key: <服务端密钥>
Content-Type: application/json

{
  "inboxKey": "ib_9f2c4a",
  "externalId": "user-1001",
  "displayName": "张三"
}
```

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `identityToken` | string | 短期身份票据 |
| `expiresIn` | int | 有效期，秒，固定 300 |
| `inboxKey` | string | 回显入口 Key |

**响应示例**

```json
{
  "identityToken": "eyJhbGciOi...",
  "expiresIn": 300,
  "inboxKey": "ib_9f2c4a"
}
```

**错误码**

| HTTP | 说明 |
| --- | --- |
| 400 | `externalId` 为空或超长 |
| 404 | 入口不存在或不属于当前企业 |

> 必须在你的后端校验当前登录态后再签发票据。票据不校验登录态，任何人拿到都能使用 300 秒。匿名咨询不要传 `externalId`，直接由聊天页匿名 bootstrap。

### 用身份票据换取访客令牌

| 项 | 值 |
| --- | --- |
| 方法 | POST |
| 路径 | `/api/v1/widget/bootstrap` |
| 鉴权 | 无需密钥 |

**请求参数**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `inboxKey` | string | 是 | 客服入口 Key |
| `identityToken` | string | 登录用户必填 | 上一步签发的票据，`externalId` 由票据决定，前端自报无效 |
| `displayName` | string | 否 | 昵称 |
| `email` / `phone` / `locale` | string | 否 | 客户资料 |
| `attributes` | object | 否 | 自定义属性 |
| `referrer` | string | 否 | 来源页 |

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `token` | string | 访客令牌，后续请求放 `Authorization: Bearer` |
| `visitorId` | string | 访客 ID，即回执接口的 `readerId` |
| `expiresIn` | int | 令牌有效期秒数，默认 12 小时 |
| `displayName` | string | 生效昵称 |
| `inbox` | object | 入口名称、欢迎语、离线留言、皮肤配置 |
| `aiEnabled` | boolean | 该入口 AI 是否可用 |
| `agentsOnline` | int | 当前在线坐席数 |
| `openConversations` | int | 未结束会话数 |
| `serverTime` | string | 服务端时间 |

**响应示例**

```json
{
  "visitorId": "2a7b8c9d-1e2f-4a3b-8c4d-5e6f7a8b9c0d",
  "displayName": "张三",
  "token": "eyJhbGciOi...",
  "expiresIn": 43200,
  "inbox": { "id": "…", "name": "售后支持", "welcomeMessage": "您好", "reopenGraceMinutes": 1440 },
  "aiEnabled": true,
  "agentsOnline": 3,
  "openConversations": 1,
  "serverTime": "2026-11-02T08:00:00Z"
}
```

**错误码**

| HTTP | `code` | 说明 |
| --- | --- | --- |
| 400 | — | 缺少 `inboxKey` |
| 401 | `IDENTITY_TOKEN_INVALID` | 票据无效或已过期 |
| 401 | `IDENTITY_TOKEN_REQUIRED` | 传了 `externalId` 但没有票据 |
| 404 | — | 入口不存在或已停用 |

## 会话接口

### 会话列表

| 项 | 值 |
| --- | --- |
| 方法 | GET |
| 路径 | `/api/v1/open/conversations` |
| 权限 | read |

**查询参数**

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `status` | string | 全部 | `OPEN` / `PENDING` / `RESOLVED`，大小写不敏感 |
| `inboxId` | string | 全部 | 按入口 UUID 过滤 |
| `assigneeId` | string | 全部 | 坐席 UUID；传 `none` 或 `unassigned` 表示未分配 |
| `updatedSince` | string | 全部 | RFC3339 时间，只返回该时间之后有更新的会话 |
| `limit` | int | 50 | 上限 200 |
| `offset` | int | 0 | — |

**请求示例**

```http
GET /api/v1/open/conversations?status=OPEN&assigneeId=none&limit=50&offset=0 HTTP/1.1
Host: chat.example.com
X-TongYu-Key: <服务端密钥>
```

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `items` | object[] | 会话对象数组，见「数据结构」 |
| `total` | int | 满足条件的会话总数 |
| `limit` | int | 生效的每页条数 |
| `offset` | int | 生效的偏移量 |

排序为最后消息时间倒序，无消息的会话按创建时间倒序。

**响应示例**

```json
{
  "items": [
    {
      "id": "5b0f...9c0d",
      "tenantId": "6f1c...7b33",
      "inboxId": "0a1b...e4d5",
      "visitorId": "2a7b...9c0d",
      "subject": "订单 2026-1101 发货咨询",
      "status": "OPEN",
      "assigneeId": "9d8c...1a2b",
      "assigneeName": "客服小李",
      "priority": 0,
      "source": "WEB",
      "lastSequence": 12,
      "lastMessagePreview": "什么时候发货",
      "lastMessageAt": "2026-11-02T07:58:11Z",
      "agentUnread": 2,
      "visitorUnread": 0,
      "visitorName": "张三",
      "tags": ["订单"],
      "createdAt": "2026-11-02T07:40:02Z",
      "updatedAt": "2026-11-02T07:58:11Z"
    }
  ],
  "total": 1,
  "limit": 50,
  "offset": 0
}
```

**错误码**

| HTTP | 说明 |
| --- | --- |
| 400 | `assigneeId` 不是 UUID 也不是 `unassigned`、`inboxId` 或 `updatedSince` 格式错误 |

### 会话详情

| 项 | 值 |
| --- | --- |
| 方法 | GET |
| 路径 | `/api/v1/open/conversations/{id}` |
| 权限 | read |

**请求参数**

| 参数 | 位置 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | 路径 | string | 是 | 会话 UUID |

**响应参数**

单个会话对象，字段见「数据结构」。会话不属于本企业时返回 `404`，不区分「不存在」与「无权限」。

**响应示例**

```json
{
  "id": "5b0f...9c0d",
  "status": "PENDING",
  "assigneeId": "9d8c...1a2b",
  "assigneeName": "客服小李",
  "acceptedAt": "2026-11-02T07:41:30Z",
  "assignmentExpiresAt": "2026-11-02T08:11:30Z",
  "handoffRequestedAt": null,
  "lastSequence": 12,
  "agentUnread": 0,
  "visitorUnread": 1,
  "tags": ["订单", "加急"],
  "createdAt": "2026-11-02T07:40:02Z",
  "updatedAt": "2026-11-02T07:59:00Z"
}
```

### 更新会话

| 项 | 值 |
| --- | --- |
| 方法 | PATCH |
| 路径 | `/api/v1/open/conversations/{id}` |
| 权限 | write |

**请求参数**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `status` | string | 否 | `OPEN` / `PENDING` / `RESOLVED`。传 `RESOLVED` 时写入结束时间 |
| `priority` | int | 否 | 优先级，数值越大越紧急 |
| `subject` | string | 否 | 会话主题，空字符串表示不修改 |
| `tags` | string[] | 否 | 整体替换标签；不传该字段表示不动标签；不存在的标签自动创建 |

> 本接口不能改派坐席，也不接受 `assigneeId` 字段。改派与接单在客服工作台或坐席控制台接口完成。

**请求示例**

```http
PATCH /api/v1/open/conversations/5b0f...9c0d HTTP/1.1
Host: chat.example.com
X-TongYu-Key: <服务端密钥>
Content-Type: application/json

{
  "status": "PENDING",
  "priority": 2,
  "tags": ["订单", "加急"]
}
```

**响应参数**

更新后的完整会话对象。

**错误码**

| HTTP | 说明 |
| --- | --- |
| 400 | `status` 不在三个取值内 |
| 404 | 会话不存在或不属于当前企业 |
| 500 | 标签写入失败 |

副作用：更新成功后发布 `conversation.updated` 实时事件并投递同名 Webhook。

## 消息接口

### 消息列表

按会话序号游标增量拉取，是断线重连后补齐消息的标准方式。

| 项 | 值 |
| --- | --- |
| 方法 | GET |
| 路径 | `/api/v1/open/conversations/{id}/messages` |
| 权限 | read |

**查询参数**

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `after` | int64 | 0 | 只返回序号大于该值的消息，用于增量 |
| `before` | int64 | 0 | 只返回序号小于该值的消息，用于向上翻页 |
| `limit` | int | 50 | 上限 200 |
| `includePrivate` | boolean | false | 为 `true` 时同时返回内部备注 |

默认不返回内部备注，因为调用方代表客户侧。需要同步进 CRM 时显式传 `includePrivate=true`。

**请求示例**

```http
GET /api/v1/open/conversations/5b0f...9c0d/messages?after=8&limit=50 HTTP/1.1
Host: chat.example.com
X-TongYu-Key: <服务端密钥>
```

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `items` | object[] | 消息对象数组，见「数据结构」 |
| `hasMore` | boolean | 该方向还有更多数据 |
| `hasOlder` | boolean | 存在更早的消息 |
| `firstSequence` | int64 | 本页最小序号 |
| `lastSequence` | int64 | 本页最大序号；本页为空时返回会话当前最新序号 |

**响应示例**

```json
{
  "items": [
    {
      "id": "7c1a...3b9d",
      "conversationId": "5b0f...9c0d",
      "senderType": "VISITOR",
      "senderId": "2a7b...9c0d",
      "senderName": "张三",
      "sequence": 9,
      "messageType": "TEXT",
      "content": "什么时候发货",
      "metadata": {},
      "createdAt": "2026-11-02T07:55:00Z"
    }
  ],
  "hasMore": false,
  "hasOlder": true,
  "firstSequence": 9,
  "lastSequence": 12
}
```

### 代发消息

以企业（坐席侧）身份向会话注入消息，用于订单状态、自助答复、机器人回复等场景。

| 项 | 值 |
| --- | --- |
| 方法 | POST |
| 路径 | `/api/v1/open/conversations/{id}/messages` |
| 权限 | write |

**请求参数**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `content` | string | 是 | 消息正文 |
| `messageType` | string | 否 | 默认 `TEXT`；允许 `TEXT`、`IMAGE`、`FILE`、`RICH`、`AUDIO`、`VIDEO`、`LOCATION`、`CARD`、`EVENT`、`SYSTEM`、`RATING` |
| `clientMessageId` | string | 否 | 幂等键，同一会话内唯一 |
| `senderName` | string | 否 | 覆盖展示署名，写入消息 `metadata.senderName` |
| `metadata` | object | 否 | 自定义字段；服务端会追加 `source: "open_api"` |

> 本接口不接受附件字段。开放接口没有上传通道（上传接口只接受访客或坐席令牌），需要发图片或文件时请发送你自有存储的 URL。

**幂等规则**

| 情况 | 结果 |
| --- | --- |
| 相同 `clientMessageId` 且内容一致 | 返回首次那条消息，不重复产生消息 |
| 相同 `clientMessageId` 但内容不同 | `403 MESSAGE_ID_CONFLICT` |
| 未传 `clientMessageId` | 每次都是新消息，重试可能重复 |

**请求示例**

```http
POST /api/v1/open/conversations/5b0f...9c0d/messages HTTP/1.1
Host: chat.example.com
X-TongYu-Key: <服务端密钥>
Content-Type: application/json

{
  "clientMessageId": "order-8842-shipped",
  "content": "你的订单已发货，运单号 SF1234567890",
  "senderName": "订单系统"
}
```

**响应参数**

消息对象，`201 Created`。

**响应示例**

```json
{
  "id": "b1e2...44f0",
  "conversationId": "5b0f...9c0d",
  "senderType": "AGENT",
  "senderId": "4c3d...77aa",
  "senderName": "订单系统",
  "clientMessageId": "order-8842-shipped",
  "sequence": 13,
  "messageType": "TEXT",
  "content": "你的订单已发货，运单号 SF1234567890",
  "metadata": { "senderName": "订单系统", "source": "open_api" },
  "createdAt": "2026-11-02T08:02:10Z"
}
```

**错误码**

| HTTP | `code` | 说明 |
| --- | --- | --- |
| 400 | — | 消息类型不支持或字段不合法 |
| 403 | `CONVERSATION_CLOSED` | 会话已结束，不能在原会话继续回复 |
| 403 | `MESSAGE_ID_CONFLICT` | 幂等键被不同内容占用 |
| 404 | — | 会话不存在或不属于当前企业 |

行为说明：

* 消息归属企业的集成机器人坐席，计入企业外发消息统计。
* 不占用人工接待，不受「先接单再回复」限制。
* 触发客户侧实时消息与 `message.agent` Webhook（订阅了才会收到）。

## 访客接口

### 访客列表

| 项 | 值 |
| --- | --- |
| 方法 | GET |
| 路径 | `/api/v1/open/visitors` |
| 权限 | read |

**查询参数**

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `search` | string | 空 | 按昵称、邮箱或 `externalId` 模糊匹配，大小写不敏感 |
| `limit` | int | 50 | 上限 200 |
| `offset` | int | 0 | — |

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `items[].id` | string | 访客 ID |
| `items[].displayName` | string | 昵称 |
| `items[].email` / `phone` / `locale` / `country` | string | 资料，未采集时为空字符串 |
| `items[].externalId` | string | 业务系统用户 ID，未绑定时为空字符串 |
| `items[].customAttributes` | object | 自定义属性 |
| `items[].conversations` | int | 该访客会话数 |
| `items[].createdAt` | string | 首次出现时间 |
| `items[].lastSeenAt` | string | 最近活跃时间，缺省用创建时间 |
| `total` / `limit` / `offset` | int | 分页信息 |

**响应示例**

```json
{
  "items": [
    {
      "id": "2a7b...9c0d",
      "displayName": "张三",
      "email": "",
      "phone": "",
      "externalId": "user-1001",
      "locale": "zh-CN",
      "country": "",
      "customAttributes": { "vip": 1 },
      "conversations": 3,
      "createdAt": "2026-10-01T02:00:00Z",
      "lastSeenAt": "2026-11-02T07:58:11Z"
    }
  ],
  "total": 1,
  "limit": 50,
  "offset": 0
}
```

### 访客详情

| 项 | 值 |
| --- | --- |
| 方法 | GET |
| 路径 | `/api/v1/open/visitors/{id}` |
| 权限 | read |

**请求参数**

| 参数 | 位置 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | 路径 | string | 是 | 访客 UUID，同时属于当前企业 |

**响应参数**

访客列表的单条结构，外加 `conversations` 数组（最近 50 条会话摘要）：`id`、`subject`、`status`、`priority`、`lastSequence`、`lastMessagePreview`、`lastMessageAt`、`createdAt`、`updatedAt`。

**响应示例**

```json
{
  "id": "2a7b...9c0d",
  "displayName": "张三",
  "externalId": "user-1001",
  "customAttributes": { "vip": 1 },
  "createdAt": "2026-10-01T02:00:00Z",
  "lastSeenAt": "2026-11-02T07:58:11Z",
  "conversations": [
    {
      "id": "5b0f...9c0d",
      "subject": "",
      "status": "OPEN",
      "priority": 0,
      "lastSequence": 12,
      "lastMessagePreview": "什么时候发货",
      "lastMessageAt": "2026-11-02T07:58:11Z",
      "createdAt": "2026-11-02T07:40:02Z",
      "updatedAt": "2026-11-02T07:58:11Z"
    }
  ]
}
```

### 为客户创建会话

由你的后端主动开启一轮咨询，例如在订单详情页放「联系客服」。

| 项 | 值 |
| --- | --- |
| 方法 | POST |
| 路径 | `/api/v1/open/visitors/{id}/conversations` |
| 权限 | write |

**请求参数**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `inboxKey` | string | 是 | 客服入口 Key，必须属于当前企业 |
| `subject` | string | 否 | 会话主题 |
| `content` | string | 否 | 非空时立即以坐席身份发出首条消息 |
| `priority` | int | 否 | 优先级，默认 0 |
| `tags` | string[] | 否 | 初始标签，不存在的自动创建 |
| `metadata` | object | 否 | 首条消息的自定义字段，追加 `source: "open_api"` |

**请求示例**

```http
POST /api/v1/open/visitors/2a7b...9c0d/conversations HTTP/1.1
Host: chat.example.com
X-TongYu-Key: <服务端密钥>
Content-Type: application/json

{
  "inboxKey": "ib_9f2c4a",
  "subject": "订单 2026-1101 发货咨询",
  "content": "您好，关于订单 2026-1101 有任何问题都可以在这里咨询",
  "tags": ["订单"]
}
```

**响应参数**

新建的会话对象，`201 Created`，`source` 为 `API`。带首条消息时 `lastSequence` 与 `lastMessagePreview` 已更新。

**错误码**

| HTTP | 说明 |
| --- | --- |
| 400 | `inboxKey` 为空 |
| 404 | 入口不属于当前企业 |
| 404 | 访客不存在或不属于当前企业 |

副作用：投递 `conversation.created` Webhook。若带首条消息，还会产生该坐席侧消息的 `message.agent` 事件。

## 坐席接口

### 坐席列表

| 项 | 值 |
| --- | --- |
| 方法 | GET |
| 路径 | `/api/v1/open/agents` |
| 权限 | read |

**请求参数**

无。

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `items[].id` | string | 坐席 ID，可作为会话列表的 `assigneeId` 或回执的 `readerId` |
| `items[].displayName` | string | 姓名 |
| `items[].role` | string | 角色 |
| `items[].status` | string | 账号状态，`ACTIVE` 为生效 |
| `items[].presence` | string | 在线状态，`ONLINE` / `OFFLINE` |
| `items[].openConversations` | int | 未结束会话数 |

返回按姓名排序的坐席，不含集成机器人账号。

**响应示例**

```json
{
  "items": [
    {
      "id": "9d8c...1a2b",
      "displayName": "客服小李",
      "role": "AGENT",
      "status": "ACTIVE",
      "presence": "ONLINE",
      "openConversations": 5
    }
  ]
}
```

## 统计接口

### 企业统计摘要

数据来源与控制台看板一致，可直接用于你的 BI。

| 项 | 值 |
| --- | --- |
| 方法 | GET |
| 路径 | `/api/v1/open/stats` |
| 权限 | read |

**查询参数**

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `days` | int | 30 | 取值 1～365，超范围或非法值按 30 处理 |

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `days` | int | 生效的天数 |
| `series[].date` | string | 自然日，`YYYY-MM-DD` |
| `series[].conversationsStarted` / `conversationsClosed` | int | 当日开始 / 结束会话数 |
| `series[].messagesIn` / `messagesOut` | int | 当日客户消息 / 坐席消息数 |
| `series[].aiAnswered` / `aiHandoff` | int | AI 自主答复 / 转人工数 |
| `series[].ratingSum` / `ratingCount` | int | 评分合计与样本数 |
| `totals.*` | int | 区间内上述字段合计 |
| `totals.aiDeflectionRate` | number | AI 拦截率，`aiAnswered / (aiAnswered + aiHandoff)` |
| `totals.avgFirstResponseSeconds` | number | 首次响应平均秒数 |
| `totals.avgRating` | number | 平均评分 |

**响应示例**

```json
{
  "days": 30,
  "series": [
    {
      "date": "2026-11-01",
      "conversationsStarted": 42,
      "conversationsClosed": 38,
      "messagesIn": 210,
      "messagesOut": 190,
      "aiAnswered": 96,
      "aiHandoff": 31,
      "ratingSum": 180,
      "ratingCount": 39
    }
  ],
  "totals": {
    "conversationsStarted": 1204,
    "conversationsClosed": 1180,
    "messagesIn": 6310,
    "messagesOut": 5922,
    "aiAnswered": 2881,
    "aiHandoff": 940,
    "aiDeflectionRate": 0.7543,
    "avgFirstResponseSeconds": 47.2,
    "avgRating": 4.6
  }
}
```

## 未读与回执接口

### 企业未读汇总

| 项 | 值 |
| --- | --- |
| 方法 | GET |
| 路径 | `/api/v1/open/unread` |
| 权限 | read |

**请求参数**

无。

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `agentUnread` | int | 全企业客服侧未读客户消息数合计 |
| `visitorUnread` | int | 全企业客户侧未读坐席公开消息数合计 |
| `unreadConversations` | int | 任一侧未读大于 0 的会话数 |

**响应示例**

```json
{ "agentUnread": 3, "visitorUnread": 1, "unreadConversations": 2 }
```

> 这是企业范围合计，不能当作某一个用户的角标。单个用户请见「单人未读角标」。

### 会话回执游标

| 项 | 值 |
| --- | --- |
| 方法 | GET |
| 路径 | `/api/v1/open/conversations/{id}/receipts` |
| 权限 | read |

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `items[].readerType` | string | `VISITOR` / `AGENT` |
| `items[].readerId` | string | 访客或坐席 ID |
| `items[].readSequence` | int64 | 已读到的序号 |
| `items[].deliveredSequence` | int64 | 已送达的序号 |
| `items[].updatedAt` | string | 游标最后更新时间 |

**响应示例**

```json
{
  "items": [
    {
      "readerType": "VISITOR",
      "readerId": "2a7b...9c0d",
      "readSequence": 12,
      "deliveredSequence": 15,
      "updatedAt": "2026-11-02T08:00:00Z"
    }
  ]
}
```

### 上报已读与送达

| 项 | 值 |
| --- | --- |
| 方法 | POST |
| 路径 | `/api/v1/open/conversations/{id}/read`、`/api/v1/open/conversations/{id}/delivered` |
| 权限 | write |

**请求参数**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `readerType` | string | 是 | `VISITOR` 或 `AGENT` |
| `readerId` | string | 是 | `VISITOR` 必须是该会话的访客；`AGENT` 必须是当前企业生效坐席（不含机器人） |
| `sequence` | int64 | 是 | 必须大于 0，服务端夹紧到会话最新序号 |

**请求示例**

```http
POST /api/v1/open/conversations/5b0f...9c0d/read HTTP/1.1
Host: chat.example.com
X-TongYu-Key: <服务端密钥>
Content-Type: application/json

{
  "readerType": "VISITOR",
  "readerId": "2a7b...9c0d",
  "sequence": 12
}
```

**响应参数**

`200 OK`，正文与该会话的回执列表完全相同（结构见「会话回执游标」），可直接作为最新权威游标。

**错误码**

| HTTP | 说明 |
| --- | --- |
| 400 | `sequence` 不大于 0，或 `readerType` 非法 |
| 404 | 会话不存在，或 `readerId` 与会话 / 企业不匹配 |

游标规则：

| 规则 | 说明 |
| --- | --- |
| 只前进 | 提交小于当前游标的值不生效，也不会报错 |
| 自动夹紧 | 大于会话最新序号时按最新序号记录 |
| 重复安全 | 同一游标重复提交不会重复产生 Webhook |
| 多设备共用 | 同一用户多设备共用 `readerId`，取最大值 |
| 送达不等于已读 | 两个游标分别记录，`deliveredSequence` 大于 `readSequence` 是正常状态 |

## 群聊接口

群聊接口全部需要套餐能力 `groups`，群必须是客户服务群（`kind` 为 `SERVICE`）且绑定生效的客服入口。用户标识统一使用你系统的 `externalId`，通语只在对应入口下建立 visitor 映射，不会镜像你的用户库，也不会创建坐席账号。

### 群容量与角色规则

| 项 | 规则 |
| --- | --- |
| 单次加人 | 1～50 人 |
| 群容量范围 | 2～5000 人 |
| 容量默认值 | 数据库列默认 100（历史群）；开放接口建群未传时 2000 |
| 容量下调 | 不能小于当前成员数，否则 `409` |
| 管理动作鉴权 | 除详情与退群外都要求 `actorExternalId` 为群主 |
| 加人权限 | 宿主群（群主为外部用户）仅群主可加人 |
| 邀请链接 | 有效期 24 小时，新邀请生成时旧邀请全部失效 |

### 创建群

| 项 | 值 |
| --- | --- |
| 方法 | POST |
| 路径 | `/api/v1/open/groups` |
| 权限 | write |

**请求参数**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `inboxKey` | string | 是 | 群绑定的客服入口 Key |
| `externalGroupId` | string | 是 | 你的群唯一标识，1～200 字符，用作幂等键 |
| `name` | string | 是 | 群名，1～120 字 |
| `owner` | object | 是 | `externalId` + `displayName`，群主 |
| `members` | object[] | 否 | 初始成员，最多 99 人，结构与群主相同 |
| `maxMembers` | int | 否 | 2～5000，默认 2000 |
| `speakingMode` | string | 否 | `ALL`（默认）或 `MANAGERS`（仅群主与管理员可发言） |
| `requireIdentity` | boolean | 否 | 默认 `true`，要求入群者使用已实名身份 |

**请求示例**

```http
POST /api/v1/open/groups HTTP/1.1
Host: chat.example.com
X-TongYu-Key: <服务端密钥>
Content-Type: application/json

{
  "inboxKey": "ib_9f2c4a",
  "externalGroupId": "shop-8801-vip",
  "name": "8801 店 VIP 福利群",
  "owner": { "externalId": "staff-2001", "displayName": "店长小王" },
  "members": [
    { "externalId": "user-1001", "displayName": "张三" },
    { "externalId": "user-1002", "displayName": "李四" }
  ],
  "maxMembers": 2000,
  "speakingMode": "ALL"
}
```

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` / `groupId` | string | 群 ID，两者相同，便于前端直接取用 |
| `created` | boolean | `true` 为新建（`201`），`false` 为命中已有群（`200`） |

**错误码**

| HTTP | 说明 |
| --- | --- |
| 400 | 群名、`externalGroupId`、群主或成员字段不合法；初始成员数超过群容量 |
| 404 | 入口不存在或已停用 |
| 409 | `externalGroupId` 已存在且群主不一致 |

### 群列表

只返回 `externalId` 所在、且由宿主群主管理的群。

| 项 | 值 |
| --- | --- |
| 方法 | GET |
| 路径 | `/api/v1/open/groups` |
| 权限 | read |

**查询参数**

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `externalId` | string | 是 | 当前登录用户，1～200 字符 |
| `limit` | int | 否 | 默认 50，上限 100 |
| `offset` | int | 否 | 默认 0 |

**响应示例**

```json
{
  "items": [
    {
      "id": "3e4f...5a6b",
      "name": "8801 店 VIP 福利群",
      "externalGroupId": "shop-8801-vip",
      "ownerExternalId": "staff-2001",
      "archived": false,
      "dissolved": false
    }
  ],
  "limit": 50,
  "offset": 0
}
```

### 群详情

| 项 | 值 |
| --- | --- |
| 方法 | GET |
| 路径 | `/api/v1/open/groups/{id}` |
| 权限 | read |

**查询参数**

| 参数 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `externalId` | string | 是 | 必须是该群成员，用于鉴权 |

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` / `name` / `externalGroupId` | string | 群标识与名称 |
| `announcement` | string | 群公告 |
| `ownerExternalId` | string | 群主 |
| `archived` / `dissolved` | boolean | 归档与解散状态 |
| `speakingMode` | string | `ALL` / `MANAGERS` |
| `maxMembers` | int | 群容量 |
| `requireIdentity` | boolean | 是否要求实名入群 |
| `members[]` | object | `externalId`、`displayName`、`isOwner`、`isManager` |

**响应示例**

```json
{
  "id": "3e4f...5a6b",
  "name": "8801 店 VIP 福利群",
  "externalGroupId": "shop-8801-vip",
  "announcement": "每周三上新",
  "ownerExternalId": "staff-2001",
  "archived": false,
  "dissolved": false,
  "speakingMode": "ALL",
  "maxMembers": 2000,
  "requireIdentity": true,
  "members": [
    { "externalId": "staff-2001", "displayName": "店长小王", "isOwner": true, "isManager": false },
    { "externalId": "user-1001", "displayName": "张三", "isOwner": false, "isManager": false }
  ]
}
```

### 修改群资料

| 项 | 值 |
| --- | --- |
| 方法 | PATCH |
| 路径 | `/api/v1/open/groups/{id}` |
| 权限 | write |

**请求参数**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `actorExternalId` | string | 是 | 操作人，必须是群主 |
| `name` | string | 否 | 1～120 字 |
| `announcement` | string | 否 | 最多 2000 字 |

**响应示例**

```json
{ "ok": true }
```

### 转让群主

| 项 | 值 |
| --- | --- |
| 方法 | PUT |
| 路径 | `/api/v1/open/groups/{id}/owner` |
| 权限 | write |

**请求参数**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `actorExternalId` | string | 是 | 当前群主 |
| `ownerExternalId` | string | 是 | 新群主，必须是现有成员，否则 `400` |

**响应示例**

```json
{ "ok": true }
```

### 设置群管理员

| 项 | 值 |
| --- | --- |
| 方法 | PUT |
| 路径 | `/api/v1/open/groups/{id}/manager` |
| 权限 | write |

**请求参数**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `actorExternalId` | string | 是 | 操作人，必须是群主 |
| `externalId` | string | 是 | 目标成员 |
| `isManager` | boolean | 是 | `true` 授权，`false` 取消 |

**错误码**：`404` 表示目标用户不在群里，需先加人。

**响应示例**

```json
{ "ok": true }
```

### 设置群规则

| 项 | 值 |
| --- | --- |
| 方法 | PATCH |
| 路径 | `/api/v1/open/groups/{id}/policy` |
| 权限 | write |

**请求参数**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `actorExternalId` | string | 是 | 操作人，必须是群主 |
| `speakingMode` | string | 否 | `ALL` / `MANAGERS` |
| `maxMembers` | int | 否 | 2～5000，不能小于当前成员数 |
| `requireIdentity` | boolean | 否 | 是否要求实名入群 |

**错误码**：`400` 发言模式或容量非法；`409` 容量小于现有成员数。

**响应示例**

```json
{ "ok": true }
```

### 生成入群邀请

| 项 | 值 |
| --- | --- |
| 方法 | POST |
| 路径 | `/api/v1/open/groups/{id}/invite` |
| 权限 | write |

**请求参数**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `actorExternalId` | string | 是 | 群主或群管理员，否则 `403` |

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `url` | string | 可直接分享入群链接 |
| `ticket` | string | 邀请码，用于拼你自己的入群入口 |
| `expiresIn` | int | 86400 秒 |

**响应示例**

```json
{
  "url": "https://chat.example.com/groups.html?invite=8f2d...c410",
  "ticket": "8f2d...c410",
  "expiresIn": 86400
}
```

### 按用户 ID 批量加人

| 项 | 值 |
| --- | --- |
| 方法 | POST |
| 路径 | `/api/v1/open/groups/{id}/members` |
| 权限 | write |

**请求参数**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `members` | object[] | 是 | 1～50 条，每条含 `externalId`（1～200）与 `displayName`（最多 120 字，缺省为「客户」） |
| `actorExternalId` | string | 宿主群必填 | 操作人，必须是群主 |

**请求示例**

```http
POST /api/v1/open/groups/3e4f...5a6b/members HTTP/1.1
Host: chat.example.com
X-TongYu-Key: <服务端密钥>
Content-Type: application/json

{
  "actorExternalId": "staff-2001",
  "members": [
    { "externalId": "user-1001", "displayName": "张三" },
    { "externalId": "user-1002", "displayName": "李四" }
  ]
}
```

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `groupId` | string | 群 ID |
| `added` | object[] | 本次新加入，含 `externalId`、`visitorId`、`displayName` |
| `alreadyMembers` | object[] | 原本已是成员，昵称已刷新 |
| `skipped` | object[] | 跳过项，含 `externalId` 与 `reason` |

`skipped` 的 `reason` 取值：`externalId 必须为 1 到 200 个字符`、`请求内重复`、`displayName 最多 120 字`、`群成员已达到上限`。

**响应示例**

```json
{
  "groupId": "3e4f...5a6b",
  "added": [
    { "externalId": "user-1002", "visitorId": "7a8b...1c2d", "displayName": "李四" }
  ],
  "alreadyMembers": [
    { "externalId": "user-1001", "visitorId": "2a7b...9c0d", "displayName": "张三" }
  ],
  "skipped": [
    { "externalId": "user-9999", "reason": "群成员已达到上限" }
  ]
}
```

**错误码**

| HTTP | 说明 |
| --- | --- |
| 400 | 群 ID 非法；不是客户服务群；单次人数超出 1～50 |
| 403 | 群主校验不通过，仅群主可添加成员 |
| 404 | 群不存在或不属于当前企业；入口不存在或已停用 |
| 409 | 群已归档或解散，不能加人 |

### 移除成员或退群

| 项 | 值 |
| --- | --- |
| 方法 | DELETE |
| 路径 | `/api/v1/open/groups/{id}/members/{externalId}` |
| 权限 | write |

**请求参数**

| 参数 | 位置 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- | --- |
| `externalId` | 路径 | string | 是 | 被移除用户 |
| `actorExternalId` | query | string | 是 | 操作人。等于路径 `externalId` 时视为本人退群，只需是成员；否则必须是群主 |

目标用户不存在时按幂等成功处理。移除群主返回 `409`，请先转让或解散。移除成员会结束该成员进行中的群通话。

**响应示例**

```json
{ "ok": true }
```

### 解散群

| 项 | 值 |
| --- | --- |
| 方法 | POST |
| 路径 | `/api/v1/open/groups/{id}/dissolve` |
| 权限 | write |

**请求参数**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `actorExternalId` | string | 是 | 群主 |

效果：标记解散并归档、撤销全部邀请、结束进行中的通话。已解散的群重复调用返回成功。

**响应示例**

```json
{ "ok": true }
```

### 为已入群用户签发群会话令牌

用户打开群页时，由你的后端校验本站登录态后调用本接口取令牌，前端写入 `sessionStorage` 后打开群页。

| 项 | 值 |
| --- | --- |
| 方法 | POST |
| 路径 | `/api/v1/open/groups/{id}/member-token` |
| 权限 | write |

**请求参数**

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `externalId` | string | 是 | 已入群用户，1～200 字符 |

**响应参数**

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `token` | string | 访客令牌，按访客端接口使用 |
| `visitorId` | string | 该用户在此入口下的访客 ID |
| `groupId` | string | 群 ID |
| `expiresIn` | int | 令牌有效期秒数，由服务端 `WIDGET_TOKEN_TTL` 决定 |

**响应示例**

```json
{
  "token": "eyJhbGciOi...",
  "visitorId": "2a7b...9c0d",
  "groupId": "3e4f...5a6b",
  "expiresIn": 43200
}
```

**错误码**

| HTTP | 说明 |
| --- | --- |
| 400 | `externalId` 为空或超长 |
| 403 | 套餐未含群聊能力 |
| 404 | 群不存在；用户不是群成员（提示先加人） |
| 409 | 群已归档或解散 |

> 企业版也可以继续用 `POST /api/v1/open/visitor-identity` 加 `/api/v1/groups/session` 的组合，见 `groups-api.md`。

## 数据结构

### 会话对象

会话列表、会话详情、更新会话、创建会话共用同一结构。带「条件返回」的字段在缺省时不出现。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | 会话 ID |
| `tenantId` | string | 企业 ID |
| `inboxId` | string | 所属入口 ID |
| `visitorId` | string | 客户 ID，回执 `readerId` 用它 |
| `subject` | string | 主题，条件返回 |
| `status` | string | `OPEN` / `PENDING` / `RESOLVED` |
| `priority` | int | 优先级 |
| `source` | string | 来源，如 `WEB`、`API`、`APP` |
| `assigneeId` | string | 当前接待坐席，未分配时不出现 |
| `assigneeName` | string | 坐席姓名，条件返回 |
| `acceptedAt` | string | 接单时间，条件返回 |
| `assignmentExpiresAt` | string | 分配到期时间，条件返回 |
| `handoffRequestedAt` | string | 客户请求人工的时间，条件返回 |
| `closedAt` | string | 结束时间，条件返回 |
| `reopenGraceMinutes` | int | 结束后可继续的原会话窗口分钟数，条件返回 |
| `lastSequence` | int64 | 当前最新消息序号 |
| `lastMessagePreview` | string | 最后消息摘要，条件返回 |
| `lastMessageAt` | string | 最后消息时间，条件返回 |
| `agentUnread` | int | 客服侧未读客户消息数 |
| `visitorUnread` | int | 客户侧未读坐席公开消息数，不含内部备注 |
| `visitorName` | string | 客户昵称，条件返回 |
| `tags` | string[] | 标签名，条件返回 |
| `createdAt` / `updatedAt` | string | 创建与更新时间 |

### 消息对象

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | 消息 ID |
| `conversationId` | string | 所属会话 |
| `senderType` | string | `VISITOR` / `AGENT` / `SYSTEM` |
| `senderId` | string | 发送者 ID，条件返回 |
| `senderName` | string | 展示署名，条件返回 |
| `clientMessageId` | string | 幂等键回显，条件返回 |
| `sequence` | int64 | 会话内序号 |
| `messageType` | string | `TEXT`、`IMAGE`、`FILE`、`RICH`、`AUDIO`、`VIDEO`、`LOCATION`、`CARD`、`EVENT`、`SYSTEM`、`RATING` |
| `content` | string | 正文 |
| `metadata` | object | 自定义字段，条件返回 |
| `attachments` | object[] | 附件 `id`、`fileName`、`contentType`、`sizeBytes`、`url`，条件返回 |
| `private` | boolean | 内部备注标记；客户身份永远为假，开放接口默认不返回此类消息 |
| `replyToId` / `replyTo` | string / object | 引用回复，条件返回 |
| `reactions` | object[] | 表情回应，条件返回 |
| `editedAt` / `deletedAt` | string | 编辑与撤回时间，条件返回 |
| `pinnedAt` | string | 置顶时间，条件返回 |
| `createdAt` | string | 发送时间 |

## 未读与已读

### 字段语义

| 字段 | 含义 | 注意 |
| --- | --- | --- |
| `agentUnread` | 该会话中客服侧未读的客户消息数 | 是整条会话的共享接待未读，任一客服读取即更新，不等于每个客服单独的收件箱未读 |
| `visitorUnread` | 该会话中客户侧未读的坐席公开消息数 | 内部备注不计入 |
| `unreadConversations` | 任一侧未读大于 0 的会话数 | 不等于「客服还没回复的会话数」 |

### 序号与游标

消息序号在会话内递增，但序号差不能换算成未读条数：区间内可能夹有客户自行发送的消息、内部备注、系统事件。真实游标只认回执中的 `readSequence`，不要用 `lastSequence - unread` 反推。

### 上报时机

| 游标 | 何时上报 |
| --- | --- |
| `delivered` | 消息进入本地列表即可上报 |
| `read` | 仅当会话正在显示、页面在前台且用户确实看到时上报 |

不要在收到推送时直接清零。官方聊天页与客服工作台已按此规则实现：工作台滚动查看历史不会自动把最新消息标为已读。

## 单人未读角标

`GET /api/v1/open/unread` 是企业全部会话的合计，不能当作某一个用户的角标，也不要把企业合计暴露给客户。

单个登录用户的角标按下面步骤计算：

1. 用该用户的 `externalId` 与对应入口的 `inboxKey` 调用 `POST /api/v1/open/visitor-identity` 签发身份票据。
2. 用票据调用 `POST /api/v1/widget/bootstrap` 换取访客令牌。
3. 用令牌调用 `GET /api/v1/widget/conversations`。
4. 把返回列表中每条会话的 `visitorUnread` 相加，即为该用户在该入口下的角标。

| 规则 | 说明 |
| --- | --- |
| 按入口分开计算 | 同一用户在不同客服入口的会话相互独立，角标不能混加 |
| 使用官方聊天页 | 页面在用户查看时自行上报已读，你的后端只需重新计算合计 |
| 自建消息列表 | 由你的后端按序号调用 `POST /api/v1/widget/conversations/{id}/read`，正文为 `{"sequence": 12}`，成功返回 `{"status":"OK"}` |
| 服务端代报 | 也可用服务端密钥调用 `POST /api/v1/open/conversations/{id}/read`，`readerId` 填该用户的 `visitorId` |

### 会话结束后再咨询

| 行为 | 说明 |
| --- | --- |
| 客户再次发言 | 自动开始新会话（若已有未结束会话则复用），未结束会话按入口规则重新分配 |
| 旧会话 | 保持已结束，系统提示留在原会话，不会被重新打开 |
| 角标 | 新一轮未读记在新会话的 `visitorUnread` 上，仍是列表全部 `visitorUnread` 之和 |
| 客服 | 不能在已结束的原会话继续公开回复，返回 `403 CONVERSATION_CLOSED` |

## Webhook 回调

回调地址配置、完整事件正文与管理操作见 `webhook.md`，本节给出对接必须知道的契约。

### 可订阅事件

| 事件 | 触发时机 | 正文要点 |
| --- | --- | --- |
| `message.created` | 客户发送消息 | `conversationId`、`message`（消息对象）、`senderType` |
| `message.agent` | 坐席或开放接口发出消息 | 同上 |
| `conversation.created` | 新会话产生（含结束后再咨询自动开的新一轮） | `conversationId`、`visitorId`、`inboxId` |
| `conversation.updated` | 开放接口更新会话 | `conversationId`、`status` |
| `conversation.closed` | 会话结束 | `conversationId`、`closedBy`、`closedAt`；空闲自动结束时 `closedBy` 为 `null` |
| `conversation.read` | 已读游标前进 | `conversationId`、`readerType`、`readerId`、`sequence` |
| `conversation.delivered` | 送达游标前进 | 同上 |
| `visitor.created` | 新访客建档 | `visitorId`、`inboxId`、`displayName`、`externalId`、`email`、`phone`、`createdAt` |
| `webhook.test` | 管理端点击发送测试 | `test`、`tenantId`、`sentAt`、`message` |

回执事件不包含消息正文。`message.updated`、`message.deleted`、`conversation.rated` 已在平台事件表中，但暂不在管理端订阅白名单内。

### 投递请求

| 项 | 值 |
| --- | --- |
| 方法 | POST |
| `Content-Type` | `application/json` |
| 请求头 | `X-TongYu-Event`、`X-TongYu-Delivery`、`X-TongYu-Timestamp`、`X-TongYu-Signature` |
| 成功判定 | 2xx |
| 超时 | 10 秒 |
| 尝试次数 | 默认 6 次，`WEBHOOK_MAX_ATTEMPTS` 可调 |
| 重试间隔 | 10 秒、30 秒、2 分钟、10 分钟、30 分钟、1 小时 |
| 送达语义 | 至少一次，接收方必须幂等 |

`X-TongYu-Timestamp` 为秒级时间戳，`X-TongYu-Delivery` 为本次投递 ID。

### 签名校验

签名算法为 HMAC-SHA256，原文是 `<时间戳>.<原始请求体>`，请求头值为 `sha256=` 加十六进制摘要。密钥是该回调地址自己的签名密钥，不是服务端密钥。

**接收端要求**

| 要求 | 说明 |
| --- | --- |
| 用原始字节验签 | 不要先解析 JSON 再序列化，字段顺序或空白变化会导致验签失败 |
| 校验时间窗口 | 建议拒绝偏离当前时间 5 分钟以上的请求（服务端不校验，由接收端负责） |
| 先持久化再返回 2xx | 落库成功才返回 2xx，否则会被重试 |
| 按投递 ID 去重 | 同一事件可能重复投递 |
| 游标取最大值 | 按 `conversationId + readerType + readerId + 事件类型` 保留更大 `sequence`，防止乱序回退 |

**校验示例（Python）**

```python
import hashlib, hmac, time

raw = request.body  # 原始字节，不要解析后再序列化
stamp = request.headers['X-TongYu-Timestamp']
if abs(time.time() - int(stamp)) > 300:
    return 401
expected = 'sha256=' + hmac.new(
    secret.encode(), stamp.encode() + b'.' + raw, hashlib.sha256).hexdigest()
if not hmac.compare_digest(expected, request.headers['X-TongYu-Signature']):
    return 401
# 保存投递 ID 去重记录与最大 sequence 后返回 200
```

### 回执事件正文示例

```json
{
  "conversationId": "5b0f...9c0d",
  "readerType": "VISITOR",
  "readerId": "2a7b...9c0d",
  "sequence": 12
}
```

上报回执与 Webhook 入队在同一事务完成，游标没有前进时不会重复入队。

## 嵌入方式与职责划分

| 场景 | 用什么 | 参考 |
| --- | --- | --- |
| 用户端页面嵌聊天窗 | iframe `/h5/{inboxKey}` 或脚本 `/widget.js` | `integrations.md` |
| CRM、订单系统读写会话 | 本文开放接口（服务端） | 本文 |
| 实时推送到业务系统 | Webhook | `webhook.md` |
| 第三方网站建群与管理群 | 本文群聊接口 | 本文 |
| 群页与群通话前端 | 访客令牌 + 群接口 | `groups-api.md` |
| 客服工作台 | 工作台自身功能，不需要对接 | — |

> 客服工作台的新消息提示音与浏览器推送属于工作台功能，与开放接口无关。Web Push 需要 HTTPS、Service Worker 与用户主动授权，且受系统与浏览器后台策略限制，不能承诺必达；iPhone 需 iOS 16.4 以上并从添加到主屏幕的网页应用打开。此能力不等于原生 App 的 APNs 或 FCM 集成。

## 最小接入流程

1. 管理员在控制台「应用接入 → 服务端密钥」创建 `read` 与 `write` 密钥，确认套餐已开通 `integrations`、`identity`、`groups` 中所需能力。
2. 调 `GET /api/v1/open/me` 验证密钥、环境与权限。
3. 前端嵌官方聊天页，或自建消息列表并接访客端接口。
4. 需要业务侧同步时订阅 `message.created` 与 `message.agent`，按上文校验签名。
5. 消息到达设备后按该消息序号上报 `delivered`，用户实际看到后上报 `read`，两者分别记录。
6. 用 `GET /api/v1/open/conversations/{id}/receipts` 获取权威游标；断线后从消息列表的 `after` 参数与回执重新同步，未读统计可低频轮询作为补偿。
7. 网络错误或 `5xx` 时保留本地未读并重试，不要假定已经读取成功。

## 常见问题

| 问题 | 回答 |
| --- | --- |
| 密钥丢失怎么办 | 无法找回，只能新建并替换配置；旧密钥请及时撤销 |
| 能改派坐席吗 | 开放接口的 PATCH 不支持改派，改派在客服工作台或坐席控制台接口完成 |
| 能发图片文件吗 | 开放接口没有上传通道，只发送文本与你自有存储的 URL |
| 为什么 `404` 而不是 `403` | 跨企业资源统一按不存在处理，避免探测资源是否存在 |
| 未读能推算已读序号吗 | 不能，只用回执 `readSequence` |
| 已读与送达能合并成一个吗 | 不能，产品语义不同，`delivered` 不代表用户看过 |
| 会话结束后还能回复吗 | 客服侧不能；客户再发言会开新一轮会话 |
| 接口返回中文错误 | `message` 面向人工排查，程序判断依赖 `status` 与 `code`，不要匹配中文文案 |

## 变更记录

| 日期 | 变更 |
| --- | --- |
| 2026-11-02 | 重构为传统接口文档结构：补齐全量接口的请求参数表、响应参数表与错误码；订正错误码清单、权限范围、限流与套餐能力；群聊 12 个接口首次完整收录；新增数据结构、常见问题与变更记录 |
