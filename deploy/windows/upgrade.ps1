#Requires -Version 5.1
<#
.SYNOPSIS
    conMon Windows 自动升级脚本

.PARAMETER Version
    目标版本号，默认 latest

.PARAMETER DryRun
    仅显示将执行的操作，不实际执行

.EXAMPLE
    .\upgrade.ps1
    .\upgrade.ps1 -Version v2.1.0
    .\upgrade.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$GithubRepo  = 'grandinfo/gi-conMon'
$ServiceName = 'conmon'
$InstallDir  = 'C:\Program Files\conmon'
$DataDir     = 'C:\ProgramData\conmon'
$BackupDir   = 'C:\ProgramData\conmon\backups'
$BinaryPath  = "$InstallDir\conmon.exe"

function Write-Step { param([string]$M) Write-Host "`n>>> $M" -ForegroundColor White }
function Write-Ok   { param([string]$M) Write-Host "[OK]  $M" -ForegroundColor Green }
function Write-Info { param([string]$M) Write-Host "[..] $M"  -ForegroundColor Cyan }
function Write-Warn { param([string]$M) Write-Host "[!!] $M"  -ForegroundColor Yellow }
function Fail       { param([string]$M) Write-Host "[ERR] $M" -ForegroundColor Red; exit 1 }
function Dry        { param([string]$M) Write-Host "  [DRY-RUN] $M" -ForegroundColor Yellow }

Write-Host @"
╔══════════════════════════════════════════════════════╗
║           conMon Windows 升级脚本 v2.0               ║
╚══════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

if ($DryRun) { Write-Warn "DRY-RUN 模式，不执行实际操作" }

# ── 检测当前部署方式 ──────────────────────────────────────────────────────────
Write-Step "检测环境"

$deployMode = 'unknown'
$currentVersion = 'unknown'

# Windows Service
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    $deployMode = 'service'
    if (Test-Path $BinaryPath) {
        try { $currentVersion = (& $BinaryPath version 2>&1) -replace '.*?(v[\d.]+).*','$1' } catch { }
    }
}

# Docker
if ($deployMode -eq 'unknown') {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $running = docker ps -q --filter "name=^/conmon$" 2>$null
        if ($running) { $deployMode = 'docker' }

        $composeRunning = docker compose -f deployments\compose\docker-compose.yml ps 2>$null | Select-String 'conmon'
        if ($composeRunning) { $deployMode = 'compose' }
    }
}

Write-Info "部署方式:  $deployMode"
Write-Info "当前版本:  $currentVersion"

# ── 解析目标版本 ──────────────────────────────────────────────────────────────
if ($Version -eq 'latest') {
    Write-Info "查询最新版本..."
    try {
        $rel = Invoke-RestMethod "https://api.github.com/repos/$GithubRepo/releases/latest" -ErrorAction Stop
        $Version = $rel.tag_name
    } catch {
        Write-Warn "无法查询最新版本，请手动指定: .\upgrade.ps1 -Version v2.1.0"
        exit 1
    }
}
Write-Info "目标版本:  $Version"

if ($currentVersion -eq $Version -and $currentVersion -ne 'unknown') {
    Write-Ok "已是最新版本 ($Version)，无需升级"
    exit 0
}

# ── 确认 ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  将从 $currentVersion 升级到 $Version" -ForegroundColor White
Write-Host ""

if (-not $DryRun) {
    $confirm = Read-Host "确认升级? [Y/n]"
    if ($confirm -match '^[nN]$') { Write-Info "取消升级"; exit 0 }
}

# ── 备份 ─────────────────────────────────────────────────────────────────────
Write-Step "备份当前版本"

$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupPath = "$BackupDir\$ts"

if ($DryRun) {
    Dry "创建备份目录: $backupPath"
    Dry "备份二进制: $BinaryPath"
    Dry "备份配置文件"
} else {
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

    if (Test-Path $BinaryPath) {
        Copy-Item $BinaryPath "$backupPath\conmon.exe.bak"
        Write-Ok "二进制备份: $backupPath\conmon.exe.bak"
    }

    $configDir = "$DataDir\config"
    if (Test-Path $configDir) {
        Copy-Item $configDir "$backupPath\config" -Recurse -Force
        Write-Ok "配置备份: $backupPath\config"
    }
}

