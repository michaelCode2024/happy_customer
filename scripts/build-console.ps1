param([string]$Flutter = 'D:\flutter\bin\flutter.bat')
$ErrorActionPreference = 'Stop'
$consolePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'apps\agent_console'
Push-Location $consolePath
try {
    # 部署入口是 /console/。Flutter 3.41+ 已无 --web-renderer；渲染器由 web/flutter_bootstrap.js 指定。
    & $Flutter build web --release --base-href /console/ --no-web-resources-cdn --pwa-strategy=none
    if ($LASTEXITCODE -ne 0) { throw '客服控制台构建失败。' }
    python (Join-Path $PSScriptRoot 'prepare-pwa.py')
    if ($LASTEXITCODE -ne 0) { throw 'PWA 离线资源生成失败。' }
} finally {
    Pop-Location
}
