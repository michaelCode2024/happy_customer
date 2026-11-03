# 第三方接入方向

通语客服的消息与会话仍由自身服务存储和分发，不依赖腾讯云 IM。参考其“应用标识、服务端接口、客户端身份、事件回调”的接入体验，但不宣称协议或 SDK 兼容。

## 当前已经具备

- **网站 / H5**：通过公开 `inboxKey` 装载组件；`/h5/{inboxKey}` 可作为 App WebView 或业务系统 iframe。公开 Key 只标识入口，不是服务端密钥。
- **客户业务系统**：企业管理员创建租户 API Key，服务端以 `X-TongYu-Key` 调用 `/api/v1/open/`，按 `read` / `write` 权限访问会话、访客、消息和统计。密钥只在创建时显示，不要放进网页或 App。完整列表见 [open-api.md](open-api.md)。
- **访客身份**：匿名咨询只需 inboxKey；关联已登录客户必须传 identityToken。客户后端使用 write 权限的 APIKey 调用 `POST /api/v1/open/visitor-identity`，提交 inboxKey、externalId、displayName。返回的票据有效期 5 分钟，绑定企业、入口、客户 ID；bootstrap 从签名中读取身份，不受前端 externalId 覆盖。identityToken 不可作为聊天 Bearer Token 使用。
- **事件推送**：企业配置 Webhook，接收会话、消息等事件；投递失败重试。签名密钥不是 API Key，列表接口不返回这两套密钥的全文。接收方要校验签名并按投递 ID 幂等处理。契约见 [webhook.md](webhook.md)。
- **聊天可靠性**：发送使用 `clientMessageId` 幂等；会话消息以 `sequence` 排序，断线后按 `after` 补拉；WebSocket 是实时通知，不是唯一事实来源。

## 业务系统 iframe 嵌入

宿主页面：

```html
<iframe
  id="tongyu"
  src="https://chat.example.com/h5/{inboxKey}?parentOrigin=https://app.example.com"
  style="border:0;width:100%;height:100%;min-height:520px"
  allow="microphone;clipboard-write"
></iframe>
```

查询参数：theme、primaryColor、title、displayName、parentOrigin。身份票据不要放入 URL。旧 externalId 查询接入需迁移为 authenticate 指令，否则返回 IDENTITY_TOKEN_REQUIRED。

父页监听：

```js
window.addEventListener('message', (event) => {
  if (event.origin !== 'https://chat.example.com' || event.source !== document.getElementById('tongyu').contentWindow) return;
  const data = event.data;
  if (!data || data.source !== 'tongyu') return;
  // ready | open | close | message | sent | unread | resize | error …
  if (data.type === 'resize') {
    document.getElementById('tongyu').style.height = `${data.data.height}px`;
  }
});
```

父页指令（`postMessage` 到 iframe）：

```js
iframe.contentWindow.postMessage({ type: 'open' }, 'https://chat.example.com');
iframe.contentWindow.postMessage({ type: 'say', content: '你好' }, 'https://chat.example.com');
// 票据来自你的业务后端，后端从已验证的登录会话读取客户 ID。
iframe.contentWindow.postMessage({ type: 'authenticate', identityToken }, 'https://chat.example.com');
```

### 键盘弹起与光标位置（iOS PWA / WebView）

iOS 上键盘弹起有两套模型：Safari 标签页只缩视觉视口（布局视口不变），PWA 和 WebView 会真的缩布局视口。两边各补偿一次，或者宿主和页面都改一次 iframe 高度，输入框和光标就落在两套坐标里，表现为「点这儿、光标在那儿」，越补越歪。

组件现在按「哪个高度真的变了」自行判断，只补一次，并且只用 `top` / `height` 定位，不再用 `transform`：

- 输入框字号 16px，避免 iOS 聚焦时自动放大整页（放大后光标坐标必错）；
- 键盘动画结束后把光标原地重设一次，逼内核重绘，不改文字也不动选区；
- 宿主通过 `host-viewport` 托管时，组件不再做第二次补偿。

