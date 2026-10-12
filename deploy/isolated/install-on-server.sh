#!/usr/bin/env bash
# 在 47.130.172.91 网页终端执行（独立实例，不改旧项目）
# 用法：把打包文件放到 /tmp 后：
#   bash install-on-server.sh /tmp/relaydesk-isolated-XXXX.tgz
set -euo pipefail

TGZ="${1:-}"
if [[ -z "$TGZ" || ! -f "$TGZ" ]]; then
  echo "用法: bash install-on-server.sh /tmp/relaydesk-isolated-XXXX.tgz"
  exit 1
fi

APP_DIR=/opt/relaydesk-isolated
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-https://47.130.172.91:41815}"
WIDGET_TOKEN_SECRET="${WIDGET_TOKEN_SECRET:-$(openssl rand -hex 24)}"

echo "==> 安装目录 $APP_DIR （独立卷/端口，不影响其它 compose 项目）"
sudo mkdir -p "$APP_DIR"
sudo tar -xzf "$TGZ" -C "$APP_DIR"
sudo chown -R "$USER:$USER" "$APP_DIR"

cd "$APP_DIR"
cp -n deploy/isolated/env.example deploy/isolated/.env || true
# 写入对外地址与密钥
sed -i "s|^PUBLIC_BASE_URL=.*|PUBLIC_BASE_URL=$PUBLIC_BASE_URL|" deploy/isolated/.env
sed -i "s|^WIDGET_TOKEN_SECRET=.*|WIDGET_TOKEN_SECRET=$WIDGET_TOKEN_SECRET|" deploy/isolated/.env

echo "==> 构建并启动（项目名 relaydesk_isolated，宿主机端口 18080）"
cd deploy/isolated
export COMPOSE_PROJECT_NAME=relaydesk_isolated
sudo docker compose --env-file .env -f docker-compose.yml build
sudo docker compose --env-file .env -f docker-compose.yml up -d

echo "==> 等待健康检查"
for i in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:18080/health" >/dev/null 2>&1; then
    echo "health OK"
    break
  fi
  sleep 2
done
curl -fsS "http://127.0.0.1:18080/health" || true
echo
curl -fsS "http://127.0.0.1:18080/ready" || true
echo

cat <<EOF

启动完成（独立实例）。

本机探测: http://127.0.0.1:18080/health
控制台:   http://127.0.0.1:18080/console/

请在 aaPanel 把站点/反代（例如端口 41815）指到 http://127.0.0.1:18080
对外 PUBLIC_BASE_URL 已设为: $PUBLIC_BASE_URL

演示账号（DEMO_ENABLED=true 时）见容器日志：
  sudo docker compose -p relaydesk_isolated -f $APP_DIR/deploy/isolated/docker-compose.yml logs server | tail -50

平台管理员默认:
  邮箱 admin@relaydesk.local
  密码 RelayDesk@2026

停止本实例（不动其它项目）:
  cd $APP_DIR/deploy/isolated && sudo docker compose -p relaydesk_isolated down

EOF
