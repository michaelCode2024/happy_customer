param([string]$Flutter = 'D:\flutter\bin\flutter.bat')
$ErrorActionPreference = 'Stop'
$consolePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'apps\agent_console'
Push-Location $consolePath
try {
    # 与 web/flutter_bootstrap.js 的 HTML 渲染器保持一致；部署入口是 /console/。
    & $Flutter build web --release --base-href /console/ --web-renderer html --no-web-resources-cdn --pwa-strategy=none
    if ($LASTEXITCODE -ne 0) { throw '客服控制台构建失败。当前引导脚本需要支持 HTML 渲染器的 Flutter SDK。' }
} finally {
    Pop-Location
}