需要宿主配合的只有两条，属于 iframe 写法而不是接口：

1. iframe 容器 `position: fixed; inset: 0`，聊天打开时宿主页面自身不滚动；
2. iframe 的祖先节点不要留 `transform` / `filter` / `will-change: transform`——它们会改变 `fixed` 的包含块，iOS 会把光标画到另一个坐标系里。弹窗的 `scale(1)` 动画结束后记得清掉。

要做到「输入栏永远贴住键盘」，宿主可以额外把可视区高度发过来；不实现也不会飘，只是键盘上方可能留白：

```js
const frame = document.getElementById('tongyu');
const vv = window.visualViewport;
const sync = () => {
  frame.style.height = `${vv.height}px`;
  frame.style.top = `${vv.offsetTop}px`;
  frame.contentWindow.postMessage(
    { type: 'host-viewport', keyboardOpen: vv.height < window.innerHeight - 80 },
    'https://chat.example.com',
  );
};
vv.addEventListener('resize', sync);
vv.addEventListener('scroll', sync);
sync();
```

宿主托管后不要再让页面自己跟随键盘，也不要把 iframe 放进会滚动的容器里：两边同时改高度就是上面说的「补两遍」。另外，`keyboardOpen: true` 只有在该 iframe 盒子确实已经变矮时才会生效——只发消息不改高度，组件会忽略这条消息、继续自己跟，避免输入栏停在键盘底下。

CSP：服务端对 `/h5` 设置 `Content-Security-Policy: frame-ancestors …`，由环境变量 `FRAME_ANCESTORS` 控制（默认 `*`）。CORS / WebSocket Origin 仍由 `ALLOWED_ORIGINS` 控制。

## 嵌入后会话什么时候结束

访客端界面自带这些状态，宿主页面不需要额外开发，但要知道它们会发生：

- **等待人工**：访客要求人工或 AI 转接后，若还没有客服领取，聊天区显示「正在为您转接人工客服，请稍候…」，标题栏显示「转接中」。这段时间不再有静默空白。
- **空闲自动结束**：访客和客服都停止发言满 `CONVERSATION_AUTO_CLOSE_MINUTES`（默认 30 分钟，设为 `0` 关闭）后，系统结束会话，效果与客服手动「标记解决」完全一致——写入结束时间、在消息流里插入「较长时间没有收到新消息，本次咨询已自动结束。」、计入当日收单、发出 `conversation.closed`（Webhook 里 `closedBy` 为 `null`）。判定只看最后一条消息时间，客服转接和内部备注不会延长会话。
- **结束后再发言**：原来的一轮保持结束。访客再次发言会另开一轮，出现在对应入口的待接待中，并按该入口的分配规则接待。客服不能把已结束的一轮改回进行中。
- **排队提示不会被系统消息冲掉**：接入、超时重分配这类系统消息留在已结束的原会话上，不会另开一轮，也不会把结束状态改掉。

按住说话的语音消息依赖麦克风权限。iframe 必须写 `allow="microphone;clipboard-write"`，缺失时浏览器直接拒绝授权，语音按钮点了没有反应；`/widget.js` 直接嵌在宿主页面里则沿用宿主自己的权限。iframe 场景里指针的“松开”事件偶尔传不进组件（页面被切走、宿主弹层盖住、手势被系统打断），旧版本会停在“按住中”，下一次点击就失灵。现在页面隐藏或卸载会先把录音安全收尾，检测到残留的按住状态也会先复位再开始新的按住。宿主页面只是短暂抢走焦点时不会中断正在进行的录音。

## 商城、店主与福利群接入（2026-10-14）

本节是已实现接口。商城用户端和店主端保留原有登录，业务后端根据登录会话确认操作者、店铺归属、商品和订单权限，再调用通语。店铺对应独立tenant与inbox；店员对应真实agent；同一买家跨店铺复用商城externalId，但各店铺visitor独立，统一入口只汇总当前商城当前买家的数据。

