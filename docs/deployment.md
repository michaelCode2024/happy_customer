# 部署选择

## 当前推荐：Northflank Sandbox

适用于没有服务器的开发与演示阶段。其官方价格页在 2026-10-07 列出：

- 2 个免费 Service
- 1 个免费 Database
- 2 个免费 Cron Job
- Always-on compute，不休眠
- 支持 Dockerfile、WebSocket、自动 HTTPS 和自定义域名

部署步骤：

1. 将仓库推送到 GitHub、GitLab 或 Bitbucket。
2. 在 Northflank 创建 Sandbox Project。
3. 创建 PostgreSQL Addon，取得平台提供的连接地址。
4. 从仓库创建 Service，构建类型选择项目根目录的 `Dockerfile`。
5. 配置环境变量：
   - `DATABASE_URL`：PostgreSQL TLS 连接串
   - `WIDGET_TOKEN_SECRET`：至少 32 字符的随机密钥
   - `WIDGET_TOKEN_TTL=12h`
   - `ALLOWED_ORIGIN`：前端正式域名，不要在生产使用 `*`
   - `DEMO_ENABLED=false`
6. 端口设置为 `8080`，健康检查路径为 `/health`。

免费计划政策可能变化，创建资源前应再次查看官方价格页。

## 数据库备选：Neon Free

Neon 官方当前说明 Free 计划永久有效且无需信用卡，每项目包括 1 GB PostgreSQL 存储和 100 CU-hours；空闲 5 分钟自动休眠。将 Neon 的 pooled connection string 配到 `DATABASE_URL` 即可。

冷启动会影响客服首次连接，因此只建议开发验证。进入真实客户阶段应升级为不休眠的数据库与服务。

## 开源自托管方案

- Coolify：开源 PaaS，适合后续在自己的 VPS 上管理 Docker 服务、数据库、证书和发布。
- Dokploy：开源 Docker/PaaS 管理面板，定位类似。
- Supabase：PostgreSQL、认证、存储等组件可开源自托管，也提供云免费计划。

这些软件“开源”不代表“免费提供服务器”。有 VPS 后可选 Coolify/Dokploy；当前无服务器时先用托管免费额度更实际。
