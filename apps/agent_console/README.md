# 连语客服工作台

同一个 Flutter 程序提供客服工作台与平台运营后台。Web、Windows、Android、iOS、macOS 工程已生成；本机验证了 Web 和 Windows 正式构建。iOS、macOS 需要在 macOS 上用 Xcode 构建；Android 需要 Android SDK。

## 本地运行

1. 启动项目根目录的 Go 服务和 PostgreSQL：`docker compose -f deploy/docker-compose.yml --profile app up -d`（首次构建需访问镜像仓库、Go/npm/pub 依赖源）。
2. 在此目录执行 `flutter pub get`，再执行 `flutter run -d chrome` 或 `flutter run -d windows`。
3. 登录页填 `http://localhost:8080`；Windows/Android 模拟器访问宿主机地址时，应改为其可访问的网络地址。生产环境必须使用 HTTPS。

本地 Compose 启用演示数据时，服务启动日志会显示演示账号（`docker compose -f deploy/docker-compose.yml --profile app logs server`）。企业标识为 `demo`，企业主邮箱为 `owner@relaydesk.local`，坐席邮箱为 `agent@relaydesk.local`，两者密码均为 `RelayDesk@2026`。仅供本地演示，正式部署必须设置 `DEMO_ENABLED=false`，由平台运营后台开通企业并创建独立凭据。平台管理员使用单独的 `PLATFORM_ADMIN_TOKEN`，不是坐席账号密码。

## 构建

- Web：`flutter build web --release --base-href /console/ --no-web-resources-cdn --pwa-strategy=none`
- Windows：`flutter build windows --release`
- Android：`flutter build apk --release`（需要 Android SDK 与签名配置）
- iOS/macOS：在 macOS 上运行对应的 `flutter build`（需要 Xcode 与签名配置）
- 质量检查：`flutter analyze` 和 `flutter test`

Web 产物由 Go 服务按 `/console/` 提供。Go 服务和 widget 的完整构建参见项目根目录的 `Dockerfile` 与 [部署说明](../../docs/deployment.md)。
