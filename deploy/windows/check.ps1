#Requires -Version 5.1
<#
.SYNOPSIS
    conMon 部署前环境预检脚本 (Windows)

.DESCRIPTION
    检查 Windows 系统是否满足 conMon 部署要求

.PARAMETER Mode
    部署模式：binary（默认）、docker、compose、k8s、all

.EXAMPLE
    .\check.ps1
    .\check.ps1 -Mode docker
    .\check.ps1 -Mode all

.NOTES
    建议以管理员权限运行以获取完整检测结果
#>
[CmdletBinding()]
param(
    [ValidateSet('binary', 'docker', 'compose', 'k8s', 'all')]
    [string]$Mode = 'binary'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── 计数器 ───────────────────────────────────────────────────────────────────
$Script:PassCount = 0
$Script:WarnCount = 0
$Script:FailCount = 0

# ── 颜色输出辅助函数 ─────────────────────────────────────────────────────────
function Write-Pass  { param([string]$Msg) Write-Host "[PASS] $Msg" -ForegroundColor Green;  $Script:PassCount++ }
function Write-Warn  { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow; $Script:WarnCount++ }
function Write-Fail  { param([string]$Msg) Write-Host "[FAIL] $Msg" -ForegroundColor Red;    $Script:FailCount++ }
function Write-Info  { param([string]$Msg) Write-Host "[INFO] $Msg" -ForegroundColor Cyan }
function Write-Section { param([string]$Title) Write-Host "`n══ $Title ══" -ForegroundColor White }

# ── 标题横幅 ─────────────────────────────────────────────────────────────────
Write-Host @"
╔══════════════════════════════════════════════════════╗
║       conMon 部署前环境预检工具  v2.0  (Windows)     ║
╚══════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

Write-Info "检测模式:  $Mode"
Write-Info "操作系统:  $([System.Environment]::OSVersion.VersionString)"
Write-Info "PowerShell: $($PSVersionTable.PSVersion)"
Write-Info "当前用户:  $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Info "工作目录:  $(Get-Location)"
Write-Info "管理员:    $( ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) )"

# ═════════════════════════════════════════════════════════════════════════════
# 通用检查
# ═════════════════════════════════════════════════════════════════════════════
Write-Section "基础环境"

# Windows 版本
$osVer = [System.Environment]::OSVersion.Version
if ($osVer.Major -ge 10) {
    Write-Pass "Windows 版本符合要求 (Build $($osVer.Build))"
} else {
    Write-Fail "Windows 版本过低，需要 Windows 10 / Server 2019 或更高"
}

# .NET Framework / .NET Core
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet) {
    Write-Pass ".NET 已安装: $(dotnet --version 2>$null)"
} else {
    Write-Info ".NET 未安装（非必须，仅部分功能需要）"
}

# 内存
$ram = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
if ($ram -ge 256) {
    Write-Pass "物理内存: ${ram}MB"
} else {
    Write-Warn "物理内存不足: ${ram}MB，建议 ≥ 256MB"
}

# 磁盘空间（C 盘）
$disk = Get-PSDrive C -ErrorAction SilentlyContinue
if ($disk) {
    $freeGB = [Math]::Round($disk.Free / 1GB, 1)
    if ($freeGB -ge 1) {
        Write-Pass "C: 可用磁盘: ${freeGB}GB"
    } else {
        Write-Warn "C: 磁盘空间不足: ${freeGB}GB，建议 ≥ 1GB"
    }
}

# 端口占用检查
foreach ($port in @(11080, 11090)) {
    $listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
        $proc = Get-Process -Id $listener[0].OwningProcess -ErrorAction SilentlyContinue
        Write-Warn "端口 $port 已被占用（进程: $($proc.ProcessName) PID: $($proc.Id)）"
    } else {
        Write-Pass "端口 $port 可用"
    }
}

# curl / Invoke-WebRequest
if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    Write-Pass "curl.exe 可用"
} else {
    Write-Info "curl.exe 未找到，将使用 PowerShell Invoke-WebRequest 下载"
}

