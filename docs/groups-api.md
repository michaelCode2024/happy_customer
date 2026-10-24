# 群聊 API

第三方在自己的网站或 App 建群、指定群主、管理成员及解散群，请看 [第三方群聊接入](第三方群聊接入.md)。全程使用第三方用户 ID，无需为用户创建客服账号。

后台和客户统一使用 `/api/v1/groups`，请求头为各自的 Bearer 登录/访客 token。服务端校验企业状态和群成员身份；内部群只能由同企业账号组成。客户只能通过客户服务群邀请加入。

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | /api/v1/groups | 当前成员群列表，包含 unread、kind、memberCount；unread 只计其他成员发送且超过本人已读边界的消息 |
| POST | /api/v1/groups | 企业账号建群，name、kind(INTERNAL/SERVICE)、inboxId、agentIds |
| GET | /api/v1/groups/{id} | 群成员列表 |
| PATCH | /api/v1/groups/{id} | 群主修改 name、announcement、archived |
| GET | /api/v1/groups/{id}/messages | after/before 序号翻页、q 搜索，最多100条，按序号倒序 |
| POST | /api/v1/groups/{id}/messages | content、clientId(UUID)，同成员重复 clientId 幂等 |
| POST | /api/v1/groups/{id}/read | 提交实际展示的 sequence（正整数），返回 readSequence 和 unread；不默认读取最新消息 |
| PUT | /api/v1/groups/{id}/owner | 当前群主转让给现有同身份类型成员，kind、id |
| POST | /api/v1/groups/{id}/members | 群主添加同企业账号，agentId |
| DELETE | /api/v1/groups/{id}/members/{kind}/{actor} | 群主移除成员或成员退出，群主不能直接退出 |
| POST | /api/v1/groups/{id}/invite | 群主生成服务群邀请，24小时有效，撤销旧邀请 |
| PATCH | /api/v1/groups/{id}/policy | 群主设置speakingMode（ALL/MANAGERS）、maxMembers（2至5000）、requireIdentity |
| PUT | /api/v1/groups/{id}/manager | 群主设置现有成员管理员：kind、id、isManager；管理员可发言及生成邀请 |
| POST | /api/v1/group-join/{ticket} | 客户加入：匿名传 `name`；登录客户可传 `identityToken`（可选 `name`），与一对一复用同一 visitor |
| POST | /api/v1/groups/session | 已入群登录客户用 `identityToken` + `groupId` 换群聊 token，无需邀请链 |
| GET | /ws/groups?token=... | 实时 group.updated 事件，客户端据 groupId 增量获取状态 |

### 用宿主用户群体进群

不要把对方整库用户同步进通语。推荐两步：

1. **业务后端加人**：`POST /api/v1/open/groups/{id}/members`，body 为宿主用户的 `externalId` 列表（见 [开放 API](open-api.md)）。
2. **前端打开群页**：
   - 企业版：后端使用 `identityToken` 经 `POST /api/v1/groups/session` 换取群会话，再打开不含秘密的 `/groups.html?groupId=<id>&embed=1&parentOrigin=<精确宿主Origin>`。收到 `tongyu.group.ready` 后，校验 event.origin 和 event.source，再发送 `tongyu.group.authenticate` 与 groupId/token。身份票据和群 token 均不拼入 URL。
   - 专业版及以上：后端验证当前用户后调用 `POST /api/v1/open/groups/{id}/member-token`，把返回的群 token 用上述来源校验消息桥交接。当前群页脚本还保留基于 identityToken 查询参数的兼容分支，生产接入统一不要使用 URL 传密钥的旧分支；应优先使用来源校验的 authenticate 消息桥，并在真实客户浏览器验证。跨域父页不能写客服域的 sessionStorage；不要把 Token 持久化到宿主存储。

未启用requireIdentity的群仍允许匿名邀请链；新建商城福利群默认要求登录身份。登录用户应走externalId映射，避免同一人出现多个匿名visitor。

服务群邀请链接具备加入权限，应仅提供给准备邀请的客户；内部群不能生成客户邀请。归档停止发消息及加入，保留历史。移出后不能读取历史或继续发消息。群消息支持文字和通过商城业务后端发送的商品、订单卡片；群内暂不支持附件和单独的@提醒。

页面文件位于 apps/agent_console/web/groups.html，发布时同时复制到静态资源根目录，以供 /groups.html 使用。


