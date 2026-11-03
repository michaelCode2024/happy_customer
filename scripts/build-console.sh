#!/usr/bin/env bash
# 构建 Flutter 控制台 Web 产物到 apps/agent_console/build/web。
# Dockerfile 直接拷贝该目录（COPY apps/agent_console/build/web/ /static/console/），
# 所以改完 Dart 代码必须先跑这个脚本，再 docker compose build，线上才会变。
#
# 已验证：直接构建到 build/web 不会清掉目录里其它文件（help.html、groups.html、
# pwa-assets.json、desktop/ 等都还在），因此不需要临时目录再拷贝。
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root/apps/agent_console"

# Git Bash 会把 --base-href=/console/ 当成 Windows 路径改写，必须关掉路径转换，
# 否则构建会以 "Received a --base-href value of ...\console\" 失败。
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" \
  flutter build web --base-href=/console/

echo "built apps/agent_console/build/web"
