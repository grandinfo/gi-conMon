#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    conMon Windows 一键安装脚本

.DESCRIPTION
    下载 conmon.exe，安装到系统目录，创建配置文件，注册为 Windows Service

.PARAMETER Version
    目标版本号，默认 latest

.PARAMETER InstallDir
    安装目录，默认 C:\Program Files\conmon

.PARAMETER ConfigFile
    自定义配置文件路径（不指定则生成默认配置）

.PARAMETER NoService
    跳过 Windows Service 注册

.PARAMETER DataDir
    数据目录，默认 C:\ProgramData\conmon

.EXAMPLE
    .\install.ps1
    .\install.ps1 -Version v2.0.0
    .\install.ps1 -InstallDir "D:\conmon" -NoService

.NOTES
    需要以管理员身份运行 PowerShell
#>
[CmdletBinding()]
param(
    [string]$Version    = 'latest',
    [string]$InstallDir = 'C:\Program Files\conmon',
    [string]$ConfigFile = '',
    [string]$DataDir    = 'C:\ProgramData\conmon',
    [switch]$NoService
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── 常量 ─────────────────────────────────────────────────────────────────────
$GithubRepo  = 'grandinfo/gi-conMon'
$ServiceName = 'conmon'
$ServiceDesc = 'conMon Network Connection Monitor'
$LogDir      = "$DataDir\logs"
$ConfigDir   = "$DataDir\config"
$BinaryPath  = "$InstallDir\conmon.exe"

# ── 辅助函数 ─────────────────────────────────────────────────────────────────
function Write-Step  { param([string]$Msg) Write-Host "`n>>> $Msg" -ForegroundColor White }
function Write-Ok    { param([string]$Msg) Write-Host "[OK]  $Msg" -ForegroundColor Green }
function Write-Info  { param([string]$Msg) Write-Host "[..] $Msg"  -ForegroundColor Cyan }
function Write-Warn  { param([string]$Msg) Write-Host "[!!] $Msg"  -ForegroundColor Yellow }
function Fail        { param([string]$Msg) Write-Host "[ERR] $Msg" -ForegroundColor Red; exit 1 }

# ── 横幅 ─────────────────────────────────────────────────────────────────────
Write-Host @"
╔══════════════════════════════════════════════════════╗
║         conMon Windows 安装脚本 v2.0                 ║
╚══════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

# ── 获取版本 ──────────────────────────────────────────────────────────────────
Write-Step "获取版本信息"

if ($Version -eq 'latest') {
    Write-Info "查询最新版本..."
    try {
        $rel = Invoke-RestMethod "https://api.github.com/repos/$GithubRepo/releases/latest" -ErrorAction Stop
        $Version = $rel.tag_name
    } catch {
        Write-Warn "无法查询最新版本，使用 v2.0.0"
        $Version = 'v2.0.0'
    }
}
Write-Ok "目标版本: $Version"

# ── 创建目录 ──────────────────────────────────────────────────────────────────
Write-Step "创建安装目录"

foreach ($dir in @($InstallDir, $DataDir, $LogDir, $ConfigDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Ok "创建目录: $dir"
    } else {
        Write-Info "目录已存在: $dir"
    }
}

# ── 下载二进制 ────────────────────────────────────────────────────────────────
Write-Step "下载 conmon.exe"

# 优先使用本地构建产物
$localBinary = Join-Path (Get-Location) 'bin\conmon.exe'
if (Test-Path $localBinary) {
    Write-Info "使用本地构建: $localBinary"
    Copy-Item $localBinary $BinaryPath -Force
} else {
    $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'amd64' }
    $downloadUrl = "https://github.com/$GithubRepo/releases/download/$Version/conmon-windows-$arch.zip"

    Write-Info "下载: $downloadUrl"
    $zipPath = "$env:TEMP\conmon-$Version.zip"

    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        $ProgressPreference = 'Continue'
    } catch {
        Fail "下载失败: $_`n请检查网络连接或版本号是否正确"
    }

    Write-Info "解压..."
    Expand-Archive -Path $zipPath -DestinationPath "$env:TEMP\conmon-extract" -Force
    $extracted = Get-ChildItem "$env:TEMP\conmon-extract" -Filter 'conmon.exe' -Recurse | Select-Object -First 1
    if (-not $extracted) { Fail "解压后未找到 conmon.exe" }
    Copy-Item $extracted.FullName $BinaryPath -Force
    Remove-Item $zipPath, "$env:TEMP\conmon-extract" -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Ok "安装完成: $BinaryPath"

