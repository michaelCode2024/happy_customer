# 开放 API（宿主业务系统）

第三方在自己的网站或 App 建群、指定群主、管理成员及解散群，请看 [第三方群聊接入](第三方群聊接入.md)。全程使用第三方用户 ID，无需为用户创建客服账号。

租户后端用 API Key 调用。密钥在管理端创建，请求头：

```http
X-TongYu-Key: <api-key>
Content-Type: application/json
```

Base：`{PUBLIC_BASE_URL}/api/v1/open`

权限：`read` / `write`（创建密钥时勾选）。所有数据按密钥所属租户隔离，路径与 Body 不能跨租户。

## 接口一览

| 方法 | 路径 | 权限 | 说明 |
|------|------|------|------|
| GET | `/me` | read | 当前密钥与租户信息 |
| POST | `/visitor-identity` | write | 签发当前登录客户的短期身份票据，见 [开通与接入](saas-onboarding.md) |
| GET | `/conversations` | read | 会话列表（支持状态/分页查询参数，见响应） |
| GET | `/conversations/{id}` | read | 会话详情 |
| GET | `/conversations/{id}/messages` | read | 消息列表（支持 `after` / `before` 增量） |
| POST | `/conversations/{id}/messages` | write | 代发消息（坐席侧内容） |
| PATCH | `/conversations/{id}` | write | 更新状态、分配等 |
| GET | `/visitors` | read | 访客列表 |
| GET | `/visitors/{id}` | read | 访客详情 |
| POST | `/visitors/{id}/conversations` | write | 为访客开会话 |
| GET | `/agents` | read | 坐席列表 |
| GET | `/stats` | read | 租户统计摘要 |
| POST | `/groups/{id}/members` | write | 按宿主 `externalId` 批量加入客户服务群（需套餐含群聊） |
| POST | `/groups/{id}/member-token` | write | 为已入群的 `externalId` 签发群聊会话 token |

## 按宿主用户加入群聊

套餐需包含群聊。群必须是客户服务群（`SERVICE`），visitor 落在该群绑定的客服入口下，与一对一 `externalId` 规则相同。

```http
POST /api/v1/open/groups/<group-id>/members
X-TongYu-Key: <server-api-key>
Content-Type: application/json

{
  "members": [
    {"externalId": "user-1001", "displayName": "张三"},
    {"externalId": "user-1002", "displayName": "李四"}
  ]
}
```

- 每次 1～50 人；按群的maxMembers限制，旧群默认100人、新建外部群默认2000人，群主可设置2至5000人。具体规则见[第三方群聊接入](第三方群聊接入.md)。
- 响应：`added` / `alreadyMembers` / `skipped`（含 `reason`）。重复 `externalId` 幂等，已是成员时更新群昵称。
- 不创建对方用户库镜像；只存「此入口下的 visitor + 群成员」映射。

已入群用户打开群页时，由你的后端校验本站登录后签发会话：

```http
POST /api/v1/open/groups/<group-id>/member-token
X-TongYu-Key: <server-api-key>
Content-Type: application/json

{"externalId":"user-1001"}
```

返回 `token`、`visitorId`、`groupId`、`expiresIn`。企业版也可继续用 `/visitor-identity` + `/api/v1/groups/session`（见 [群聊 API](groups-api.md)）。

## 与 iframe 嵌入的分工

| 场景 | 用法 |
|------|------|
| 用户端页面嵌聊天窗 | iframe `/h5/{inboxKey}` 或脚本 `/widget.js`，见 [integrations.md](integrations.md) |
| CRM / 订单系统读写会话 | 本 Open API（服务端） |
| 实时推送到业务系统 | Webhook（管理端配置） |

不要把 API Key 放进前端或 iframe 页面。

## 错误

JSON：`{ "status": 401, "code": "...", "message": "...", "timestamp": "..." }`。常见：API_KEY_REQUIRED、API_KEY_INVALID、FORBIDDEN。

## 新消息、未读与回执接入

适用于专业版及以上的服务端开放 API。企业版提供身份票据签发。API Key 只能保存在你的后端，前端通过自己的业务接口转发查询；你的后端必须校验当前用户与 visitorId / readerId 的关联。

| 方法 | 路径 | 权限 | 用途 |
| --- | --- | --- | --- |
| GET | `/unread` | read | 企业未读汇总：agentUnread、visitorUnread、unreadConversations |
| GET | `/conversations/{id}/receipts` | read | 返回各读取者的 readSequence、deliveredSequence、updatedAt |
| POST | `/conversations/{id}/read` | write | 上报用户实际看到的最高消息序号 |
| POST | `/conversations/{id}/delivered` | write | 上报设备收到的最高消息序号 |

