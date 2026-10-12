# 聊桥（RelayDesk）

**先看 [中文使用指南](docs/使用指南.md)：登录账号、创建企业与客服、接待消息、自动回复、H5/App 和 Token 接入。当前本机服务运行后也可打开 http://127.0.0.1:8080/console/help.html 。**

面向网站、H5、App 与 PC 的多租户客服平台，核心会话与实时通信全部自研。

> 让每一次客户连接，都能被及时接住。

## 技术栈

- **Go 1.27.1**：轻量、高并发 API 与 WebSocket 服务
- **PostgreSQL 18.6**：多租户业务数据与消息持久化
- **Flutter 3.47.1**：跨 Web、桌面、Android、iOS 的坐席/运营应用
- **TypeScript 7 + Web Component**：轻量网站/H5 聊天入口
- **Docker**：一致的本地与云端交付

版本依据和客户端拆分原因见 [`docs/architecture.md`](docs/architecture.md)。

企业开通、成员账号、APIKey 和客户身份接入见 [SaaS 开通指南](docs/saas-onboarding.md)，后台「渠道与接入 → 接入指南」也提供可复制示例。

## 目录

```text
cmd/server/             # Go 服务入口
internal/               # 后端业务与平台模块
apps/agent_console/     # Flutter 跨端坐席工作台
packages/widget/        # TypeScript Web Component
deploy/                 # 本地基础设施
docs/                   # 架构、API 与部署文档
```

## 已有能力

- PostgreSQL 内嵌版本迁移
- 多租户、Inbox 与访客模型
- Widget 身份初始化及短期 HMAC Token
- 创建/查询会话
- 消息持久化、幂等 ID 和会话内严格递增序号
- WebSocket 实时事件和断线增量补拉
- Flutter 响应式工作台基础界面
- 无框架依赖的 `<relaydesk-widget>` 基础组件

## 本地启动

当前 Go/Flutter 版本可分别通过 Docker 与 FVM 固定，不依赖本机安装旧版 SDK。

```bash
docker compose -f deploy/docker-compose.yml up -d
docker build -t relaydesk .
docker run --rm -p 8080:8080 --env-file .env --network deploy_default relaydesk
```

首次运行：复制 `.env.example` 为 `.env`，并替换 Token 密钥。本地演示 Inbox Key 为 `demo-web`。

健康检查：`GET http://localhost:8080/health`。

## 无服务器时部署

开发演示推荐：

1. **Northflank Sandbox**：从本仓库 `Dockerfile` 部署 Go 服务；官方当前提供 2 个免费服务和 1 个免费数据库，且标明不休眠。
2. **Neon Free**：独立 PostgreSQL 备选，永久免费且无需信用卡；空闲 5 分钟会休眠，适合开发而非正式客服。
3. **Cloudflare Pages**：托管 Widget 和 Flutter Web 静态文件。

Coolify、Dokploy、Supabase 等有开源自托管版本，但仍需要一台服务器。正式商用不能把在线客服可用性建立在免费额度上。

详细步骤见 [`docs/deployment.md`](docs/deployment.md)。
