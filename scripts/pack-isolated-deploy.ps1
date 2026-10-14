# Pack minimal source + prebuilt console/widget for isolated server deploy.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$outDir = Join-Path $root '.local-deploy'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outFile = Join-Path $outDir ("relaydesk-isolated-" + $stamp + ".tgz")

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$need = @(
  'packages\widget\dist\widget.js',
  'apps\agent_console\build\web\index.html',
  'apps\agent_console\build\web\main.dart.js'
)
foreach ($rel in $need) {
  $p = Join-Path $root $rel
  if (-not (Test-Path $p)) {
    throw ("Missing build artifact: " + $rel)
  }
}

$includes = @(
  'cmd', 'internal', 'go.mod', 'go.sum', 'Dockerfile', '.dockerignore',
  'deploy/isolated',
  'packages/widget/dist',
  'apps/agent_console/build/web',
  'apps/website'
)

Push-Location $root
try {
  & tar -czf $outFile @includes
  if ($LASTEXITCODE -ne 0) { throw 'tar failed' }
} finally {
  Pop-Location
}

$sizeMb = [math]::Round((Get-Item $outFile).Length / 1MB, 1)
Write-Host ("OK " + $outFile + " (" + $sizeMb + " MB)")
