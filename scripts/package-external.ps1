param([string]$Platform)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskDelivery = Join-Path $taskRoot '对外资料'
$taskManagement = Join-Path $taskRoot 'docs\交付管理'
$taskCommon = Join-Path $taskDelivery '01_通用资料'
$taskCustomerRoot = Join-Path $taskDelivery '02_平台专属'
$taskOutputRoot = Join-Path $taskDelivery '04_打包文件'
$taskSources = [Collections.Generic.List[string]]::new()
$taskSources.Add($taskCommon)
$taskCredentialNames = @{}
$taskPublicPrefix = $null
$taskSlug = '通用'

function Read-DeliveryManifest([string]$ManifestPath, [string]$SourcePath, [bool]$AllowSubdirectories) {
    if (!(Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw '缺少内部交付清单。' }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (!$manifest.deliverableFiles -or $manifest.deliverableFiles -is [string]) { throw '交付清单必须是文件名数组。' }
    $names = @{}
    foreach ($name in $manifest.deliverableFiles) {
        if ($name -isnot [string] -or $name -match '(^|[/\\])\.\.?([/\\]|$)|^[\\/]|:' -or
            (!$AllowSubdirectories -and $name -match '[/\\]') -or $names.ContainsKey($name)) {
            throw '交付清单中含重复、越界或非法文件名。'
        }
        if (!(Test-Path -LiteralPath (Join-Path $SourcePath $name) -PathType Leaf)) { throw "交付清单文件缺失：$name" }
        $names[$name] = $true
    }
    return @{ Profile = $manifest; Names = $names }
}

$taskCommonManifest = Read-DeliveryManifest (Join-Path $taskManagement '通用资料清单.json') $taskCommon $true
$taskMaterialVersion = $taskCommonManifest.Profile.materialVersion
if (!$taskMaterialVersion) { throw '通用资料清单缺少当前资料版本。' }
$taskDeclared = $null
if ($Platform) {
    if ($Platform -notmatch '^[a-z0-9][a-z0-9-]{1,62}$') { throw '客户标识须为已登记的唯一 ASCII slug。' }
    $taskSlug = $Platform
    $taskCustomer = Join-Path $taskCustomerRoot $Platform
    $taskProfilePath = Join-Path $taskManagement "客户\$Platform\客户档案.json"
    $taskCustomerManifest = Read-DeliveryManifest $taskProfilePath $taskCustomer $false
    $taskProfile = $taskCustomerManifest.Profile
    if ($taskProfile.materialVersion -ne $taskMaterialVersion) { throw '客户与通用资料版本不一致。' }
    $taskDeclared = $taskCustomerManifest.Names
    if ($taskProfile.customerId -ne $Platform -or !$taskProfile.displayName) { throw '客户档案与客户目录不匹配。' }
    foreach ($name in @($taskProfile.credentialFiles)) {
        if ($null -eq $name) { continue }
        if ($name -isnot [string] -or !$taskDeclared.ContainsKey($name) -or $taskCredentialNames.ContainsKey($name)) {
            throw '账号配置文件必须在本客户交付清单中单独登记，且不得重复。'
        }
        $taskCredentialNames[$name] = $true
    }
    $taskSources.Add($taskCustomer)
    $taskPublicPrefix = [IO.Path]::GetFullPath($taskCustomer).TrimEnd('\') + '\'
}

$taskFiles = [Collections.Generic.List[object]]::new()
$taskArchiveNames = @{}
foreach ($taskSource in $taskSources) {
    if (!(Test-Path -LiteralPath $taskSource -PathType Container)) { throw '交付来源目录不存在。' }
    # 检查所有祖先，避免通过父目录联接跨出实际项目目录。
    $taskAncestor = Get-Item -LiteralPath $taskSource
    while ($taskAncestor -and $taskAncestor.FullName -ne $taskRoot) {
        if (($taskAncestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '交付目录不允许目录联接。' }
        $taskAncestor = $taskAncestor.Parent
    }
    $taskPrefix = [IO.Path]::GetFullPath($taskSource).TrimEnd('\') + '\'
    $taskNames = if ($taskSource -eq $taskCommon) { $taskCommonManifest.Names } else { $taskDeclared }
    $taskItems = @(Get-ChildItem -LiteralPath $taskSource -Recurse -Force)
    if ($taskItems | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }) { throw '交付目录不允许符号链接。' }
    foreach ($taskFile in $taskItems | Where-Object { !$_.PSIsContainer }) {
        if (!$taskFile.FullName.StartsWith($taskPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw '交付文件超出来源目录。' }
        $taskRelative = $taskFile.FullName.Substring($taskPrefix.Length).Replace('\', '/')
        if (!$taskNames.ContainsKey($taskRelative)) { throw "交付文件未登记：$taskRelative" }
        if ($taskFile.Extension.ToLowerInvariant() -notin @('.txt', '.pdf')) { throw "不支持的交付文件类型：$taskRelative" }
        if ($taskArchiveNames.ContainsKey($taskRelative)) { throw "归档中存在重名文件：$taskRelative" }
        $taskArchiveNames[$taskRelative] = $true
        $taskIsCustomer = $taskPublicPrefix -and $taskFile.FullName.StartsWith($taskPublicPrefix, [StringComparison]::OrdinalIgnoreCase)
        $taskAllowsCredentials = $taskIsCustomer -and $taskCredentialNames.ContainsKey($taskRelative)
        if (!$taskAllowsCredentials -and $taskFile.Name -match '(?i)secret|credential|password|token|private|凭证|密钥|密码|口令|内部|私密|nacos') {
            throw "文件名包含非交付资料标记：$taskRelative"
        }
        if ($taskFile.Extension -eq '.txt') {
            $taskText = [IO.File]::ReadAllText($taskFile.FullName, [Text.Encoding]::UTF8)
            $taskHasCredentials = $taskText -match '(?i)\brdk_[A-Za-z0-9_-]{20,}|\b(?:sk|rk)-[A-Za-z0-9_-]{20,}' -or
                $taskText -match '(?im)^\s*(?:初始密码|当前密码|(?:初始)?服务端\s*API\s*Key|API\s*Key|密码|口令)\s*[：:=]\s*(?!通过独立受控渠道|通过受控渠道|待确认|待提供|单独提供|\[单独)[^\r\n]{6,}\S'
            if ($taskHasCredentials -and !$taskAllowsCredentials) { throw "凭证仅可进入本客户登记的账号配置文件：$taskRelative" }
            foreach ($taskVersionMatch in [regex]::Matches($taskText, '(?m)^(?:资料版本|版本)[：:]\s*([^\r\n]+)')) {
                if ($taskVersionMatch.Groups[1].Value.Trim() -ne $taskMaterialVersion) { throw "资料版本不一致：$taskRelative" }
            }
            if ($taskText -match '待提供|待确认|待核实|驯服|训话|本机联调|\.local-deploy|D:\\dev-workspace') {
                throw "交付文案含旧版、未完成项或内部信息：$taskRelative"
            }
        }
        $taskFiles.Add(@{ File = $taskFile; Name = $taskRelative })
    }
}
if (!$taskFiles.Count) { throw '没有可打包的正式资料。' }

$taskDropDir = Join-Path $taskOutputRoot $taskSlug
$taskTempDir = Join-Path $taskRoot '.local-deploy\external-package'
$taskRecordDir = Join-Path $taskManagement '生成记录'
foreach ($taskDir in @($taskDropDir, $taskTempDir, $taskRecordDir)) {
    New-Item -ItemType Directory -Force -Path $taskDir | Out-Null
    $taskAncestor = Get-Item -LiteralPath $taskDir
    while ($taskAncestor -and $taskAncestor.FullName -ne $taskRoot) {
        if (($taskAncestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '输出目录不允许目录联接。' }
        $taskAncestor = $taskAncestor.Parent
    }
}
$taskFileName = if ($Platform) { '通语客服_' + $Platform + '_资料包.zip' } else { '通语客服_通用资料.zip' }
$taskZip = Join-Path $taskDropDir $taskFileName
$taskTemp = Join-Path $taskTempDir ([guid]::NewGuid().ToString() + '.zip')
$taskTempHash = $taskTemp + '.sha256'
try {
    $taskArchive = [IO.Compression.ZipFile]::Open($taskTemp, 'Create')
    try {
        foreach ($taskEntry in $taskFiles) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($taskArchive, $taskEntry.File.FullName, $taskEntry.Name, 'Optimal') | Out-Null
        }
    } finally { $taskArchive.Dispose() }
    $taskCheck = [IO.Compression.ZipFile]::OpenRead($taskTemp)
    try {
        if ($taskCheck.Entries.Count -ne $taskFiles.Count) { throw '归档文件数量不一致。' }
        foreach ($taskEntry in $taskFiles) {
            $taskPacked = $taskCheck.GetEntry($taskEntry.Name)
            if (!$taskPacked) { throw "归档缺少文件：$($taskEntry.Name)" }
            $taskInput = [IO.File]::OpenRead($taskEntry.File.FullName)
            $taskStream = $taskPacked.Open()
            $taskHasher = [Security.Cryptography.SHA256]::Create()
            try {
                $taskOriginalHash = [BitConverter]::ToString($taskHasher.ComputeHash($taskInput))
                $taskPackedHash = [BitConverter]::ToString($taskHasher.ComputeHash($taskStream))
            } finally { $taskInput.Dispose(); $taskStream.Dispose(); $taskHasher.Dispose() }
            if ($taskOriginalHash -ne $taskPackedHash) { throw "归档文件校验失败：$($taskEntry.Name)" }
        }
    } finally { $taskCheck.Dispose() }
    $taskZipInput = [IO.File]::OpenRead($taskTemp)
    $taskZipHasher = [Security.Cryptography.SHA256]::Create()
    try {
        $taskHash = [BitConverter]::ToString($taskZipHasher.ComputeHash($taskZipInput)).Replace('-', '')
    } finally { $taskZipInput.Dispose(); $taskZipHasher.Dispose() }
    [IO.File]::WriteAllText($taskTempHash, "$taskHash  $taskFileName" + [Environment]::NewLine, [Text.Encoding]::ASCII)
    # 完整核验后覆盖固定交付文件名，不生成旧版副本。
    Move-Item -LiteralPath $taskTemp -Destination $taskZip -Force
    Move-Item -LiteralPath $taskTempHash -Destination ($taskZip + '.sha256') -Force
    $taskRecord = @{ customerId = $taskSlug; generatedAt = (Get-Date -Format o); fileName = $taskFileName; fileCount = $taskFiles.Count; sha256 = $taskHash }
    $taskRecord | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskRecordDir "$taskSlug.json") -Encoding UTF8
    Write-Output "资料包已生成并逐文件校验：$taskZip（$($taskFiles.Count) 个文件；SHA-256 $taskHash）"
} finally {
    foreach ($taskPath in @($taskTemp, $taskTempHash)) {
        if (Test-Path -LiteralPath $taskPath -PathType Leaf) { Remove-Item -LiteralPath $taskPath -Force }
    }
}
