#Requires -Version 5.1
<#
.SYNOPSIS
    conMon Docker 单机部署管理脚本 (Windows)

.PARAMETER Command
    子命令：start | stop | restart | status | logs | update | remove | exec

.PARAMETER Version
    镜像版本，用于 start/update 命令

.PARAMETER Follow
    配合 logs 命令实时跟踪日志

.EXAMPLE
    .\docker.ps1 start
    .\docker.ps1 start -Version v2.0.0
    .\docker.ps1 logs -Follow
    .\docker.ps1 update v2.1.0
    .\docker.ps1 status
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('start','stop','restart','status','logs','update','remove','exec','help')]
    [string]$Command = 'help',

    [string]$Version = $env:CONMON_VERSION ?? 'latest',
    [switch]$Follow,
    [string[]]$ExecArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── 配置 ─────────────────────────────────────────────────────────────────────
$ContainerName = 'conmon'
$Image         = 'conmon/conmon'
$HttpPort      = $env:CONMON_HTTP_PORT  ?? '8080'
$GrpcPort      = $env:CONMON_GRPC_PORT  ?? '9090'
$ConfigFile    = $env:CONMON_CONFIG     ?? (Join-Path (Get-Location) 'configs\conmon.yaml')
$DataVolume    = 'conmon-data'
$LogVolume     = 'conmon-logs'

# ── 辅助函数 ─────────────────────────────────────────────────────────────────
function Write-Ok   { param([string]$M) Write-Host "[OK]  $M" -ForegroundColor Green }
function Write-Info { param([string]$M) Write-Host "[..] $M"  -ForegroundColor Cyan }
function Write-Warn { param([string]$M) Write-Host "[!!] $M"  -ForegroundColor Yellow }
function Fail       { param([string]$M) Write-Host "[ERR] $M" -ForegroundColor Red; exit 1 }

function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail "Docker 未安装" }
    try { docker info 2>$null | Out-Null } catch { Fail "Docker daemon 未运行，请启动 Docker Desktop" }
}

function Get-ContainerRunning {
    $id = docker ps -q --filter "name=^/$ContainerName$" 2>$null
    return $id -ne ''
}

function Get-ContainerExists {
    $id = docker ps -aq --filter "name=^/$ContainerName$" 2>$null
    return $id -ne ''
}

# ── 命令实现 ─────────────────────────────────────────────────────────────────
function Invoke-Start {
    Assert-Docker
    Write-Host ">>> 启动 conMon 容器" -ForegroundColor White

    if (Get-ContainerRunning) {
        Write-Warn "容器 $ContainerName 已在运行"
        Write-Info "停止: .\docker.ps1 stop"
        Write-Info "重启: .\docker.ps1 restart"
        return
    }

    if (Get-ContainerExists) {
        Write-Info "移除旧容器..."
        docker rm $ContainerName | Out-Null
    }

    $runArgs = @(
        '--name', $ContainerName,
        '--restart', 'unless-stopped',
        '-p', "${HttpPort}:8080",
        '-p', "${GrpcPort}:9090",
        '-v', "${DataVolume}:/var/lib/conmon",
        '-v', "${LogVolume}:/var/log/conmon"
    )

    # 配置文件挂载
    if (Test-Path $ConfigFile) {
        $absConfig = (Resolve-Path $ConfigFile).Path
        $runArgs += '-v', "${absConfig}:/etc/conmon/conmon.yaml:ro"
        Write-Info "配置文件: $absConfig"
    } else {
        Write-Warn "配置文件不存在: $ConfigFile，使用容器内置默认配置"
    }

    # 注入环境变量
    $envVars = @('JWT_SECRET','DB_PASSWORD','INFLUXDB_TOKEN','DINGTALK_WEBHOOK_URL','WECOM_WEBHOOK_URL')
    foreach ($v in $envVars) {
        if ($env:($v)) { $runArgs += '-e', "$v=$($env:($v))" }
    }

    # 加载 .env 文件
    if (Test-Path '.env') {
        $runArgs += '--env-file', '.env'
        Write-Info "加载环境变量: .env"
    }

    Write-Info "启动容器..."
    docker run -d @runArgs "${Image}:${Version}" | Out-Null

    # 等待健康检查
    Write-Info "等待服务就绪..."
    $waited = 0
    while ($waited -lt 30) {
        Start-Sleep -Seconds 1
        $waited++
        try {
            $resp = Invoke-RestMethod "http://localhost:$HttpPort/health" -TimeoutSec 2 -ErrorAction Stop
            Write-Ok "conMon 启动成功！"
            Write-Host ""
            Write-Host "  Web UI:    http://localhost:$HttpPort" -ForegroundColor White
            Write-Host "  健康检查:  Invoke-RestMethod http://localhost:$HttpPort/health" -ForegroundColor Cyan
            Write-Host "  查看日志:  .\docker.ps1 logs -Follow" -ForegroundColor Cyan
            return
        } catch { }
    }
    Write-Warn "等待超时，请检查日志: .\docker.ps1 logs"
}

