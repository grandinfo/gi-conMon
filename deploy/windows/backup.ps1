#Requires -Version 5.1
<#
.SYNOPSIS
    conMon Windows 数据备份脚本

.PARAMETER BackupDest
    备份目录，默认 C:\ProgramData\conmon\backups

.PARAMETER KeepDays
    保留最近 N 天的备份，默认 30

.PARAMETER RestoreTimestamp
    从指定时间戳备份恢复（格式: yyyyMMdd_HHmmss）

.PARAMETER List
    列出所有可用备份

.EXAMPLE
    .\backup.ps1
    .\backup.ps1 -BackupDest D:\backups\conmon
    .\backup.ps1 -KeepDays 60
    .\backup.ps1 -List
    .\backup.ps1 -RestoreTimestamp 20260615_030000

.NOTES
    建议使用任务计划程序（Task Scheduler）定期执行
#>
[CmdletBinding()]
param(
    [string]$BackupDest        = 'C:\ProgramData\conmon\backups',
    [int]   $KeepDays          = 30,
    [string]$RestoreTimestamp  = '',
    [switch]$List
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$DataDir   = 'C:\ProgramData\conmon'
$ConfigDir = 'C:\ProgramData\conmon\config'
$LogDir    = 'C:\ProgramData\conmon\logs'
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$BackupName = "conmon_backup_$Timestamp"

function Write-Step { param([string]$M) Write-Host "`n>>> $M" -ForegroundColor White }
function Write-Ok   { param([string]$M) Write-Host "[OK]  $M" -ForegroundColor Green }
function Write-Info { param([string]$M) Write-Host "[..] $M"  -ForegroundColor Cyan }
function Write-Warn { param([string]$M) Write-Host "[!!] $M"  -ForegroundColor Yellow }

# ── 列出备份 ─────────────────────────────────────────────────────────────────
if ($List) {
    Write-Host "=== 可用备份列表 ===" -ForegroundColor White
    if (-not (Test-Path $BackupDest)) {
        Write-Info "备份目录不存在: $BackupDest"
        exit 0
    }
    Get-ChildItem $BackupDest -Filter 'conmon_backup_*.zip' |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            $ts = $_.BaseName -replace 'conmon_backup_',''
            $size = [Math]::Round($_.Length / 1MB, 2)
            Write-Host "  $ts  (${size}MB)  ->  $($_.FullName)"
        }
    exit 0
}

# ── 恢复备份 ─────────────────────────────────────────────────────────────────
if ($RestoreTimestamp) {
    Write-Step "从备份恢复: $RestoreTimestamp"

    $zipFile = "$BackupDest\conmon_backup_${RestoreTimestamp}.zip"
    if (-not (Test-Path $zipFile)) {
        Write-Host "[ERR] 备份不存在: $zipFile" -ForegroundColor Red
        exit 1
    }

    Write-Warn "这将覆盖当前的配置和数据！"
    $confirm = Read-Host "确认恢复? [y/N]"
    if ($confirm -notmatch '^[yY]$') { Write-Info "取消"; exit 0 }

    # 停止服务
    $svc = Get-Service conmon -ErrorAction SilentlyContinue
    $wasRunning = $false
    if ($svc -and $svc.Status -eq 'Running') {
        Stop-Service conmon -Force
        $wasRunning = $true
        Write-Ok "服务已停止"
    }

    # 解压恢复
    $extractPath = "$env:TEMP\conmon-restore-$RestoreTimestamp"
    Expand-Archive -Path $zipFile -DestinationPath $extractPath -Force

    if (Test-Path "$extractPath\config") {
        Copy-Item "$extractPath\config\*" $ConfigDir -Recurse -Force
        Write-Ok "配置已恢复"
    }

    if (Test-Path "$extractPath\conmon.db") {
        Copy-Item "$extractPath\conmon.db" "$DataDir\conmon.db" -Force
        Write-Ok "数据库已恢复"
    }

    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue

    if ($wasRunning) {
        Start-Service conmon
        Start-Sleep -Seconds 2
        $svc = Get-Service conmon
        if ($svc.Status -eq 'Running') { Write-Ok "服务已重启" }
        else { Write-Warn "服务重启失败，请手动启动: Start-Service conmon" }
    }

    Write-Ok "恢复完成: $RestoreTimestamp"
    exit 0
}

# ═════════════════════════════════════════════════════════════════════════════
# 全量备份
# ═════════════════════════════════════════════════════════════════════════════
Write-Host @"
╔══════════════════════════════════════════════════════╗
║         conMon Windows 备份脚本 v2.0                 ║
╚══════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

Write-Step "开始备份: $BackupName"

# 创建临时备份目录
$tempDir = "$env:TEMP\$BackupName"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
New-Item -ItemType Directory -Path $BackupDest -Force | Out-Null

$errors = 0

# ── 备份配置文件（自动脱敏）─────────────────────────────────────────────────
Write-Info "备份配置文件..."
if (Test-Path $ConfigDir) {
    $configBackup = "$tempDir\config"
    Copy-Item $ConfigDir $configBackup -Recurse -Force

    # 脱敏：替换密码/密钥字段
    Get-ChildItem $configBackup -Filter '*.yaml' -Recurse | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        $content = $content -replace '(?i)(password|secret|token|key):\s*"[^"]*"', '$1: "***REDACTED***"'
        $content = $content -replace "(?i)(password|secret|token|key):\s*'[^']*'", "`$1: '***REDACTED***'"
        Set-Content $_.FullName $content -Encoding UTF8
    }
    Write-Ok "配置文件已备份（已脱敏）"
} else {
    Write-Warn "配置目录不存在: $ConfigDir"
}

