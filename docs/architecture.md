# RelayDesk P0 架构

## 技术基线（2026-10-07）

- Go 1.27.1：聊天 API、WebSocket 与后台任务
- PostgreSQL 18.6：业务数据；19 当前仍处于 Beta，不进入生产
- Flutter 3.47.1 / Dart 3.13.1：坐席台与运营台，覆盖 Web、Windows、macOS、Android、iOS
- TypeScript 7.0.2 + Web Component：网站/H5 访客组件
- Docker：本地环境和云平台一致交付

只采用当前稳定版本，不使用 RC、Beta 或 Snapshot 作为生产基线。版本升级必须经过测试，而不是无约束使用浮动 `latest` 标签。

## 为什么不是所有端都用 Flutter

Flutter 适合功能复杂、需要跨桌面和移动端的坐席工作台，但 Flutter Web 运行时对嵌入第三方网站的一个聊天按钮而言过重。因此：

- 坐席/运营产品使用 Flutter，共享绝大多数界面和业务逻辑。
- 网站、PC Web 和 H5 使用标准 Web Component，体积小且不绑定宿主框架。
- 业务 App 首期通过 WebView 接入同一 H5；后期提供 Android/iOS 原生桥接 SDK。
- 所有客户端只依赖 OpenAPI/WebSocket 协议，不依赖某个前端框架。

## 后端模块

- `auth`：Widget Token，后续扩展坐席 Session 与 RBAC
- `config`：环境配置和安全校验
- `platform/database`：连接池、内嵌迁移与开发数据
- `realtime`：WebSocket 连接与实时事件
- `server`：HTTP API、租户边界校验与中间件

首期保持模块化单体。模型稳定且确实出现独立扩容需求后，再拆实时网关或异步任务服务。

## 消息可靠性

1. Widget 使用公开 `inboxKey` 初始化访客并换取短期 HMAC Token。
2. 所有资源查询同时校验 `tenantId + inboxId + visitorId`，避免跨租户越权。
3. 发送消息时在数据库事务内原子递增会话序号并持久化消息。
4. 事务提交后才发送 WebSocket 事件；访客消息的 AI 自动回复在提交后异步执行，不阻塞发送接口。
5. 断线重连使用 `after=<lastSequence>` 增量补拉；WebSocket 不作为消息存储。
6. `clientMessageId` 提供客户端重试幂等性。
7. 队列事件按 `inbox:` 扇出（坐席按入口订阅）；跨实例仍用 PostgreSQL `LISTEN/NOTIFY`。
8. 单实例 WebSocket 与 DB 池可由环境变量设硬顶；`GET /metrics` 暴露基础计数。

## 部署演进

- 开发期：Northflank Sandbox 或本机 Docker，PostgreSQL 可使用 Northflank 免费数据库或 Neon Free。
- 静态端：Cloudflare Pages 托管 Flutter Web 和 Widget 产物；也可由同一 Go 容器提供 `/widget.js`、`/h5/`、`/console/`。
- 正式商用：迁移到付费常驻实例、托管 PostgreSQL、对象存储和 Redis（共享限流）；中国大陆业务需国内云、域名与备案方案。