# ── 执行升级 ──────────────────────────────────────────────────────────────────
Write-Step "执行升级（$deployMode 模式）"

switch ($deployMode) {
    'service' {
        if ($DryRun) {
            Dry "Stop-Service conmon"
            Dry "下载新版二进制并替换 $BinaryPath"
            Dry "Start-Service conmon"
        } else {
            # 停止服务
            if ($svc.Status -eq 'Running') {
                Write-Info "停止服务..."
                Stop-Service $ServiceName -Force
                Start-Sleep -Seconds 2
            }

            # 下载新二进制
            $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'amd64' }
            $url = "https://github.com/$GithubRepo/releases/download/$Version/conmon-windows-$arch.zip"

            # 优先使用本地构建
            $localBin = Join-Path (Get-Location) 'bin\conmon.exe'
            if (Test-Path $localBin) {
                Write-Info "使用本地构建..."
                Copy-Item $localBin $BinaryPath -Force
            } else {
                Write-Info "下载: $url"
                $zip = "$env:TEMP\conmon-$Version.zip"
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
                $ProgressPreference = 'Continue'
                Expand-Archive -Path $zip -DestinationPath "$env:TEMP\conmon-upg" -Force
                $exe = Get-ChildItem "$env:TEMP\conmon-upg" -Filter 'conmon.exe' -Recurse | Select-Object -First 1
                Copy-Item $exe.FullName $BinaryPath -Force
                Remove-Item $zip, "$env:TEMP\conmon-upg" -Recurse -Force -ErrorAction SilentlyContinue
            }

            # 重启服务
            Write-Info "重启服务..."
            Start-Service $ServiceName
            Start-Sleep -Seconds 3
        }
    }

    'docker' {
        if ($DryRun) {
            Dry "docker pull conmon/conmon:$Version"
            Dry ".\docker.ps1 stop && .\docker.ps1 start -Version $Version"
        } else {
            & "$PSScriptRoot\docker.ps1" update $Version
        }
    }

    'compose' {
        if ($DryRun) {
            Dry "更新 .env: CONMON_VERSION=$Version"
            Dry "docker compose pull conmon-server"
            Dry "docker compose up -d --no-deps conmon-server"
        } else {
            & "$PSScriptRoot\compose.ps1" upgrade $Version
        }
    }

    default {
        Write-Warn "未检测到运行中的 conMon 实例"
        if (-not $DryRun) {
            $doInstall = Read-Host "执行全新安装? [Y/n]"
            if ($doInstall -notmatch '^[nN]$') {
                & "$PSScriptRoot\install.ps1" -Version $Version
            }
        }
    }
}

# ── 验证升级结果 ──────────────────────────────────────────────────────────────
if (-not $DryRun) {
    Write-Step "验证升级结果"
    Start-Sleep -Seconds 2

    try {
        $health = Invoke-RestMethod 'http://localhost:8080/health' -TimeoutSec 5 -ErrorAction Stop
        Write-Ok "升级成功！运行版本: $($health.version)"
    } catch {
        Write-Warn "服务未响应，请手动检查"
        Write-Host "  服务状态: Get-Service $ServiceName" -ForegroundColor Cyan
        Write-Host "  日志:     Get-EventLog -LogName Application -Source conmon -Newest 20" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  回滚命令:" -ForegroundColor Yellow
        Write-Host "    Stop-Service $ServiceName" -ForegroundColor Yellow
        Write-Host "    Copy-Item '$backupPath\conmon.exe.bak' '$BinaryPath'" -ForegroundColor Yellow
        Write-Host "    Start-Service $ServiceName" -ForegroundColor Yellow
    }
}

if ($DryRun) {
    Write-Host "`n[DRY-RUN 完成] 去掉 -DryRun 参数后执行实际升级" -ForegroundColor Green
}