# ═════════════════════════════════════════════════════════════════════════════
# Binary 模式检查
# ═════════════════════════════════════════════════════════════════════════════
if ($Mode -in @('binary', 'all')) {
    Write-Section "二进制部署环境"

    # 管理员权限（注册 Windows Service 需要）
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if ($isAdmin) {
        Write-Pass "当前以管理员权限运行"
    } else {
        Write-Warn "非管理员权限，注册 Windows Service 将失败（请以管理员身份运行 PowerShell）"
    }

    # 检查 sc.exe（Service Control Manager）
    if (Test-Path "$env:WINDIR\System32\sc.exe") {
        Write-Pass "sc.exe 可用（Windows Service 管理）"
    } else {
        Write-Fail "sc.exe 未找到（系统异常）"
    }

    # 检查 Windows Firewall（告知需要放行端口）
    $fwEnabled = (Get-NetFirewallProfile -Profile Domain,Public,Private -ErrorAction SilentlyContinue |
        Where-Object Enabled -eq True | Measure-Object).Count -gt 0
    if ($fwEnabled) {
        Write-Warn "Windows 防火墙已启用，请确保放行 TCP 11080（HTTP）和 11090（gRPC）端口"
    } else {
        Write-Info "Windows 防火墙未启用"
    }

    # 检查是否已安装 conmon
    $existingConmon = Get-Command conmon.exe -ErrorAction SilentlyContinue
    if ($existingConmon) {
        Write-Info "已安装 conmon: $($existingConmon.Source)"
    }

    # Go 环境（源码构建需要）
    $go = Get-Command go -ErrorAction SilentlyContinue
    if ($go) {
        Write-Pass "Go 已安装: $(go version)"
    } else {
        Write-Info "Go 未安装（仅源码构建需要，预编译二进制不需要）"
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# Docker 模式检查
# ═════════════════════════════════════════════════════════════════════════════
if ($Mode -in @('docker', 'compose', 'all')) {
    Write-Section "Docker 环境"

    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($docker) {
        try {
            $dockerVer = (docker version --format '{{.Server.Version}}' 2>$null)
            Write-Pass "Docker 已安装: $dockerVer"

            # Docker daemon 运行？
            docker info 2>$null | Out-Null
            Write-Pass "Docker daemon 运行正常"
        } catch {
            Write-Fail "Docker daemon 未运行，请启动 Docker Desktop"
        }

        # WSL2 后端检查（Windows Docker 推荐）
        $wsl = Get-Command wsl -ErrorAction SilentlyContinue
        if ($wsl) {
            $wslVer = wsl --status 2>$null | Select-String "版本|Version" | Select-Object -First 1
            Write-Pass "WSL2 可用 ($wslVer)"
        } else {
            Write-Warn "WSL2 未检测到，Docker Desktop 推荐使用 WSL2 后端"
        }
    } else {
        Write-Fail "Docker 未安装（https://docs.docker.com/desktop/windows/）"
    }
}

if ($Mode -in @('compose', 'all')) {
    Write-Section "Docker Compose 环境"

    try {
        $composeVer = docker compose version --short 2>$null
        Write-Pass "Docker Compose 插件: $composeVer"
    } catch {
        $legacyCompose = Get-Command docker-compose -ErrorAction SilentlyContinue
        if ($legacyCompose) {
            Write-Pass "docker-compose: $(docker-compose --version)"
        } else {
            Write-Fail "Docker Compose 未安装"
        }
    }

    # .env 文件
    $envFile = "deployments\compose\.env"
    if (Test-Path $envFile) {
        Write-Pass ".env 文件已存在"
        $content = Get-Content $envFile -Raw
        foreach ($var in @('DB_PASSWORD', 'JWT_SECRET')) {
            if ($content -match "$var=change-me|$var=\s*$") {
                Write-Warn "$var 使用了默认值，请修改 $envFile"
            } else {
                Write-Pass "$var 已配置"
            }
        }
    } else {
        Write-Warn ".env 文件不存在，请复制 deployments\compose\.env.example 后修改"
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# Kubernetes 模式检查
# ═════════════════════════════════════════════════════════════════════════════
if ($Mode -in @('k8s', 'all')) {
    Write-Section "Kubernetes 环境"

    $kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
    if ($kubectl) {
        $kubectlVer = kubectl version --client --short 2>$null
        Write-Pass "kubectl: $kubectlVer"

        try {
            kubectl cluster-info 2>$null | Out-Null
            Write-Pass "Kubernetes 集群连接正常"
            $nodeCount = (kubectl get nodes --no-headers 2>$null | Measure-Object -Line).Lines
            Write-Pass "集群节点数: $nodeCount"
        } catch {
            Write-Warn "无法连接 Kubernetes 集群，请检查 kubeconfig"
        }
    } else {
        Write-Fail "kubectl 未安装"
    }

    $helm = Get-Command helm -ErrorAction SilentlyContinue
    if ($helm) {
        Write-Pass "Helm: $(helm version --short 2>$null)"
    } else {
        Write-Warn "Helm 未安装（使用 Helm Chart 部署时需要）"
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 网络连通性
# ═════════════════════════════════════════════════════════════════════════════
Write-Section "网络连通性"

$checkUrls = @(
    @{ Name = 'GitHub（下载二进制）';   Url = 'https://github.com' }
    @{ Name = 'Docker Hub（拉取镜像）'; Url = 'https://registry-1.docker.io' }
    @{ Name = '外网 DNS（8.8.8.8）';   Url = 'https://dns.google' }
)

foreach ($item in $checkUrls) {
    try {
        $resp = Invoke-WebRequest -Uri $item.Url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($resp.StatusCode -lt 400) {
            Write-Pass "$($item.Name) 可达"
        } else {
            Write-Warn "$($item.Name) 返回 $($resp.StatusCode)"
        }
    } catch {
        Write-Warn "$($item.Name) 不可达（$($item.Url)）"
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# 汇总报告
# ═════════════════════════════════════════════════════════════════════════════
Write-Section "检查汇总"

$total = $Script:PassCount + $Script:WarnCount + $Script:FailCount
Write-Host ""
Write-Host "  总计: $total 项"
Write-Host "  通过: $($Script:PassCount) 项" -ForegroundColor Green
Write-Host "  警告: $($Script:WarnCount) 项" -ForegroundColor Yellow
Write-Host "  失败: $($Script:FailCount) 项" -ForegroundColor Red
Write-Host ""

if ($Script:FailCount -gt 0) {
    Write-Host "✗ 存在 $($Script:FailCount) 个必须解决的问题，请先修复再部署。" -ForegroundColor Red
    exit 1
} elseif ($Script:WarnCount -gt 0) {
    Write-Host "⚠ 存在 $($Script:WarnCount) 个警告，建议处理后再部署。" -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "✓ 环境检查全部通过，可以开始部署！" -ForegroundColor Green
    exit 0
}