平台超级管理员调用 `POST /api/v1/platform/marketplaces`，body为 `{"name":"商城名称","plan":"ENTERPRISE"}`。响应包含id、apiKey、plan；密钥只在创建时返回，保存在商城后端。默认ENTERPRISE，平台也可指定STARTER/GROWTH；商城不能自行修改套餐。`PATCH /api/v1/platform/marketplaces/{id}` 可设置status为ACTIVE或DISABLED；停用撤销店员和买家会话。普通企业密钥与商城密钥不能互换。

商城服务端接口请求头为 `X-TongYu-Marketplace-Key`。初始化流程：

1. `PUT /api/v1/marketplace/shops/{shopId}`，body为 `{"name":"店铺A","status":"ACTIVE"}`。返回shopId、tenantId、inboxId、inboxKey、created、status。shopId是宿主稳定ID，同一商城重试返回原租户，不创建重复店铺。status可为SUSPENDED；停用后旧聊天身份不能继续访问。
2. `GET /api/v1/marketplace/shops/{shopId}` 查询映射。商城密钥不能查询另一个商城的店铺。
3. `PUT /api/v1/marketplace/shops/{shopId}/staff/{staffId}`，body为 `{"displayName":"店员","role":"AGENT","status":"ACTIVE"}`。店主/主管使用SUPERVISOR，普通店员使用AGENT；状态可为DISABLED。返回agentId、staffId、shopId、role、status、created。创建与恢复都检查席位；相同资料重试保持登录，角色变更或停用撤销旧会话。
4. 店员在宿主登录后，后端从登录会话取真实staffId，调用 `POST /api/v1/marketplace/shops/{shopId}/staff-session`，body为 `{"externalId":"staffId"}`。返回真实客服token、agent资料、tenantId、inboxId、expiresIn；前端使用现有 `/api/v1/console/` 和 `/ws/console` 接待、回复、回执及成员管理。回复归属于该店员，不归属于“集成客服”。登录不会自动上线；前端通过console/me/presence设置在线并通过claim领取会话。
5. 买家登录后，业务后端调用 `POST /api/v1/marketplace/buyer-session`，body为 `{"externalId":"买家ID","displayName":"买家昵称"}`。返回token与expiresIn:3600，不能接受浏览器任意指定的买家ID。

买家前端使用 `Authorization: Bearer <买家token>` 调用 `GET /api/v1/marketplace/buyer/threads?limit=50&offset=0`。返回items、total、unread、limit、offset；items按updatedAt倒序，kind为CONVERSATION或GROUP，包含id、shopId、title、status、lastMessagePreview、lastSequence、updatedAt、unread。这是跨店铺私聊与已加入福利群的统一入口。只需要私聊列表时使用 `/api/v1/marketplace/buyer/conversations`，字段shopName替代title。分页上限100；total和unread是全量范围，不能把本页未读当全量未读。

打开店铺私聊：`POST /api/v1/marketplace/buyer/shops/{shopId}/session`，返回该店铺widget token、identityToken、inboxKey、visitorId、tenantId、shopId。自研聊天使用widget token调用原有widget会话/消息接口；嵌入聊天使用identityToken走上文的安全交接。创建会话接口返回 `{"conversation":{...}}`，不是顶层id。所有读写都校验会话属于当前买家和店铺。

统一入口的实时通知使用 `/ws/marketplace?token=<买家token>`。事件为conversation.updated或group.updated，只含变更提示，前端重新获取列表/消息；断线后重新获取统一列表并按消息sequence补拉。`POST /api/v1/marketplace/buyer/logout` 撤销当前买家会话；其店铺widget身份、由身份票据换得的聊天身份及商城群会话一并失效。其他设备会话不受影响。

### 福利群与店员身份

服务端商城接口以 `/api/v1/marketplace/shops/{shopId}/groups` 为Base：POST建群；`/{id}/members`批量加人；`/{id}/invite`生成邀请；`/{id}/manager`通过PUT授权管理员；`/{id}/policy`通过PATCH设置发言模式/容量。请求体与[开放 API](open-api.md)的群聊接口一致，入口由shopId自动选择。建群群主与新授权管理员必须是本店有效店主或店员；业务后端还需验证当前操作者本人、禁止买家代指定群主。买家必须主动确认加入，不自动导入整店客户。

