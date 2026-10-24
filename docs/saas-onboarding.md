# 通语企业开通与聊天接入

2026-10-23 对照源码复核；当前说明不代表目标实例已部署或已通过客户验收。

## 两种后台

平台运营：使用平台管理员邮箱和密码登录，点击顶栏「开通企业与账号」，保存企业标识、所有者邮箱和初始密码。在「账号安全」修改管理员密码；修改后所有旧会话失效。企业用户使用各自的账号，不能登录平台后台。

企业工作空间：使用企业标识、邮箱、密码登录。成员账户只能由超级管理员在平台企业详情中直接建立，不提供邀请或企业自助建号。客服主管在「企业管理」创建客服入口，并给已有成员分配入口。成员上线接待；无人在线时会话进入待接待队列，客户留言仍会保存。收件箱默认显示所有有入口权限的未结束会话，切换「我的」「待接待」可以缩小范围。

## 匿名聊天

到「应用接入 → 接入入口」复制入口对应的脚本或 iframe。公开 inboxKey 用于前端标识入口，无需 APIKey。

## 登录客户

1. 在「应用接入 → 服务端密钥」创建带 write 权限的 APIKey，只保存到业务后端。
2. 业务后端验证当前登录客户，从登录会话读取真实客户 ID，再向 TongYu 请求票据：

```http
POST /api/v1/open/visitor-identity
X-TongYu-Key: <业务后端 APIKey>
Content-Type: application/json

{"inboxKey":"入口公钥","externalId":"当前登录客户ID","displayName":"客户昵称"}
```

3. 前端向自己的后端获取响应中的 inboxKey、identityToken，然后加载组件：

```js
const identity = await fetch('/api/customer-chat-identity').then(r => r.json());
window.TongYuSettings = {
  endpoint: 'https://chat.example.com',
  inboxKey: identity.inboxKey,
  identityToken: identity.identityToken
};
const script = document.createElement('script');
script.src = 'https://chat.example.com/widget.js';
document.head.appendChild(script);
```

`/api/customer-chat-identity` 由接入方实现，不能相信浏览器自由提交的客户 ID。票据 5 分钟有效、绑定一个企业入口，组件自动换取访客 Token 建立实时连接。APIKey、平台管理员会话 Token 不能交给接入方或放入业务网页。每次加载或切换业务账号重新申请票据。匿名和登录历史不自动合并。

iframe 接入须指定准确 parentOrigin，在页面加载/身份桥已建立后发送 authenticate 指令，详见 [iframe 接入](integrations.md)。parentOrigin 为星号时不接受身份认证，票据不可放在 URL 中。

## 旧接入迁移

仅提交 externalId 将返回 IDENTITY_TOKEN_REQUIRED。升级为服务端签发 identityToken，或者省略 externalId 使用匿名咨询。身份票据过期、篡改或跨入口使用返回 IDENTITY_TOKEN_INVALID。

## 群聊与本站用户

客户服务群可按本站用户 ID 加人，不必把用户目录同步进通语：

1. 工作台建好 `SERVICE` 群（或记录群 ID）。
2. 业务后端 `POST /api/v1/open/groups/{groupId}/members`，body 带 `externalId` / `displayName`。
3. 企业版由后端使用 `identityToken` 调用 `POST /api/v1/groups/session`；其他含群聊的套餐由后端调用 `POST /api/v1/open/groups/{groupId}/member-token`。群页不应在 URL 中放票据。跨源父页不能直接写客服源的 sessionStorage；应由客服同源宿主或已实现的验证消息桥接入，并在目标浏览器实测，详见群聊 API。

一对一与群聊对同一 `inboxKey` + `externalId` 复用同一 visitor。详情见 [群聊 API](groups-api.md)。

## 验收

客户发文字或文件 → 后台「全部 / 待接待」找到会话 → 坐席领取 → 回复 → 客户看到回复。检查成员被分配到对应入口且账号启用；自动分配还需要在线成员和可用接待容量。断线重连按消息序号补拉；客户端刷新和轮询频率以实际版本为准。

## 品牌与接入兼容

产品展示名称为「通语」，工程与交付目录名称为 TongYuDesk。中文后台以消息接待、企业管理和应用接入为核心。蓝白主题、轻侧栏和多行编辑区用于日常协作。TongYu 是接入协议名，`window.TongYuSettings`、`X-TongYu-Key`、postMessage `source: tongyu`、API 路径和已接入企业的数据保持兼容。


## 历史验收

2026-10-11 的界面、文件、录音与自动回复验收原件移至 [历史记录](历史资料/20261011_开通与界面验收.md)。不把历史通过数量当作当前运行结果。

## 套餐与服务状态联动

套餐功能以服务端权限为准。取消订阅、暂停订阅或试用到期后，扩展模块接口不可调用，菜单同步收起；历史数据保留。普通聊天发送也会返回 `SUBSCRIPTION_INACTIVE`。月消息额度同时统计公开会话消息和群聊消息，排除内部备注及系统事件，额度用完返回 `MESSAGE_LIMIT_REACHED`；发送失败保留草稿，可调整额度后重试。重复 clientId 重试不重复扣额度。消息历史目前持续保留，没有按套餐天数自动删除。

成员资料和入口权限一次提交，任一步失败整体回滚。角色变更、禁用或入口权限实际改变时撤销旧登录，需重新登录；只修改显示名或保存相同权限不退出。禁用企业或入口后旧实时连接也会关闭。Webhook 仅在企业、订阅和回调均启用且套餐包含接入能力时入队/投递，暂停期间待投递任务保留，恢复后继续。已发出的网络请求可能完成。

## 企业角色简化

企业侧仅有客服主管（SUPERVISOR）和客服坐席（AGENT）。主管管理企业配置、已有成员、渠道、知识库、自动回复与报表；坐席在已分配入口中接待客户。新账号仍由平台超级管理员创建，额度也由平台超级管理员分配。旧 OWNER/ADMIN 在升级时迁移为主管并注销旧登录，至少保留一名启用主管。平台角色与第三方群主身份不受影响。