function Invoke-Stop {
    Assert-Docker
    if (Get-ContainerRunning) {
        docker stop $ContainerName | Out-Null
        Write-Ok "容器已停止: $ContainerName"
    } else {
        Write-Info "容器未运行"
    }
}

function Invoke-Restart {
    Invoke-Stop
    Start-Sleep -Seconds 1
    Invoke-Start
}

function Invoke-Status {
    Assert-Docker
    Write-Host "=== 容器状态 ===" -ForegroundColor White
    docker ps -a --filter "name=^/$ContainerName$" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}"
    Write-Host ""

    if (Get-ContainerRunning) {
        Write-Host "=== 健康检查 ===" -ForegroundColor White
        try {
            $health = Invoke-RestMethod "http://localhost:$HttpPort/health" -TimeoutSec 5
            $health | ConvertTo-Json
        } catch {
            Write-Warn "健康检查失败（服务可能正在启动）"
        }

        Write-Host ""
        Write-Host "=== 资源使用 ===" -ForegroundColor White
        docker stats $ContainerName --no-stream --format "CPU: {{.CPUPerc}}  内存: {{.MemUsage}}  网络: {{.NetIO}}"
    }
}

function Invoke-Logs {
    Assert-Docker
    if ($Follow) {
        docker logs -f $ContainerName
    } else {
        docker logs --tail=100 $ContainerName
    }
}

function Invoke-Update {
    param([string]$NewVersion)
    Assert-Docker
    Write-Host ">>> 更新到版本: $NewVersion" -ForegroundColor White

    Write-Info "拉取镜像: ${Image}:${NewVersion}"
    docker pull "${Image}:${NewVersion}"

    Invoke-Stop

    $script:Version = $NewVersion
    Invoke-Start

    Write-Ok "更新完成: ${Image}:${NewVersion}"
}

function Invoke-Remove {
    Assert-Docker
    Write-Warn "这将移除容器（数据卷 $DataVolume 将保留）"
    $confirm = Read-Host "确认移除? [y/N]"
    if ($confirm -notmatch '^[yY]$') { Write-Info "取消"; return }

    docker stop $ContainerName 2>$null
    docker rm   $ContainerName 2>$null
    Write-Ok "容器已移除（数据已保留）"
    Write-Info "如需清除数据: docker volume rm $DataVolume $LogVolume"
}

function Invoke-Exec {
    Assert-Docker
    $cmd = if ($ExecArgs.Count -gt 0) { $ExecArgs } else { @('/bin/sh') }
    docker exec -it $ContainerName @cmd
}

function Show-Usage {
    Write-Host @"
用法: .\docker.ps1 <命令> [选项]

命令:
  start              启动 conMon 容器
  stop               停止容器
  restart            重启容器
  status             查看容器状态和健康信息
  logs [-Follow]     查看日志（-Follow 实时跟踪）
  update [VERSION]   更新到指定版本
  remove             移除容器（保留数据卷）
  exec               在容器内执行命令

环境变量:
  CONMON_VERSION     镜像版本（默认: latest）
  CONMON_HTTP_PORT   HTTP 端口（默认: 8080）
  CONMON_CONFIG      配置文件路径

示例:
  .\docker.ps1 start
  `$env:CONMON_VERSION='v2.0.0'; .\docker.ps1 start
  .\docker.ps1 logs -Follow
  .\docker.ps1 update v2.1.0
"@
}

# ── 主入口 ───────────────────────────────────────────────────────────────────
switch ($Command) {
    'start'   { Invoke-Start }
    'stop'    { Invoke-Stop }
    'restart' { Invoke-Restart }
    'status'  { Invoke-Status }
    'logs'    { Invoke-Logs }
    'update'  { Invoke-Update -NewVersion ($ExecArgs[0] ?? 'latest') }
    'remove'  { Invoke-Remove }
    'exec'    { Invoke-Exec }
    default   { Show-Usage }
}