# ── 验证二进制 ────────────────────────────────────────────────────────────────
Write-Step "验证二进制"
try {
    $verOutput = & $BinaryPath version 2>&1
    Write-Ok "版本验证: $verOutput"
} catch {
    Fail "二进制运行失败: $_"
}

# ── 将安装目录加入 PATH ──────────────────────────────────────────────────────
Write-Step "配置系统 PATH"

$currentPath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
if ($currentPath -notlike "*$InstallDir*") {
    [System.Environment]::SetEnvironmentVariable('PATH', "$currentPath;$InstallDir", 'Machine')
    Write-Ok "已将 $InstallDir 加入系统 PATH（需重新打开终端生效）"
} else {
    Write-Info "PATH 已包含 $InstallDir"
}

# ── 安装配置文件 ──────────────────────────────────────────────────────────────
Write-Step "安装配置文件"

$targetConfig = "$ConfigDir\conmon.yaml"

if ($ConfigFile -and (Test-Path $ConfigFile)) {
    Copy-Item $ConfigFile $targetConfig -Force
    Write-Ok "使用指定配置: $ConfigFile"
} elseif (-not (Test-Path $targetConfig)) {
    # 写入默认配置（Windows 路径）
    $defaultConfig = @"
server:
  bind: "0.0.0.0:8080"
  external_url: "http://localhost:8080"
  auth:
    jwt_secret: "CHANGE_ME_USE_STRONG_RANDOM_SECRET_32CHARS"
    token_expire: "24h"

storage:
  type: "sqlite"
  path: "$($DataDir.Replace('\','/'))/conmon.db"
  retention:
    raw: "168h"
    events: "2160h"
    alerts: "4320h"

probe:
  id: "probe-windows-01"
  name: "Windows 本地探针"
  location: "本地"
  concurrency: 100

monitors:
  - name: "百度 HTTPS"
    target: "www.baidu.com"
    protocol: "https"
    port: 443
    interval: "1m"
    tags: ["示例"]

  - name: "自身健康检查"
    target: "localhost"
    protocol: "http"
    port: 8080
    interval: "30s"
    probe_config:
      path: "/health"
      expected_codes: [200]

alerting:
  channels: []
  rules:
    - name: "服务宕机"
      condition: "event.to_status == 'DOWN'"
      channels: []
      severity: "error"
      throttle: "10m"

log:
  level: "info"
  format: "json"
  output: "stdout"
"@
    $defaultConfig | Set-Content $targetConfig -Encoding UTF8
    Write-Ok "默认配置已写入: $targetConfig"
} else {
    Write-Info "配置文件已存在，跳过"
}

# ── 创建环境变量配置文件 ──────────────────────────────────────────────────────
$envFile = "$ConfigDir\conmon.env"
if (-not (Test-Path $envFile)) {
    @"
# conMon 环境变量文件（PowerShell 格式）
# 修改后重启服务: Restart-Service conmon

# JWT 密钥（建议使用随机字符串）
`$env:JWT_SECRET = "CHANGE_ME_USE_STRONG_RANDOM_SECRET"

# 数据库密码（PostgreSQL 模式）
# `$env:DB_PASSWORD = "your-database-password"

# 钉钉 Webhook
# `$env:DINGTALK_WEBHOOK_URL = "https://oapi.dingtalk.com/robot/send?access_token=xxx"
# `$env:DINGTALK_SECRET = "xxx"

# 企业微信 Webhook
# `$env:WECOM_WEBHOOK_URL = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx"
"@ | Set-Content $envFile -Encoding UTF8
    Write-Ok "环境变量配置文件: $envFile"
}

# ── 创建防火墙规则 ────────────────────────────────────────────────────────────
Write-Step "配置 Windows 防火墙"

$fwRules = @(
    @{ Name = 'conMon HTTP API';  Port = 8080 }
    @{ Name = 'conMon gRPC Probe'; Port = 9090 }
)

