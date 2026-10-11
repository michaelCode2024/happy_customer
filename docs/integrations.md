# 第三方接入方向

连语客服的消息与会话仍由自身服务存储和分发，不依赖腾讯云 IM。参考其“应用标识、服务端接口、客户端身份、事件回调”的接入体验，但不宣称协议或 SDK 兼容。

## 当前已经具备

- **网站 / H5**：通过公开 `inboxKey` 装载组件；`/h5/{inboxKey}` 可作为 App WebView 或业务系统 iframe。公开 Key 只标识入口，不是服务端密钥。
- **客户业务系统**：企业管理员创建租户 API Key，服务端以 `X-RelayDesk-Key` 调用 `/api/v1/open/`，按 `read` / `write` 权限访问会话、访客、消息和统计。密钥只在创建时显示，不要放进网页或 App。完整列表见 [open-api.md](open-api.md)。
- **访客身份**：`POST /api/v1/widget/bootstrap` 接受 `externalId`、昵称与联系信息。当前 `externalId` 是客户侧传入的标识，**未验证签名**；不能仅凭该字段展示受保护的订单、账户信息或复用为已认证身份。
- **事件推送**：企业配置 Webhook，接收会话、消息等事件；投递失败重试。接收方要校验签名并按事件 ID / 消息 ID 幂等处理。
- **聊天可靠性**：发送使用 `clientMessageId` 幂等；会话消息以 `sequence` 排序，断线后按 `after` 补拉；WebSocket 是实时通知，不是唯一事实来源。

## 业务系统 iframe 嵌入

宿主页面：

```html
<iframe
  id="relaydesk"
  src="https://chat.example.com/h5/{inboxKey}?parentOrigin=https://app.example.com&externalId=u123&displayName=张三"
  style="border:0;width:100%;height:100%;min-height:520px"
  allow="microphone;clipboard-write"
></iframe>
```

查询参数（均可选）：`theme`、`primaryColor`、`title`、`externalId`、`displayName`、`parentOrigin`。

父页监听：

```js
window.addEventListener('message', (event) => {
  const data = event.data;
  if (!data || data.source !== 'relaydesk') return;
  // ready | open | close | message | sent | unread | resize | error …
  if (data.type === 'resize') {
    document.getElementById('relaydesk').style.height = `${data.data.height}px`;
  }
});
```

父页指令（`postMessage` 到 iframe）：

```js
iframe.contentWindow.postMessage({ type: 'open' }, 'https://chat.example.com');
iframe.contentWindow.postMessage({ type: 'say', content: '你好' }, 'https://chat.example.com');
```

CSP：服务端对 `/h5` 设置 `Content-Security-Policy: frame-ancestors …`，由环境变量 `FRAME_ANCESTORS` 控制（默认 `*`）。CORS / WebSocket Origin 仍由 `ALLOWED_ORIGINS` 控制。

## 下一阶段：开发者中心

1. 每个企业下管理多个“应用”：应用 ID、接入端（网站 / H5 / App / 服务端）、关联的客服入口、允许域名与启停状态。应用与企业绑定，不允许跨企业读取密钥或身份映射。
2. 服务端签发短期访客身份票据：客户后端用应用密钥证明身份，票据绑定企业、应用、入口、外部用户 ID、到期时间与随机数。App 密钥永不下发前端；客户端用票据换取访客会话，替代可伪造的裸 `externalId`。
3. 提供 Android、iOS、Flutter 与 Web 的轻量 SDK / 接入示例，统一登录、重连、增量补拉、消息幂等、已读、附件上传与错误码。SDK 不绕开服务端鉴权和权限规则。
4. 开发者控制台显示 API Key 的权限与最近使用、Webhook 订阅 / 投递 / 重放、调用用量、沙箱测试入口及可复制的中文接入代码。
5. 真正对接腾讯 IM 等外部通道时，通过独立适配器完成双向身份映射、消息 ID 去重、回调验签和失败补偿；不把第三方的 UserSig 或回调格式混进连语客服核心会话模型。

腾讯云文档参考：[REST API 简介](https://cloud.tencent.com/document/product/269/1519)、[第三方回调与安全](https://cloud.tencent.com/document/product/269/1522)。以上“下一阶段”尚未实现，不能将现有 Open API 当作可直接运行的腾讯 IM SDK。
