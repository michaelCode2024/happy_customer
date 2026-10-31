# Webhook 与两套密钥

业务系统接收通语事件时用本文。开放 API 的路径和权限见 [open-api.md](open-api.md)。

## 两套密钥不能互换

| | 服务端 API Key | Webhook 签名密钥 |
| --- | --- | --- |
| 用途 | 请求头 `X-TongYu-Key`，调用 `/api/v1/open/` | 只用于校验 `X-TongYu-Signature` |
| 形态 | `rdk_` 加 24 字节的 base64url | 32 字节的 base64url，没有 `rdk_` 前缀 |
| 何时能看到全文 | 创建成功那一次响应里的 `key` | 创建回调时响应里的 `secret`；轮换时响应里的新 `secret` |
| 列表接口 | 只返回 `keyPrefix`，即全文前 12 个字符 | 不返回 `secret` |

库里只存 API Key 的哈希。列表上的前缀不能还原全文。创建响应没保存下来，就撤销旧密钥再创建一把，把新的 `key` 原样写入业务配置。不要凭截图或前缀补全后面的字符。base64url 里数字 `0` 和字母 `O`、数字 `1` 和字母 `l` / `I` 都是不同字符，写错一位时开放 API 返回 `401` / `API_KEY_INVALID`。

Webhook 签名密钥以明文存在回调配置里，但查询列表不带回它。丢了就对那条回调执行轮换，用新 `secret` 更新接收方。不要把 API Key 填进签名密钥，也不要用签名密钥去调开放 API。

## 谁可以配置

管理接口使用主管坐席的登录 Bearer，不是 `X-TongYu-Key`。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/admin/webhooks` | 列表。含 `availableEvents`。不含 `secret` |
| POST | `/api/v1/admin/webhooks` | 创建。`secret` 可省略，省略时由服务端生成 |
| PATCH | `/api/v1/admin/webhooks/{id}` | 改地址、状态、事件；`rotateSecret: true` 时换签名密钥 |
| DELETE | `/api/v1/admin/webhooks/{id}` | 删除 |
| GET | `/api/v1/admin/webhooks/{id}/deliveries?limit=50` | 投递记录，`limit` 最大 200 |
| POST | `/api/v1/admin/webhooks/{id}/test` | 入队一条 `webhook.test` |

创建：

```http
POST /api/v1/admin/webhooks
Authorization: Bearer <主管坐席令牌>
Content-Type: application/json

{
  "url": "https://api.example.com/hooks/tongyu",
  "events": ["message.agent", "message.created"],
  "secret": "可选；留空则响应里带回新生成的密钥"
}
```

`201` 响应含 `id`、`url`、`secret`、`events`。`secret` 只在这次响应和之后的轮换响应里出现。

地址必须以 `http://` 或 `https://` 开头。`events` 至少要有一个合法事件，未知名称会被丢掉。可订阅的事件：

| 事件 | 何时入队 |
| --- | --- |
| `message.agent` | 坐席发出的公开消息 |
| `message.created` | 访客发出的公开消息 |
| `conversation.created` | 会话创建 |
| `conversation.updated` | 会话更新 |
| `conversation.closed` | 会话关闭 |
| `visitor.created` | 访客创建 |
| `conversation.read` | 已读游标前进 |
| `conversation.delivered` | 送达游标前进 |

内部备注不入队。坐席公开消息只发 `message.agent`，不会再发一条 `message.created`。入门版、成长版、企业版且订阅有效才会入队；试用版不发。

轮换：

```json
{ "rotateSecret": true }
```

`200` 的 `secret` 为新密钥。未轮换时 `secret` 为空字符串，旧密钥不变。`status` 只能是 `ACTIVE` 或 `DISABLED`。

## 投递请求

```http
POST <回调地址>
Content-Type: application/json
X-TongYu-Event: message.agent
X-TongYu-Delivery: <投递 UUID>
X-TongYu-Timestamp: <Unix 秒>
X-TongYu-Signature: sha256=<十六进制 HMAC>
```

签名原文是 `<timestamp>.<原始请求体字节>`，密钥是该回调的 `secret`，算法 HMAC-SHA256。用收到的原始字节计算，不要先解析 JSON 再序列化。建议拒绝与当前时间相差超过 300 秒的时间戳。`X-TongYu-Delivery` 作为幂等键；同一投递会重试，重复的要直接返回成功。

坐席公开消息的正文：

```json
{
  "conversationId": "会话 UUID",
  "senderType": "AGENT",
  "message": {
    "id": "消息 UUID",
    "conversationId": "会话 UUID",
    "senderType": "AGENT",
    "senderId": "坐席 UUID",
    "senderName": "坐席显示名",
    "sequence": 27,
    "messageType": "TEXT",
    "content": "消息正文",
    "createdAt": "2026-10-30T14:43:07.978Z"
  }
}
```

这里没有业务侧用户 ID。`message.created` 的 `senderType` 为 `VISITOR`。已读、送达的正文见 [open-api.md](open-api.md) 的回执一节。测试事件 `webhook.test` 的正文含 `test`、`tenantId`、`sentAt`、`message`。

## 从回调找到业务用户

消息回调只有通语的 `conversationId`。接收方用**同一租户**、带 `read` 权限的 API Key 再查两次：

```http
GET /api/v1/open/conversations/<conversationId>
X-TongYu-Key: <api-key>
```

响应里的 `visitorId` 再查：

```http
GET /api/v1/open/visitors/<visitorId>
X-TongYu-Key: <api-key>
```

访客响应里的 `externalId` 才是业务系统自己的用户标识。密钥无效是 `401` / `API_KEY_INVALID`；会话或访客不属于该密钥的租户是 `404`。这次查询失败就不要对通语返回 `2xx`，否则通语认为已经送达，不会再试。

## 接收方要返回的状态

通语等待最多 10 秒。`2xx` 记为成功。网络错误和其他状态码按下面的间隔重试，默认最多 6 次（含首次）：10 秒、30 秒、2 分钟、10 分钟、30 分钟、1 小时。用尽后状态变为 `FAILED`，不再自动投递。签名错误应返回 `401`，尚未落库或依赖的开放 API 暂时失败应返回非 `2xx`，让通语继续重试。

```python
import hashlib, hmac, time
raw = request.body
stamp = request.headers["X-TongYu-Timestamp"]
if abs(time.time() - int(stamp)) > 300:
    return 401
expected = "sha256=" + hmac.new(
    secret.encode(), stamp.encode() + b"." + raw, hashlib.sha256
).hexdigest()
if not hmac.compare_digest(expected, request.headers["X-TongYu-Signature"]):
    return 401
# 按 X-TongYu-Delivery 去重并完成落库后再返回 200
```
