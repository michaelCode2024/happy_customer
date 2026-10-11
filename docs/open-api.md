# 开放 API（宿主业务系统）

租户后端用 API Key 调用。密钥在管理端创建，请求头：

```http
X-RelayDesk-Key: <api-key>
Content-Type: application/json
```

Base：`{PUBLIC_BASE_URL}/api/v1/open`

权限：`read` / `write`（创建密钥时勾选）。所有数据按密钥所属租户隔离，路径与 Body 不能跨租户。

## 接口一览

| 方法 | 路径 | 权限 | 说明 |
|------|------|------|------|
| GET | `/me` | read | 当前密钥与租户信息 |
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

## 与 iframe 嵌入的分工

| 场景 | 用法 |
|------|------|
| 用户端页面嵌聊天窗 | iframe `/h5/{inboxKey}` 或脚本 `/widget.js`，见 [integrations.md](integrations.md) |
| CRM / 订单系统读写会话 | 本 Open API（服务端） |
| 实时推送到业务系统 | Webhook（管理端配置） |

不要把 API Key 放进前端或 iframe 页面。

## 错误

JSON：`{ "error": { "code": "...", "message": "..." } }`。常见：`API_KEY_REQUIRED`、`API_KEY_INVALID`、`FORBIDDEN`。