## 撤回、昵称与解散

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| PATCH | /api/v1/groups/{id}/me | 当前成员修改群昵称，body 为 name，1至120字；历史消息保留发送时昵称 |
| POST | /api/v1/groups/{id}/messages/{message}/recall | 仅发送者可撤回自己的消息，重复调用幂等 |
| POST | /api/v1/groups/{id}/dissolve | 仅群主可解散，保留历史但不能恢复；停止发送和通话、撤销邀请 |
| GET | /api/v1/groups/{id}/calls | 当前成员参与的最近20次通话、iceServers；其他成员不能读取 SDP |
| POST | /api/v1/groups/{id}/calls | 发起一对一语音，recipientKind、recipientId、offer:{type:offer,sdp} |
| POST | /api/v1/groups/{id}/calls/{call} | action 为 accept/decline/end；accept 必须提供 answer:{type:answer,sdp} |

撤回后的消息返回 recalled=true、content 为空；搜索不再命中原文，服务端清空原文。解散后列表返回 dissolved=true、archived=true，不允许通过取消归档重新打开。内部群与客户服务群均支持这些操作。

## 语音通话接入

工作台群聊右上角的电话按钮打开内嵌的同源通话面板，登录 token 通过校验来源和父窗口的 postMessage 交接，不放入 URL。客户在自己的群聊页面点「通话」选择成员。被呼叫的客服在工作台任意页面会收到来电弹窗，点「打开通话」进入接听面板；客户直接在群页面接听。接听前不会读取麦克风。通话中可以静音或挂断。

状态为 RINGING、ACCEPTED、ENDED、DECLINED、MISSED。RINGING 在60秒后超时；ACCEPTED 表示双方完成信令接听，不表示音频已经连通，页面只有在 WebRTC connectionState=connected 后显示「通话中」。浏览器协商失败、拒绝麦克风、授权超时均显示可理解的错误。结束、移出成员、解散或离开页面时释放麦克风；页面关闭时尝试结束服务端通话，异常断网的接听记录最多保留2小时后自动过期。结束后不再保留 SDP。语音不经应用服务器转发、不录音。

上线使用 HTTPS。默认没有外部 ICE 服务，适合本机或可直连的内网；跨公网、不同 NAT 的可靠连通需要部署自己的 STUN/TURN，然后为服务器配置环境变量 TONGYU_RTC_ICE_SERVERS（JSON 数组，例如 [{"urls":"stun:your-host:3478"}]；TURN 同时填写 username、credential）。TURN 凭据应使用短期凭据，返回给参与通话的登录成员。没有配置中继时不能承诺所有网络都可以通话。配置示例和 WebRTC 实现依据：[MDN WebRTC 信令说明](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Signaling_and_video_calling)。

网页/H5 现提供一对一语音和下述多人群音视频，不包含原生 Flutter 手机客户端的通话插件。App WebView 需宿主开放麦克风、摄像头与自动播放权限，并进行实机测试。发布时复制 groups.html、group-interactions.js 和 group-conference.js 到静态目录根部。


## 多人群语音与视频（2026-10-11）

内部协作群和客户服务群共用以下接口，使用当前客服或群客户的 Bearer 登录令牌。每场最多 6 人，同群同时只有一场多人通话；不能与一对一通话重叠。

- `GET /api/v1/groups/{id}/rooms?session={sessionId}&after={signalId}`：当前房间、参与成员、设备状态及 ICE 配置。仅当前已加入的浏览器会话收到发给它的协商 SDP；其他群成员仅看房间和成员。
- `POST /api/v1/groups/{id}/rooms`：所有操作均需 `sessionId`（浏览器生成 UUID）。`create` 使用 `mediaKind: AUDIO/VIDEO` 和 `camera`；其他操作带 `roomId`。
- `join` 加入；`heartbeat` 每 8 秒上报 `muted/camera`；`signal` 携带 `recipientSession` 和 `payload: {type: offer/answer, sdp}`；`leave` 退出；`end` 结束全场，仅发起人或群主允许。

创建示例：`{action:"create",sessionId:"UUID",mediaKind:"VIDEO",camera:false}`。关闭摄像头加入不会申请摄像头权限，可稍后通过按钮请求摄像头并替换协商好的视频轨道。

45 秒没有心跳的成员会在房间读取/操作时回收；最后一人退出、解散或归档会结束通话并清除 SDP。成员被移出后失去信令权限。页面关闭释放所有设备及 PeerConnection。

浏览器要求 HTTPS 或 localhost；跨公网/NAT 需要配置自有 STUN/TURN（`TONGYU_RTC_ICE_SERVERS`）。此版本使用最多 6 人的 WebRTC mesh，尚未提供 SFU、大型会议或原生 App RTC 插件。
