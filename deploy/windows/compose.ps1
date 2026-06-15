#Requires -Version 5.1
<#
.SYNOPSIS
    conMon Docker Compose 全栈部署脚本 (Windows)

.PARAMETER Command
    子命令：init | up | down | restart | status | logs | upgrade | ps | cleanup

.PARAMETER Service
    logs 命令的目标服务（默认: conmon-server）

.PARAMETER Version
    upgrade 命令的目标版本

.EXAMPLE
    .\compose.ps1 init
    .\compose.ps1 up
    .\compose.ps1 status
    .\compose.ps1 logs -Service conmon-server
    .\compose.ps1 upgrade v2.1.0
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('init','up','down','restart','status','logs','upgrade','ps','exec','cleanup','help')]
    [string]$Command = 'help',

    [string]$Service = 'conmon-server',
    [string]$Version = '',
    [switch]$Follow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$ScriptDir   = Split-Path $PSCommandPath -Parent
$ProjectRoot = Split-Path (Split-Path $ScriptDir -Parent) -Parent
$ComposeDir  = Join-Path $ProjectRoot 'deployments\compose'
$ComposeFile = Join-Path $ComposeDir 'docker-compose.yml'
$EnvFile     = Join-Path $ComposeDir '.env'

function Write-Step { param([string]$M) Write-Host "`n>>> $M" -ForegroundColor White }
function Write-Ok   { param([string]$M) Write-Host "[OK]  $M" -ForegroundColor Green }
function Write-Info { param([string]$M) Write-Host "[..] $M"  -ForegroundColor Cyan }
function Write-Warn { param([string]$M) Write-Host "[!!] $M"  -ForegroundColor Yellow }
function Fail       { param([string]$M) Write-Host "[ERR] $M" -ForegroundColor Red; exit 1 }

function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail "Docker 未安装" }
    try { docker info 2>$null | Out-Null } catch { Fail "Docker daemon 未运行，请启动 Docker Desktop" }

    # 确定 compose 命令
    try {
        docker compose version 2>$null | Out-Null
        $script:ComposeCmd = 'docker compose'
    } catch {
        if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
            $script:ComposeCmd = 'docker-compose'
        } else {
            Fail "Docker Compose 未安装"
        }
    }
}

function Invoke-Compose {
    $fullArgs = @('-f', $ComposeFile, '--env-file', $EnvFile) + $args
    if ($script:ComposeCmd -eq 'docker compose') {
        docker compose @fullArgs
    } else {
        docker-compose @fullArgs
    }
}

function Get-HttpPort {
    if (Test-Path $EnvFile) {
        $line = Get-Content $EnvFile | Where-Object { $_ -match '^CONMON_HTTP_PORT=' }
        if ($line) { return ($line -split '=')[1].Trim() }
    }
    return '8080'
}

# ── Init ─────────────────────────────────────────────────────────────────────
function Invoke-Init {
    Write-Step "初始化 Docker Compose 环境"
    Assert-Docker

    if (-not (Test-Path $ComposeDir)) { Fail "Compose 目录不存在: $ComposeDir" }

    if (Test-Path $EnvFile) {
        Write-Info ".env 文件已存在（跳过）"
    } else {
        Copy-Item (Join-Path $ComposeDir '.env.example') $EnvFile
        # 生成随机密钥
        $dbPass     = [System.Web.Security.Membership]::GeneratePassword(24, 4)
        $jwtSecret  = [System.Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        $influxToken = [System.Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32))

        $content = Get-Content $EnvFile -Raw
        $content = $content -replace 'DB_PASSWORD=.*',       "DB_PASSWORD=$dbPass"
        $content = $content -replace 'JWT_SECRET=.*',        "JWT_SECRET=$jwtSecret"
        $content = $content -replace 'INFLUXDB_TOKEN=.*',    "INFLUXDB_TOKEN=$influxToken"
        Set-Content $EnvFile $content -Encoding UTF8

        Write-Ok ".env 文件已生成（密钥已随机化）"
        Write-Warn "请查看并补充告警渠道配置: $EnvFile"
    }

    Write-Ok "初始化完成，请执行: .\compose.ps1 up"
}