会话列表和详情也返回 agentUnread、visitorUnread。前者是客服侧未读客户消息数，后者是客户侧未读公开客服消息数；内部备注不计入客户未读。汇总是企业范围；单个客户请从属于该客户的会话汇总，不可把企业汇总暴露给客户。

```http
POST /api/v1/open/conversations/<conversation-id>/read
X-TongYu-Key: <server-api-key>
Content-Type: application/json

{"readerType":"VISITOR","readerId":"<visitor-uuid>","sequence":12}
```

readerType 为 VISITOR / AGENT，readerId 必须属于对应客户会话或企业活跃坐席。sequence 必须大于 0；服务端夹紧到最新序号，游标只前进。重复请求安全。只读到 12 时，之后的消息仍未读；查询 receipts 返回权威游标。AGENT 的未读数是会话的共享接待未读，任一客服读取后更新共享未读，不等于每个客服单独的收件箱。

收到消息即可上报 delivered；只有会话正在显示、页面在前台且用户正在查看时才上报 read。不要在收到推送时直接全部清零。聊天组件与客服工作台已采用这一规则；客服滚动查看历史时不自动读取最新消息。

### Webhook 实时同步

企业管理员在「应用接入 → Webhook」勾选 `conversation.read` 与 `conversation.delivered`，已有回调需补选。消息提醒订阅 `message.created` / `message.agent`。回执请求与 Webhook 入队在同一事务完成，重复游标不重复入队；投递按至少一次处理，接收方仍必须幂等。

```json
{"conversationId":"<uuid>","readerType":"VISITOR","readerId":"<uuid>","sequence":12}
```

请求头 `X-TongYu-Event` 标识事件类型，`X-TongYu-Delivery` 为投递 ID；按照已有 `X-TongYu-Timestamp` 与 `X-TongYu-Signature` 校验 HMAC-SHA256：签名原文为 `<timestamp>.<原始请求体>`，请求头值为 `sha256=<十六进制签名>`。校验时间窗口，使用原始字节，成功持久化后返回 2xx；失败会重试。按投递 ID 去重，并按 `(conversationId,readerType,readerId,eventType)` 取最大 sequence，防止乱序回调回退。

### 工作台提醒

「个人设置」提供新消息提示音、测试提示音与桌面通知开关。浏览器首次交互后才允许播放声音；桌面通知需用户点击开启并授权，不支持或拒绝时保留提示音与未读角标。通知仅显示通用提醒，不在操作系统展示客户消息正文。连续消息在 1.5 秒内合并提醒。网页完全关闭时不会继续收到提醒，本次不包含原生 App 推送服务。


### 最小接入流程与返回值

1. 管理员在「接入 → 服务端密钥」建立 read/write 密钥；未读与回执使用专业版及以上开放 API。
2. 消息到达你的设备后，用该消息的 sequence 调用 delivered；用户实际看到后再调用 read。二者分别记录，不要用送达代替已读。
3. 查询 receipts 获取权威游标；同一用户多设备共用 readerId，提交较小游标不会回退。read/delivered 成功响应均为 200 和当前 receipts 列表。
4. 订阅回执 Webhook 实时更新你自己的业务界面；断线后从 messages 的 after 参数和 receipts 重新同步。未读统计可低频轮询作为补偿。

```json
{"agentUnread":3,"visitorUnread":1,"unreadConversations":2}
```

```json
{"items":[{"readerType":"VISITOR","readerId":"<uuid>","readSequence":12,"deliveredSequence":15,"updatedAt":"2026-10-11T12:00:00Z"}]}
```

`unreadConversations` 统计两侧任一未读大于零的会话，不等于只包含客服未读的会话。消息序号不是未读条数，不能用 lastSequence 减 unread 推算真实已读游标，因为其中可能夹有客户自发消息、内部备注等。游标请始终使用 receipts 中的 readSequence。

400 表示无效字段或 sequence ≤ 0；401 表示密钥无效；403 表示权限或套餐不足；404 表示会话不存在、不属于该企业或 readerId 与会话不匹配。网络或 5xx 错误时保留本地未读并重试，不应假定已成功读取。旧客户端的 read 请求如果没有 sequence，需要升级为携带正数边界。

回调正文就是前述回执 JSON，不包含消息正文。签名校验示例（接收服务器伪代码）：

```python
import hashlib, hmac, time
raw = request.body  # 原始字节，不要 JSON 解析后再序列化
stamp = request.headers['X-TongYu-Timestamp']
if abs(time.time() - int(stamp)) > 300:
    return 401
expected = 'sha256=' + hmac.new(secret.encode(), stamp.encode() + b'.' + raw, hashlib.sha256).hexdigest()
if not hmac.compare_digest(expected, request.headers['X-TongYu-Signature']):
    return 401
# 持久化投递 ID 去重与最大 sequence，再返回 200
```
