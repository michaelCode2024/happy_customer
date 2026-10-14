param([string]$Platform)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskDelivery = Join-Path $taskRoot '对外资料'
$taskOutput = Join-Path $taskDelivery '04_打包文件'
New-Item -ItemType Directory -Force -Path $taskOutput | Out-Null
$taskSources = @((Join-Path $taskDelivery '01_通用资料'))
if ($Platform) {
    # 平台名只能是单级目录，防止误打包其他平台或项目文件。
    if ($Platform -in @('.', '..') -or $Platform.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $Platform -match '[/\\]') { throw '平台名称无效' }
    $taskPlatformDir = Join-Path (Join-Path $taskDelivery '02_平台专属') $Platform
    if (!(Test-Path -LiteralPath $taskPlatformDir -PathType Container)) { throw '平台资料目录不存在' }
    $taskSources += $taskPlatformDir
    $taskName = "通语客服_${Platform}交付包.zip"
} else {
    $taskSources += Join-Path $taskDelivery '03_平台模板'
    $taskName = '通语客服_通用资料.zip'
}
$taskZipPath = Join-Path $taskOutput $taskName
$taskTempPath = Join-Path $taskOutput ([guid]::NewGuid().ToString() + '.zip')
$taskFiles = @($taskSources | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File })
if (!$taskFiles.Count) { throw '没有可打包资料' }
$taskArchive = [IO.Compression.ZipFile]::Open($taskTempPath, 'Create')
try {
    foreach ($taskFile in $taskFiles) {
        $taskRelative = $taskFile.FullName.Substring($taskDelivery.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($taskArchive, $taskFile.FullName, $taskRelative, 'Optimal') | Out-Null
    }
} finally { $taskArchive.Dispose() }
# 逐项比对归档内容和原文件，避免把旧版本或缺失文件作为交付结果。
$taskCheck = [IO.Compression.ZipFile]::OpenRead($taskTempPath)
try {
    if ($taskCheck.Entries.Count -ne $taskFiles.Count) { throw '归档文件数量不一致' }
    foreach ($taskFile in $taskFiles) {
        $taskRelative = $taskFile.FullName.Substring($taskDelivery.Length + 1).Replace('\', '/')
        $taskEntry = $taskCheck.GetEntry($taskRelative)
        if (!$taskEntry) { throw "归档缺少文件：$taskRelative" }
        $taskStream = $taskEntry.Open()
        $taskHasher = [Security.Cryptography.SHA256]::Create()
        try { $taskActual = [BitConverter]::ToString($taskHasher.ComputeHash($taskStream)).Replace('-', '') }
        finally { $taskStream.Dispose(); $taskHasher.Dispose() }
        if ($taskActual -ne (Get-FileHash -LiteralPath $taskFile.FullName -Algorithm SHA256).Hash) { throw "归档校验失败：$taskRelative" }
    }
} finally { $taskCheck.Dispose() }
Move-Item -LiteralPath $taskTempPath -Destination $taskZipPath -Force
Write-Output "已生成并校验：$taskZipPath（$($taskFiles.Count) 个文件）"
