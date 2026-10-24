# 通语 TongYuDesk

面向网站、H5 和 App WebView 的多租户客服平台。运营方开通企业租户，企业主管配置入口与成员，坐席接待客户。平台运营账号与企业客服账号是独立的两套权限。

## 从哪里开始

- [文档索引与适用范围](docs/00-文档索引.md)：区分当前说明、历史验收与客户配置。
- [客服使用指南](docs/使用指南.md)、[企业开通](docs/saas-onboarding.md)、[平台运营 API](docs/platform-api.md)。
- [网站与业务接入](docs/integrations.md)、[Open API](docs/open-api.md)、[Widget API](docs/api.md)、[群聊 API](docs/groups-api.md)。
- [架构和隔离](docs/architecture.md)、[独立部署与运维](docs/deployment.md)、[平台交付差距审查](docs/平台交付审查-20261023.md)。
- [对外资料](对外资料/00_资料目录.txt)、[内部交付管理](docs/交付管理/README.md)。首个客户资料按 `caizhan` 独立管理；对外目录仅保留当前正式文件，客户账号和密钥不进入 Git 或通用包。

## 当前实现与商用边界

已实现多租户与入口、访客和客服会话、实时消息、消息持久化及幂等、平台开通企业、手工套餐和额度、企业角色、群聊、外部身份票据及 Webhook。源码存在不等于目标实例已部署或客户已验收。

当前套餐和额度由平台超级管理员手工分配。尚未形成线上支付、购买/续费订单、自动扣款、发票或客户自营 SaaS 软件授权管理闭环。独立部署需要按交付范围完成安装、备份恢复、升级和实际业务验收。

## 工程组成

- `cmd/server`、`internal`：Go API、WebSocket、后台任务、PostgreSQL 内嵌迁移。
- `apps/agent_console`：Flutter 企业与平台工作台，含 Web/H5 专用资源。
- `packages/widget`：TypeScript Web Component 网站聊天组件。
- `apps/website`：官网、下载与安装说明。
- `deploy`：现有本机与特定独立实例开发编排，不直接当作客户正式发行包。

依赖版本应以 `go.mod`、`Dockerfile`、`packages/widget/package.json` 和实际构建 SDK 为准。Flutter pubspec 声明兼容下限，不证明指定版本已经实测。

## 本地开发

已有本机环境先核对实际容器、端口和 `.env`，不要按历史端口直接重置实例。全新开发环境可从 `deploy/docker-compose.yml` 启动数据库，再按 `.env.example` 配置应用。该 Compose 含演示设置，只用于开发。

构建前先生成 `packages/widget/dist/widget.js` 及完整 `apps/agent_console/build/web/`；当前 Dockerfile 直接复制预构建静态产物，不会运行 Flutter 或 npm。具体步骤与运行条件见 [部署指南](docs/deployment.md)。

检查 `/health` 仅证明数据库可连接；`/ready` 是运行配置概况，不证明 AI 实际回复、对象存储写入、客户聊天或恢复演练成功。以对应端到端流程补验。