# ── 备份 SQLite 数据库 ──────────────────────────────────────────────────────
Write-Info "备份 SQLite 数据库..."
$dbPath = "$DataDir\conmon.db"
if (Test-Path $dbPath) {
    # 检查是否有 sqlite3.exe
    $sqlite3 = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
    if ($sqlite3) {
        sqlite3.exe $dbPath ".backup '$tempDir\conmon.db'" 2>$null
        Write-Ok "SQLite 数据库已备份（在线一致性备份）"
    } else {
        # 尝试停止服务后复制（确保数据一致）
        $svc = Get-Service conmon -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-Warn "建议安装 sqlite3.exe 以支持在线备份（跳过，使用文件复制）"
        }
        Copy-Item $dbPath "$tempDir\conmon.db" -Force
        Write-Ok "SQLite 数据库已备份（文件复制）"
    }
} else {
    Write-Info "SQLite 数据库不存在（可能使用 PostgreSQL）"
}

# ── 备份最近日志 ─────────────────────────────────────────────────────────────
Write-Info "备份最近日志..."
if (Test-Path $LogDir) {
    $logBackup = "$tempDir\logs"
    New-Item -ItemType Directory -Path $logBackup -Force | Out-Null
    Get-ChildItem $LogDir -Filter '*.log' |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-7) } |
        ForEach-Object { Copy-Item $_.FullName $logBackup }
    Write-Ok "最近 7 天日志已备份"
}

# 导出 Windows 事件日志（conmon 相关）
try {
    $events = Get-EventLog -LogName Application -Source conmon -Newest 1000 -ErrorAction SilentlyContinue
    if ($events) {
        $events | Export-Csv "$tempDir\event-log.csv" -NoTypeInformation -Encoding UTF8
        Write-Ok "Windows 事件日志已备份"
    }
} catch { }

# ── 记录备份元信息 ──────────────────────────────────────────────────────────
$metaInfo = [ordered]@{
    backup_name = $BackupName
    timestamp   = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')
    hostname    = $env:COMPUTERNAME
    os          = [System.Environment]::OSVersion.VersionString
    conmon_version = try { (& 'C:\Program Files\conmon\conmon.exe' version 2>&1) } catch { 'unknown' }
}
$metaInfo | ConvertTo-Json | Set-Content "$tempDir\backup-info.json" -Encoding UTF8

# ── 压缩备份 ─────────────────────────────────────────────────────────────────
Write-Info "压缩备份..."
$zipPath = "$BackupDest\${BackupName}.zip"
Compress-Archive -Path "$tempDir\*" -DestinationPath $zipPath -Force
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

$zipSize = [Math]::Round((Get-Item $zipPath).Length / 1MB, 2)
Write-Ok "备份已压缩: $zipPath (${zipSize}MB)"

# ── 清理过期备份 ─────────────────────────────────────────────────────────────
Write-Step "清理过期备份（保留最近 $KeepDays 天）"
$cutoffDate = (Get-Date).AddDays(-$KeepDays)
$deleted = 0

Get-ChildItem $BackupDest -Filter 'conmon_backup_*.zip' |
    Where-Object { $_.LastWriteTime -lt $cutoffDate } |
    ForEach-Object {
        Remove-Item $_.FullName -Force
        Write-Info "删除: $($_.Name)"
        $deleted++
    }

if ($deleted -eq 0) { Write-Info "无过期备份需要清理" }
else { Write-Ok "清理了 $deleted 个过期备份" }

# ── 汇总 ─────────────────────────────────────────────────────────────────────
Write-Step "备份完成"
Write-Host ""
Write-Host "  备份文件: $zipPath"  -ForegroundColor White
Write-Host "  备份大小: ${zipSize}MB" -ForegroundColor White
Write-Host "  保留策略: 最近 $KeepDays 天" -ForegroundColor White
Write-Host ""

Write-Host "当前备份列表:" -ForegroundColor White
Get-ChildItem $BackupDest -Filter 'conmon_backup_*.zip' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 5 |
    ForEach-Object {
        $s = [Math]::Round($_.Length / 1MB, 2)
        Write-Host "  $($_.Name) (${s}MB)"
    }

Write-Host ""
Write-Host "  恢复命令:" -ForegroundColor White
Write-Host "    .\backup.ps1 -RestoreTimestamp $Timestamp" -ForegroundColor Cyan

# ── 配置任务计划程序 ─────────────────────────────────────────────────────────
$taskName = 'conMon-DailyBackup'
if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
    Write-Host ""
    $setupTask = Read-Host "是否创建定时备份任务（每天 03:00）? [y/N]"
    if ($setupTask -match '^[yY]$') {
        $action  = New-ScheduledTaskAction `
            -Execute 'powershell.exe' `
            -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`" -BackupDest `"$BackupDest`" -KeepDays $KeepDays"
        $trigger = New-ScheduledTaskTrigger -Daily -At '03:00'
        $settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable -WakeToRun:$false
        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -RunLevel Highest `
            -Description 'conMon 每日自动备份' | Out-Null
        Write-Ok "定时任务已创建: $taskName (每天 03:00)"
    }
}