# ── Up ───────────────────────────────────────────────────────────────────────
function Invoke-Up {
    Write-Step "启动 conMon 全栈服务"
    Assert-Docker

    if (-not (Test-Path $EnvFile)) { Fail ".env 不存在，请先执行: .\compose.ps1 init" }

    Write-Info "拉取最新镜像..."
    Invoke-Compose pull --quiet

    Write-Info "启动所有服务..."
    Invoke-Compose up -d --remove-orphans

    # 等待就绪
    $port = Get-HttpPort
    Write-Info "等待 conMon 服务就绪..."
    $waited = 0
    while ($waited -lt 60) {
        Start-Sleep -Seconds 2
        $waited += 2
        try {
            $resp = Invoke-RestMethod "http://localhost:$port/health" -TimeoutSec 3 -ErrorAction Stop
            Write-Ok "所有服务已就绪！"
            Write-Host ""
            Write-Host "  conMon:  http://localhost:$port" -ForegroundColor White
            Write-Host "  Grafana: http://localhost:3000" -ForegroundColor White
            return
        } catch { }
    }
    Write-Warn "等待超时，请检查日志: .\compose.ps1 logs"
}

# ── 其他命令 ─────────────────────────────────────────────────────────────────
function Invoke-Down    { Assert-Docker; Invoke-Compose down; Write-Ok "所有服务已停止" }
function Invoke-Restart { Assert-Docker; Invoke-Compose restart; Write-Ok "重启完成" }
function Invoke-Ps      { Assert-Docker; Invoke-Compose ps }

function Invoke-Status {
    Assert-Docker
    Write-Host "=== 服务状态 ===" -ForegroundColor White
    Invoke-Compose ps
    Write-Host ""
    $port = Get-HttpPort
    try {
        $health = Invoke-RestMethod "http://localhost:$port/health" -TimeoutSec 5
        Write-Host "=== 健康状态 ===" -ForegroundColor White
        $health | ConvertTo-Json
    } catch { Write-Warn "conMon 服务未响应" }
}

function Invoke-Logs {
    Assert-Docker
    if ($Follow) { Invoke-Compose logs -f --tail=50 $Service }
    else          { Invoke-Compose logs --tail=100 $Service }
}

function Invoke-Upgrade {
    param([string]$NewVersion)
    Assert-Docker
    Write-Step "升级 conMon"

    $ver = if ($NewVersion) { $NewVersion } else { 'latest' }
    $content = Get-Content $EnvFile -Raw
    $content = $content -replace 'CONMON_VERSION=.*', "CONMON_VERSION=$ver"
    Set-Content $EnvFile $content -Encoding UTF8

    Invoke-Compose pull conmon-server
    Invoke-Compose up -d --no-deps conmon-server

    Start-Sleep -Seconds 3
    $port = Get-HttpPort
    try {
        $health = Invoke-RestMethod "http://localhost:$port/health" -TimeoutSec 5
        Write-Ok "升级完成，当前版本: $($health.version)"
    } catch { Write-Warn "升级后服务未响应，请检查日志: .\compose.ps1 logs" }
}

function Invoke-Cleanup {
    Assert-Docker
    Write-Warn "这将停止所有服务并删除所有数据（不可恢复！）"
    $confirm = Read-Host "请输入 'DELETE ALL' 确认"
    if ($confirm -ne 'DELETE ALL') { Write-Info "取消"; return }
    Invoke-Compose down -v --remove-orphans
    Write-Ok "所有服务和数据已清除"
}

function Show-Usage {
    Write-Host @"
用法: .\compose.ps1 <命令> [选项]

命令:
  init                初始化（生成 .env，随机化密钥）
  up                  启动所有服务
  down                停止所有服务
  restart             重启所有服务
  status              查看服务状态和健康信息
  logs [-Service svc] [-Follow]  查看日志
  upgrade [VERSION]   升级 conmon-server
  ps                  显示容器列表
  cleanup             停止并删除所有数据（危险！）

示例:
  .\compose.ps1 init
  .\compose.ps1 up
  .\compose.ps1 logs -Service conmon-server -Follow
  .\compose.ps1 upgrade v2.1.0
"@
}

# ── 主入口 ───────────────────────────────────────────────────────────────────
switch ($Command) {
    'init'    { Invoke-Init }
    'up'      { Invoke-Up }
    'down'    { Invoke-Down }
    'restart' { Invoke-Restart }
    'status'  { Invoke-Status }
    'logs'    { Invoke-Logs }
    'upgrade' { Invoke-Upgrade -NewVersion $Version }
    'ps'      { Invoke-Ps }
    'cleanup' { Invoke-Cleanup }
    default   { Show-Usage }
}
