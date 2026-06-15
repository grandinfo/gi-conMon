#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    conMon Windows 卸载脚本

.PARAMETER RemoveData
    同时删除所有数据和配置（不可恢复）

.PARAMETER DryRun
    仅显示将执行的操作

.EXAMPLE
    .\uninstall.ps1
    .\uninstall.ps1 -RemoveData
    .\uninstall.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$RemoveData,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$ServiceName = 'conmon'
$InstallDir  = 'C:\Program Files\conmon'
$DataDir     = 'C:\ProgramData\conmon'

function Write-Step { param([string]$M) Write-Host "`n>>> $M" -ForegroundColor White }
function Write-Ok   { param([string]$M) Write-Host "[OK]  $M" -ForegroundColor Green }
function Write-Info { param([string]$M) Write-Host "[..] $M"  -ForegroundColor Cyan }
function Write-Warn { param([string]$M) Write-Host "[!!] $M"  -ForegroundColor Yellow }
function Dry        { param([string]$M) Write-Host "  [DRY-RUN] $M" -ForegroundColor Yellow }

function Invoke-Action {
    param([scriptblock]$Action, [string]$DryMsg)
    if ($DryRun) { Dry $DryMsg }
    else { & $Action }
}

Write-Host @"
╔══════════════════════════════════════════════════════╗
║           conMon Windows 卸载脚本                    ║
╚══════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

if ($DryRun) { Write-Warn "DRY-RUN 模式，不执行实际操作" }

if (-not $DryRun) {
    Write-Host ""
    Write-Host "警告: 此操作将卸载 conMon！" -ForegroundColor Red
    if ($RemoveData) { Write-Host "-RemoveData 标志: 所有数据和配置将被永久删除！" -ForegroundColor Red }
    Write-Host ""
    $confirm = Read-Host "确认卸载? 输入 'yes' 继续"
    if ($confirm -ne 'yes') { Write-Info "取消卸载"; exit 0 }
}

# ── 停止并删除 Windows Service ────────────────────────────────────────────────
Write-Step "停止 Windows Service"

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -eq 'Running') {
        Invoke-Action { Stop-Service $ServiceName -Force } "Stop-Service $ServiceName"
        Write-Ok "服务已停止"
    }
    Invoke-Action {
        sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 1
    } "sc.exe delete $ServiceName"
    Write-Ok "Windows Service 已删除: $ServiceName"
} else {
    Write-Info "服务不存在: $ServiceName"
}

# ── 删除计划任务 ─────────────────────────────────────────────────────────────
Write-Step "删除计划任务"

$tasks = @('conMon-DailyBackup')
foreach ($task in $tasks) {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Invoke-Action { Unregister-ScheduledTask -TaskName $task -Confirm:$false } "Unregister-ScheduledTask $task"
        Write-Ok "计划任务已删除: $task"
    }
}

# ── 停止 Docker 容器 ─────────────────────────────────────────────────────────
Write-Step "清理 Docker 资源"

if (Get-Command docker -ErrorAction SilentlyContinue) {
    foreach ($container in @('conmon', 'conmon-server')) {
        $exists = docker ps -aq --filter "name=^/$container$" 2>$null
        if ($exists) {
            Invoke-Action {
                docker stop $container 2>$null
                docker rm   $container 2>$null
            } "docker stop/rm $container"
            Write-Ok "Docker 容器已删除: $container"
        }
    }

    if ($RemoveData) {
        foreach ($vol in @('conmon-data', 'conmon-logs')) {
            $volExists = docker volume inspect $vol 2>$null
            if ($volExists) {
                Invoke-Action { docker volume rm $vol } "docker volume rm $vol"
                Write-Ok "数据卷已删除: $vol"
            }
        }
    }
}

# ── 删除防火墙规则 ───────────────────────────────────────────────────────────
Write-Step "删除防火墙规则"

foreach ($ruleName in @('conMon HTTP API', 'conMon gRPC Probe')) {
    $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($rule) {
        Invoke-Action { Remove-NetFirewallRule -DisplayName $ruleName } "Remove-NetFirewallRule '$ruleName'"
        Write-Ok "防火墙规则已删除: $ruleName"
    }
}

# ── 从 PATH 移除安装目录 ─────────────────────────────────────────────────────
Write-Step "清理系统 PATH"

$machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
if ($machinePath -like "*$InstallDir*") {
    $newPath = ($machinePath -split ';' | Where-Object { $_ -ne $InstallDir }) -join ';'
    Invoke-Action {
        [System.Environment]::SetEnvironmentVariable('PATH', $newPath, 'Machine')
    } "从系统 PATH 移除: $InstallDir"
    Write-Ok "已从系统 PATH 移除: $InstallDir"
}

# ── 删除二进制和安装目录 ─────────────────────────────────────────────────────
Write-Step "删除安装文件"

if (Test-Path $InstallDir) {
    Invoke-Action { Remove-Item $InstallDir -Recurse -Force } "Remove-Item $InstallDir -Recurse"
    Write-Ok "安装目录已删除: $InstallDir"
}

# 删除桌面快捷方式
$shortcut = [System.Environment]::GetFolderPath('Desktop') + '\conMon 控制台.lnk'
if (Test-Path $shortcut) {
    Invoke-Action { Remove-Item $shortcut -Force } "Remove-Item $shortcut"
    Write-Ok "桌面快捷方式已删除"
}

# ── 删除数据（可选）─────────────────────────────────────────────────────────
if ($RemoveData) {
    Write-Step "删除数据和配置（-RemoveData）"

    Write-Warn "以下目录将被永久删除："
    foreach ($dir in @($DataDir)) {
        if (Test-Path $dir) {
            $size = [Math]::Round((Get-ChildItem $dir -Recurse -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum / 1MB, 2)
            Write-Host "  - $dir (${size}MB)" -ForegroundColor Yellow
        }
    }

    if (-not $DryRun) {
        $final = Read-Host "最后确认删除所有数据? [y/N]"
        if ($final -notmatch '^[yY]$') {
            Write-Warn "跳过数据删除"
            $RemoveData = $false
        }
    }

    if ($RemoveData) {
        foreach ($dir in @($DataDir)) {
            if (Test-Path $dir) {
                Invoke-Action { Remove-Item $dir -Recurse -Force } "Remove-Item $dir -Recurse"
                Write-Ok "已删除: $dir"
            }
        }
    }
}

# ── 汇总 ─────────────────────────────────────────────────────────────────────
Write-Host ""
if ($DryRun) {
    Write-Host "[DRY-RUN 完成] 去掉 -DryRun 参数后执行实际卸载" -ForegroundColor Yellow
} else {
    Write-Host "✓ conMon 卸载成功" -ForegroundColor Green
    Write-Host ""
    if (-not $RemoveData) {
        Write-Host "  保留的数据：" -ForegroundColor White
        if (Test-Path $DataDir) { Write-Host "  数据目录: $DataDir" }
        Write-Host ""
        Write-Host "  如需完全清除: .\uninstall.ps1 -RemoveData" -ForegroundColor Cyan
    }
}