foreach ($rule in $fwRules) {
    $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Info "防火墙规则已存在: $($rule.Name)"
    } else {
        New-NetFirewallRule `
            -DisplayName $rule.Name `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort $rule.Port `
            -Action Allow `
            -Profile Any `
            -ErrorAction SilentlyContinue | Out-Null
        Write-Ok "防火墙规则已创建: $($rule.Name) (TCP $($rule.Port))"
    }
}

# ── 注册 Windows Service ──────────────────────────────────────────────────────
if (-not $NoService) {
    Write-Step "注册 Windows Service"

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Info "服务已存在，停止并更新..."
        Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
        sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 2
    }

    # 使用 sc.exe 注册服务
    $binPathWithArgs = "`"$BinaryPath`" server -c `"$targetConfig`""
    sc.exe create $ServiceName `
        binPath= $binPathWithArgs `
        DisplayName= $ServiceDesc `
        start= auto `
        obj= LocalSystem | Out-Null

    # 设置服务描述
    sc.exe description $ServiceName "conMon Network Connection Monitor - 企业级网络连接监控工具" | Out-Null

    # 设置故障恢复（失败后自动重启）
    sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

    Write-Ok "Windows Service 已注册: $ServiceName"
    Write-Ok "启动类型: 自动（开机自启）"
    Write-Ok "故障恢复: 失败后自动重启"

    # 创建 PowerShell Profile 便捷函数
    $profileContent = @"
# conMon 管理快捷函数
function Start-ConMon   { Start-Service conmon; Write-Host '✓ conMon 已启动' -ForegroundColor Green }
function Stop-ConMon    { Stop-Service conmon;  Write-Host '✓ conMon 已停止' -ForegroundColor Yellow }
function Restart-ConMon { Restart-Service conmon; Write-Host '✓ conMon 已重启' -ForegroundColor Green }
function Get-ConMonStatus {
    `$svc = Get-Service conmon
    `$resp = try { Invoke-RestMethod http://localhost:8080/health -TimeoutSec 3 } catch { `$null }
    Write-Host "服务状态: `$(`$svc.Status)" -ForegroundColor $(if ($svc.Status -eq 'Running') { 'Green' } else { 'Red' })
    if (`$resp) { Write-Host "API 状态: `$(`$resp.status) v`$(`$resp.version)" -ForegroundColor Green }
}
function Get-ConMonLogs { Get-EventLog -LogName Application -Source conmon -Newest 50 }
"@
}

# ── 创建桌面快捷方式 ──────────────────────────────────────────────────────────
Write-Step "创建管理快捷方式"

$desktopPath = [System.Environment]::GetFolderPath('Desktop')
$shortcutPath = "$desktopPath\conMon 控制台.lnk"

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = 'powershell.exe'
$shortcut.Arguments = "-NoExit -Command `"Start-Process http://localhost:8080; Write-Host 'conMon Web 控制台已在浏览器中打开' -ForegroundColor Green`""
$shortcut.WorkingDirectory = $InstallDir
$shortcut.Description = 'conMon Web 控制台'
$shortcut.Save()
Write-Ok "桌面快捷方式: $shortcutPath"

# ── 完成 ─────────────────────────────────────────────────────────────────────
Write-Host @"

╔══════════════════════════════════════════════════════╗
║            conMon 安装完成！                         ║
╚══════════════════════════════════════════════════════╝
"@ -ForegroundColor Green

Write-Host "  安装路径:  $BinaryPath"       -ForegroundColor White
Write-Host "  配置文件:  $targetConfig"     -ForegroundColor White
Write-Host "  数据目录:  $DataDir"          -ForegroundColor White
Write-Host "  日志目录:  $LogDir"           -ForegroundColor White
Write-Host ""

if (-not $NoService) {
    Write-Host "  启动服务：" -ForegroundColor White
    Write-Host "    Start-Service conmon" -ForegroundColor Cyan
    Write-Host "    # 或在服务管理器中启动: services.msc" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  服务管理：" -ForegroundColor White
    Write-Host "    Get-Service conmon" -ForegroundColor Cyan
    Write-Host "    Stop-Service conmon" -ForegroundColor Cyan
    Write-Host "    Restart-Service conmon" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "  重要：请修改配置中的默认密钥：" -ForegroundColor Yellow
Write-Host "    $targetConfig" -ForegroundColor Yellow
Write-Host ""
Write-Host "  服务地址：http://localhost:8080" -ForegroundColor White
Write-Host "  健康检查：Invoke-RestMethod http://localhost:8080/health" -ForegroundColor Cyan
Write-Host ""
