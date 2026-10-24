# Widget HTTP 与实时消息 API

2026-10-23 对照当前路由复核。基础地址为目标实例的 `{BASE_URL}`；生产使用 HTTPS 和 WSS。本机端口应从实际实例取得，不使用文档端口推定运行状态。

## 初始化

`POST /api/v1/widget/bootstrap`

```json
{
  "inboxKey": "网站公开入口 Key",
  "identityToken": "业务后端签发的身份票据（关联账号时提供）",
  "displayName": "访客昵称（可选）"
}
```

响应中的 `token` 用于后续请求：`Authorization: Bearer <token>`。

匿名咨询仅需 inboxKey。关联已登录账号，由客户业务后端使用 write 权限的 APIKey 调用 `POST /api/v1/open/visitor-identity`，提交 inboxKey、externalId、displayName，取得 5 分钟有效的 identityToken。前端不能再单独提交裸 externalId；详见 [接入指南](integrations.md)。

## 会话

- `POST /api/v1/widget/conversations`：创建会话
- `GET /api/v1/widget/conversations`：访客的会话列表
- `GET /api/v1/widget/conversations/{id}/messages?after=0`：增量拉取消息，最多 100 条
- `POST /api/v1/widget/conversations/{id}/messages`：发送文本消息

发送消息示例：

```json
{
  "clientMessageId": "浏览器生成的幂等 ID",
  "content": "你好，我需要帮助"
}
```

## 实时连接

连接 `wss://<客服域名>/ws/widget?token=<token>`。以下事件仅展示字段形式，完整结构以当前接口返回为准：

```json
{
  "type": "message.created",
  "data": {
    "conversationId": "...",
    "sequence": 1,
    "content": "你好，我需要帮助"
  }
}
```

Token 放在查询参数是浏览器原生 WebSocket API 的兼容方案。生产日志和反向代理必须关闭或脱敏该路径的查询参数。