同一Base还提供GET群列表（externalId、limit、offset）、GET `/{id}`详情（externalId）、PATCH `/{id}`资料、PUT `/{id}/owner`转让、DELETE `/{id}/members/{externalId}`移除/退出，以及POST `/{id}/dissolve`解散；请求字段与 [open-api.md](open-api.md) 的群聊接口一致。福利群只能转让给本店有效店员。店员在自有后台显示群列表时由自己的后端代理GET，打开群再使用绑定客服登录的群会话；外部用户群不会自动变成普通agent成员群。

买家已入群后，用买家token调用 `POST /api/v1/marketplace/buyer/groups/{id}/session`。店员用真实客服token调用 `POST /api/v1/marketplace/staff/groups/{id}/session`。返回token、groupId、visitorId、expiresIn:3600；前端用该token调用groups消息接口或通过postMessage交接群页面。这两类群身份绑定原登录会话，退出或停用会失效。旧服务端member-token仍可用于独立宿主集成，但它不是绑定商城买家登录的会话；商城应用优先使用新的群会话接口。

### 商品和订单卡片

仅业务后端可以调用 `POST /api/v1/marketplace/shops/{shopId}/conversations/{id}/cards`。body包含senderType（VISITOR/AGENT）、externalId（当前真实买家或店员）、clientMessageId（UUID）、card。服务器验证发送人与会话、店铺的关系；AGENT回复仍需先领取接待。浏览器不能提交权威商品价格或订单状态，宿主应从自己的数据库读取、检查订单归属后构造card。

card字段：kind为PRODUCT/ORDER；id是稳定商品或订单ID；title为1至120字；amountMinor是非负整数，按两位小数的最小货币单位，最大9007199254740991；currency是三位大写币种；url、imageUrl可省略，只允许http/https且禁止URL用户信息。ORDER还需orderNumber（最多120字），status可选且最多120字。不接收收货地址、支付凭据等敏感字段。amountMinor:29900表示299.00，消息保存快照，不会被未来订单变更悄悄改写；状态变更需发送新卡片或新消息。

群卡片使用 `POST /api/v1/marketplace/shops/{shopId}/groups/{id}/cards`，body为externalId、clientMessageId、card；同样检查群成员及发言模式。订单分享额外要求shareOrder:true，宿主必须先确认订单可分享给群成员。群消息与私聊统一返回messageType:CARD及metadata.card，现有Widget、客服工作台、群页面和Flutter客服组件支持展示。重试使用同一clientMessageId，避免重复消息；不能用新ID重发同一网络重试。

## 后续开发者中心（尚未实现）

1. 每个企业下管理多个“应用”：应用 ID、接入端（网站 / H5 / App / 服务端）、关联的客服入口、允许域名与启停状态。应用与企业绑定，不允许跨企业读取密钥或身份映射。
2. 身份票据已实现企业、入口和客户 ID 绑定；下一阶段增加独立应用层、票据撤销和细粒度权限。
3. 提供 Android、iOS、Flutter 与 Web 的轻量 SDK / 接入示例，统一登录、重连、增量补拉、消息幂等、已读、附件上传与错误码。SDK 不绕开服务端鉴权和权限规则。
4. 开发者控制台显示 API Key 的权限与最近使用、Webhook 订阅 / 投递 / 重放、调用用量、沙箱测试入口及可复制的中文接入代码。
5. 真正对接腾讯 IM 等外部通道时，通过独立适配器完成双向身份映射、消息 ID 去重、回调验签和失败补偿；不把第三方的 UserSig 或回调格式混进通语客服核心会话模型。

腾讯云文档参考：[REST API 简介](https://cloud.tencent.com/document/product/269/1519)、[第三方回调与安全](https://cloud.tencent.com/document/product/269/1522)。以上“下一阶段”尚未实现，不能将现有 Open API 当作可直接运行的腾讯 IM SDK。
