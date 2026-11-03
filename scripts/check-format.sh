#!/usr/bin/env bash
# 检查 Dart 代码是否已按仓库规范格式化。
#
# 为什么需要它：cardTheme.margin、inputDecorationTheme 这类全局样式改了以后，
# 手写代码很容易和 dart format 的产物不一致；一旦有人跑 dart format，
# 会顺带重排一堆无关代码，review 里看不出真正的改动。
#
# 用法：
#   scripts/check-format.sh          # 只检查，有问题返回非 0
#   scripts/check-format.sh --write  # 直接格式化
#
# 想让它拦住提交，在 .git/hooks/pre-commit 里写：
#   #!/usr/bin/env sh
#   exec "$(git rev-parse --show-toplevel)/scripts/check-format.sh"
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/apps/agent_console"

if ! command -v dart >/dev/null 2>&1; then
  echo "找不到 dart，请先安装 Flutter SDK 并加入 PATH。" >&2
  exit 1
fi

cd "$app"
if [ "${1:-}" = "--write" ]; then
  dart format lib test
else
  # 只报告不改文件；有漂移时退出码非 0，可直接用于 hook / CI。
  dart format --output=none --set-exit-if-changed lib test
fi
