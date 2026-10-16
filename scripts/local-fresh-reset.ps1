# Clear local business data, disable demo seed, keep AI config.
# Only touches local Docker: deploy-postgres-1 / tongyu-local.

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

Write-Host '==> Stop API container'
docker stop tongyu-local 2>$null | Out-Null

Write-Host '==> Truncate business tables (keep schema_migration)'
$sqlPath = Join-Path $env:TEMP 'tongyu-fresh-reset.sql'
@'
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN (
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public' AND tablename <> 'schema_migration'
  ) LOOP
    EXECUTE 'TRUNCATE TABLE ' || quote_ident(r.tablename) || ' RESTART IDENTITY CASCADE';
  END LOOP;
END $$;
'@ | Set-Content -Path $sqlPath -Encoding ascii
Get-Content -Path $sqlPath -Raw | docker exec -i deploy-postgres-1 psql -U tongyu -d tongyu -v ON_ERROR_STOP=1 | Out-Null
Remove-Item $sqlPath -Force -ErrorAction SilentlyContinue

Write-Host '==> Clean local uploads and fixtures'
if (Test-Path 'data\uploads') {
  Get-ChildItem 'data\uploads' -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item 'data\acceptance-fixture.json','data\automation-fixture.json' -Force -ErrorAction SilentlyContinue

Write-Host '==> Recreate tongyu-local (DEMO_ENABLED=false)'
docker rm tongyu-local 2>$null | Out-Null

$aiProvider = 'compatible'
$aiBase = ''
$aiKey = ''
$aiModel = ''
if (Test-Path '.env') {
  Get-Content '.env' -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^\s*AI_PROVIDER=(.*)$') { $aiProvider = $Matches[1].Trim() }
    if ($_ -match '^\s*AI_BASE_URL=(.*)$') { $aiBase = $Matches[1].Trim() }
    if ($_ -match '^\s*AI_API_KEY=(.*)$') { $aiKey = $Matches[1].Trim() }
    if ($_ -match '^\s*AI_MODEL=(.*)$') { $aiModel = $Matches[1].Trim() }
  }
}

docker run -d --name tongyu-local --restart unless-stopped --network deploy_default -p 8080:8080 `
  -v "${Root}/server-linux:/tongyu" `
  -v "${Root}/.local-static:/static" `
  -v "${Root}/data/uploads:/data/uploads" `
  -e DATABASE_URL=postgres://tongyu:tongyu@postgres:5432/tongyu?sslmode=disable `
  -e DATABASE_MAX_CONNS=40 `
  -e WIDGET_TOKEN_SECRET=local-only-change-this-secret-before-production `
  -e WIDGET_TOKEN_TTL=12h `
  -e ALLOWED_ORIGIN=* `
  -e FRAME_ANCESTORS=* `
  -e MAX_WS_CONNECTIONS=10000 `
  -e DEMO_ENABLED=false `
  -e PUBLIC_BASE_URL=http://localhost:8080 `
  -e PLATFORM_ADMIN_EMAIL=admin@tongyu.local `
  -e PLATFORM_ADMIN_PASSWORD=TongYu@2026 `
  -e STORAGE_DRIVER=local `
  -e STORAGE_LOCAL_DIR=/data/uploads `
  -e STATIC_DIR=/static `
  -e LISTEN_ADDRESS=:8080 `
  -e AI_PROVIDER=$aiProvider `
  -e AI_BASE_URL=$aiBase `
  -e AI_API_KEY=$aiKey `
  -e AI_MODEL=$aiModel `
  -e AI_AUTO_REPLY_ENABLED=true `
  --entrypoint /tongyu alpine:3.20 | Out-Null

Write-Host '==> Wait for ready'
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Seconds 1
  try {
    $ready = Invoke-RestMethod 'http://127.0.0.1:8080/ready' -TimeoutSec 2
    if ($ready.status -eq 'READY') {
      $ready | ConvertTo-Json -Compress
      break
    }
  } catch {}
}

Write-Host ''
Write-Host 'History wiped. Use a private window for the console.'
Write-Host 'Platform: http://localhost:8080/console/  admin@tongyu.local / TongYu@2026'
Write-Host 'Next: python scripts/e2e-onboarding.py'
