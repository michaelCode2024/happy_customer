# 快速开始

版本 **v1** · 更新日期 **2026-11-02** · 适用服务端 **TongYu 主线**

从零到「客户在网页上发出第一条消息、你的后端收到它」，大约需要 20 分钟。本文只走主路径，细节见各专题文档。

## 0. 准备一个测试企业

运营方用平台管理员账号开通一个企业，拿回企业标识、主管邮箱与初始密码：

```http
POST /api/v1/platform/tenants
Authorization: Bearer <平台管理员令牌>
Content-Type: application/json

{
  "name": "联调测试",
  "slug": "sandbox-demo",
  "ownerEmail": "dev@example.com",
  "inboxName": "联调测试 网站客服",
  "publicKey": "sandbox-web",
  "plan": "TRIAL",
  "trialDays": 14
}
```

响应里的 `inboxId`、`publicKey`、`scriptUrl` 后面都要用到，`initialPassword` 只出现这一次。

> 通语**没有独立的沙箱域名**。测试用独立企业隔离，不要拿生产企业的密钥联调：密钥的作用范围就是企业，用错企业会读到别人的会话。

## 1. 创建服务端密钥

主管账号登录企业工作台，进入「应用接入 → 服务端密钥」，创建一把同时勾选 `read` 与 `write` 的密钥。

密钥只在创建成功的那一次响应里显示全文，之后列表只返回前 12 位前缀。**丢失无法找回，只能新建并替换配置。**

密钥只放在你的后端。它出现在浏览器、App 安装包或聊天页面里，等于把整个企业的会话数据交出去。

## 2. 验证密钥

先调这个接口确认环境、权限都对，再去排查业务接口的报错：

```bash
curl -X GET 'https://chat.example.com/api/v1/open/me' \
  -H 'X-TongYu-Key: rdk_你的密钥'
```

返回 `tenant`、`keyName`、`scopes`、`inboxes`、`agents`、`openConversations`。`scopes` 里没有 `write` 说明密钥权限建少了。

## 3. 把聊天入口放到页面上

两种方式，任选其一。

**脚本方式**（推荐，自动处理主题、未读与实时连接）：

```html
<script>
  window.TongYuSettings = {
    endpoint: 'https://chat.example.com',
    inboxKey: 'sandbox-web'
  };
</script>
<script src="https://chat.example.com/widget.js" async></script>
```

**iframe 方式**（已有页面结构，或要放进 App 的 WebView）：

```html
<iframe
  src="https://chat.example.com/h5/sandbox-web?parentOrigin=https://app.example.com"
  style="border:0;width:100%;height:100%;min-height:520px"
  allow="microphone;clipboard-write"
></iframe>
```

`allow="microphone;clipboard-write"` 不能省：缺了它，浏览器直接拒绝麦克风授权，语音按钮点了没反应。

到这一步，匿名访客已经能发消息了。打开页面发一条，工作台的「待接待」里应该能看到。

## 4. 关联已登录客户

匿名访客没有业务身份，会话对不上你的用户。要让客服看到「这是哪位客户」，由你的后端签发票据：

```bash
curl -X POST 'https://chat.example.com/api/v1/open/visitor-identity' \
  -H 'X-TongYu-Key: rdk_你的密钥' \
  -H 'Content-Type: application/json' \
  -d '{"inboxKey":"sandbox-web","externalId":"user-1001","displayName":"张三"}'
```

响应里的 `identityToken` 交给前端，写进 `TongYuSettings` 即可：

```js
window.TongYuSettings = {
  endpoint: 'https://chat.example.com',
  inboxKey: 'sandbox-web',
  identityToken: identity.identityToken   // 由你的后端返回，不要在前端自己拼
};
```

票据 300 秒有效、一次性使用。**必须由后端在校验登录态之后签发**——票据本身不校验登录态，任何人拿到都能用 5 分钟。前端提交裸 `externalId` 会被拒绝（`IDENTITY_TOKEN_REQUIRED`）。

## 5. 接收事件

到「应用接入 → Webhook」建一条回调，勾选 `message.created`、`message.agent`、`conversation.created`、`conversation.closed`。

回调地址必须公网可达、5 秒内返回 `2xx`。签名原文是 `<timestamp>.<原始请求体字节>`，用 HMAC-SHA256 计算后与 `X-TongYu-Signature` 比较，并按 `X-TongYu-Delivery` 去重。

> 试用企业可以正常调用开放接口，但 **Webhook 不入队**，只有入门版、成长版、企业版且订阅有效才会投递。要验证回调链路，需要一个付费套餐的测试企业。

## 常见卡点

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `401 API_KEY_INVALID` | 密钥写错一位，或用了 Webhook 签名密钥 | 密钥区分 `0`/`O`、`1`/`l`，且签名密钥没有 `rdk_` 前缀；两者不能互换 |
| `403 SCOPE_REQUIRED` | 密钥只有 `read`，调了写接口 | 重新建一把带 `write` 的密钥 |
| `403 PLAN_FEATURE_REQUIRED` | 套餐不含 `integrations` / `identity` / `groups` | 让平台管理员调整套餐 |
| `403 IDENTITY_TOKEN_REQUIRED` | 前端直接传了 `externalId` | 改为后端签发 `identityToken` |
| `404` 而不是 `403` | 资源属于其他企业 | 跨企业统一按不存在处理，先核对密钥所属企业 |
| 语音按钮没反应 | iframe 缺麦克风权限 | 补 `allow="microphone"` |
| 会话列表读不到未读 | 用了企业级 `/unread` | 单人角标用访客端会话列表的 `visitorUnread` |

## 下一步

- 接口全量参数与错误码：[开放接口](open-api.md)
- 回调签名与重试：[Webhook 回调](webhook.md)
- 前端嵌入与商城接入：[前端嵌入](integrations.md)
- 群聊与通话：[群聊 API](groups-api.md)
- 生成客户端或复制 Go 客户端：[SDK 与代码生成](sdk.md)
- 导入 Postman / Apifox：[OpenAPI 规范](/docs/openapi.json)
